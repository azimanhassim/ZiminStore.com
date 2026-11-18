-- =====================================================================
-- ZiminStore: processing queue, automatic status, history, report archive,
-- e-mail retry with attempt logging, duplicate-payment guards.
--
-- STATUS: DRAFT FOR REVIEW. NOT APPLIED. NOT APPROVED TO RUN.
-- Rollback: supabase/migrations/20261118_processing_queue_rollback.sql
--
-- Runs as ONE transaction: if any step fails (including the pre-checks),
-- nothing is changed.
--
-- Adds (nothing existing is dropped or loosened):
--   A. public.zs_order_events     history + error log (admin read-only).
--   B. public.zs_report_archive   metadata of replaced/removed reports. The old
--                                 PDF stays in the private "similarity-reports"
--                                 bucket; nothing deletes it.
--   C. Automatic order status     payment verified -> payment_verified;
--                                 report inserted  -> processing / report_ready
--                                 (row lock on the order, DISTINCT documents).
--   D. Status history             every orders.status change, with from/to.
--   E. Duplicate payment guards   one PENDING proof per order (unique index);
--                                 no new proof once a payment is VERIFIED.
--   F. E-mail retry               keyed on the time the order BECAME report_ready
--                                 (not updated_at). Every attempt is logged by
--                                 zs-notify as notify_sent / notify_failed; after
--                                 5 retries an 'error' event is written once.
--   G. Orphan payment proofs      helper for zs-cleanup (service role only) to
--                                 delete proof files that never got a payments row.
-- The website keeps working whether or not this file has been applied.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Pre-checks (abort the whole transaction if the data is not ready)
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from public.payments where status = 'pending'
             group by order_id having count(*) > 1) then
    raise exception 'DIHENTIKAN: ada pesanan dengan lebih daripada satu bukti bayaran pending. Selesaikan dahulu.';
  end if;
  if to_regclass('public.zs_notification_log') is null then
    raise exception 'DIHENTIKAN: public.zs_notification_log tidak wujud (zs-notify bergantung padanya).';
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.zs_notification_log'::regclass and contype = 'p') then
    raise exception 'DIHENTIKAN: zs_notification_log tiada primary key (kind, ref_id).';
  end if;
  if not exists (select 1 from pg_extension where extname = 'pg_net')
     or not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise exception 'DIHENTIKAN: pg_net dan pg_cron mesti dihidupkan.';
  end if;
  -- Archive-in-place relies on customers reading a report file only while a
  -- public.reports row points to it. Warn (do not abort) if no such policy is found.
  if not exists (select 1 from pg_policies
                  where schemaname = 'storage' and tablename = 'objects'
                    and coalesce(qual, '') ilike '%similarity-reports%'
                    and coalesce(qual, '') ilike '%reports%') then
    raise warning 'SEMAK: tiada polisi storage yang mengikat fail similarity-reports kepada jadual reports. Sahkan pelanggan tidak boleh membaca laporan lama yang diarkib.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- A. History / error log
-- ---------------------------------------------------------------------
-- No foreign key on purpose: history must survive if an order is ever deleted.
create table if not exists public.zs_order_events (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null,
  kind       text not null check (kind in (
               'status_changed','payment_verified','payment_rejected',
               'report_uploaded','report_replaced','report_removed',
               'processing_started','action_required','note',
               'notify_retry','notify_sent','notify_failed','error')),
  actor      uuid,                                  -- auth.uid(); null = system
  detail     text check (char_length(detail) <= 500),
  meta       jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists zs_order_events_order_idx on public.zs_order_events (order_id, created_at desc);
create index if not exists zs_order_events_kind_idx  on public.zs_order_events (kind, created_at desc);
alter table public.zs_order_events enable row level security;

drop policy if exists zs_order_events_admin_select on public.zs_order_events;
create policy zs_order_events_admin_select on public.zs_order_events
  for select to authenticated using ((select public.is_admin()));

-- Admins may add their own entries from the portal; everything else is written by
-- triggers (table owner) or by zs-notify (service role). No update/delete policies.
drop policy if exists zs_order_events_admin_insert on public.zs_order_events;
create policy zs_order_events_admin_insert on public.zs_order_events
  for insert to authenticated
  with check ((select public.is_admin()) and actor = (select auth.uid())
              and kind in ('processing_started','action_required','note'));

revoke all on public.zs_order_events from anon, authenticated;
grant select, insert on public.zs_order_events to authenticated;

-- ---------------------------------------------------------------------
-- B. Report archive (metadata; the PDF itself is never deleted)
-- ---------------------------------------------------------------------
create table if not exists public.zs_report_archive (
  id           uuid primary key default gen_random_uuid(),
  report_id    uuid not null,          -- the deleted public.reports.id
  order_id     uuid not null,
  document_id  uuid,
  customer_id  uuid not null,
  report_path  text not null,          -- still in bucket "similarity-reports"
  uploaded_at  timestamptz,
  archived_at  timestamptz not null default now(),
  archived_by  uuid,                   -- admin who replaced/removed it
  replaced_by  uuid                    -- the newer public.reports.id, if any
);
create index if not exists zs_report_archive_order_idx on public.zs_report_archive (order_id, archived_at desc);
alter table public.zs_report_archive enable row level security;

drop policy if exists zs_report_archive_admin_select on public.zs_report_archive;
create policy zs_report_archive_admin_select on public.zs_report_archive
  for select to authenticated using ((select public.is_admin()));

revoke all on public.zs_report_archive from anon, authenticated;
grant select on public.zs_report_archive to authenticated;

-- ---------------------------------------------------------------------
-- C1. Payment reviewed -> order status + history
-- ---------------------------------------------------------------------
create or replace function public.zs_after_payment_review()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status is distinct from old.status then
    if new.status = 'verified' then
      update public.orders set status = 'payment_verified'
       where id = new.order_id and status = 'pending_payment';
      insert into public.zs_order_events (order_id, kind, actor, meta)
      values (new.order_id, 'payment_verified', auth.uid(), jsonb_build_object('payment_id', new.id));
    elsif new.status = 'rejected' then
      insert into public.zs_order_events (order_id, kind, actor, meta)
      values (new.order_id, 'payment_rejected', auth.uid(), jsonb_build_object('payment_id', new.id));
    end if;
  end if;
  return null;
end; $$;
drop trigger if exists zs_payments_after_review on public.payments;
create trigger zs_payments_after_review after update of status on public.payments
  for each row execute function public.zs_after_payment_review();

-- ---------------------------------------------------------------------
-- C2. Report inserted -> processing / report_ready (locked, distinct documents)
-- ---------------------------------------------------------------------
create or replace function public.zs_after_report_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_need int; v_status text; v_done int; v_next text;
begin
  -- Serialise concurrent uploads for the same order; the count below then sees
  -- every report committed before the lock was granted.
  select o.document_count, o.status into v_need, v_status
    from public.orders o where o.id = new.order_id for update;

  select count(distinct r.document_id) into v_done
    from public.reports r where r.order_id = new.order_id and r.document_id is not null;

  v_next := case when v_done >= v_need then 'report_ready' else 'processing' end;

  -- Never downgrade a completed order (a replacement keeps it report_ready).
  if v_status in ('payment_verified','processing','action_required') and v_status <> v_next then
    update public.orders set status = v_next where id = new.order_id;
  end if;

  insert into public.zs_order_events (order_id, kind, actor, detail, meta)
  values (new.order_id, 'report_uploaded', auth.uid(), v_done || '/' || v_need || ' dokumen ada laporan',
          jsonb_build_object('report_id', new.id, 'document_id', new.document_id,
                             'report_path', new.report_path, 'done', v_done, 'need', v_need));
  return null;
end; $$;
drop trigger if exists zs_reports_after_insert on public.reports;
create trigger zs_reports_after_insert after insert on public.reports
  for each row execute function public.zs_after_report_insert();

-- ---------------------------------------------------------------------
-- C3. Report deleted (replacement) -> archive metadata + history
-- ---------------------------------------------------------------------
create or replace function public.zs_archive_report()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_new uuid;
begin
  select r.id into v_new from public.reports r
   where r.order_id = old.order_id and r.document_id is not distinct from old.document_id and r.id <> old.id
   order by r.uploaded_at desc nulls last limit 1;

  insert into public.zs_report_archive
    (report_id, order_id, document_id, customer_id, report_path, uploaded_at, archived_by, replaced_by)
  values (old.id, old.order_id, old.document_id, old.customer_id, old.report_path, old.uploaded_at, auth.uid(), v_new);

  insert into public.zs_order_events (order_id, kind, actor, detail, meta)
  values (old.order_id, case when v_new is null then 'report_removed' else 'report_replaced' end, auth.uid(),
          case when v_new is null then 'Laporan dikeluarkan (fail diarkib)' else 'Laporan diganti (fail lama diarkib)' end,
          jsonb_build_object('old_report_id', old.id, 'document_id', old.document_id,
                             'old_report_path', old.report_path, 'old_uploaded_at', old.uploaded_at,
                             'replaced_by', v_new));
  return null;
end; $$;
drop trigger if exists zs_reports_after_delete on public.reports;
create trigger zs_reports_after_delete after delete on public.reports
  for each row execute function public.zs_archive_report();

-- ---------------------------------------------------------------------
-- D. Status history (from/to kept in meta; F uses the time of -> report_ready)
-- ---------------------------------------------------------------------
create or replace function public.zs_log_order_status()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status is distinct from old.status then
    insert into public.zs_order_events (order_id, kind, actor, detail, meta)
    values (new.id, 'status_changed', auth.uid(), old.status || ' -> ' || new.status,
            jsonb_build_object('from', old.status, 'to', new.status));
  end if;
  return null;
end; $$;
drop trigger if exists zs_orders_log_status on public.orders;
create trigger zs_orders_log_status after update of status on public.orders
  for each row execute function public.zs_log_order_status();

-- ---------------------------------------------------------------------
-- E1. One PENDING payment proof per order
-- ---------------------------------------------------------------------
create unique index if not exists zs_payments_one_pending
  on public.payments (order_id) where status = 'pending';

-- E2. zs_prepare_payment: identical to the live version (read 18 Nov 2026) plus ONE
--     new check: reject a new proof when the order already has a VERIFIED payment.
create or replace function public.zs_prepare_payment()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_customer uuid;
  v_total integer;
  v_expected integer;
  v_order_status text;
  v_document_rows integer;
  v_missing_files integer;
begin
  select o.customer_id, o.total_sen, o.document_count, o.status
    into v_customer, v_total, v_expected, v_order_status
  from public.orders o
  where o.id = new.order_id;

  if not found or v_customer is distinct from new.customer_id then
    raise exception 'Pesanan tidak sah';
  end if;

  if new.customer_id is distinct from auth.uid() and not public.is_admin() then
    raise exception 'Tidak dibenarkan';
  end if;

  -- NEW: a paid order never takes another proof (also covers action_required).
  if exists (select 1 from public.payments p where p.order_id = new.order_id and p.status = 'verified') then
    raise exception 'Pesanan ini sudah disahkan dibayar';
  end if;

  if not public.is_admin()
     and v_order_status not in ('pending_payment', 'action_required') then
    raise exception 'Pesanan tidak menerima bukti bayaran sekarang';
  end if;

  if new.proof_path is null
     or new.proof_path not like new.customer_id::text || '/' || new.order_id::text || '/%' then
    raise exception 'Laluan bukti bayaran tidak sah';
  end if;

  if not exists (
    select 1
    from storage.objects so
    where so.bucket_id = 'payment-proofs'
      and so.name = new.proof_path
  ) then
    raise exception 'Fail bukti bayaran belum wujud dalam Storage';
  end if;

  select count(*) into v_document_rows
  from public.documents d
  where d.order_id = new.order_id
    and d.customer_id = new.customer_id;

  if v_document_rows <> v_expected then
    raise exception 'Bilangan rekod dokumen belum sama dengan jumlah pesanan';
  end if;

  select count(*) into v_missing_files
  from public.documents d
  where d.order_id = new.order_id
    and d.customer_id = new.customer_id
    and not exists (
      select 1
      from storage.objects so
      where so.bucket_id = 'customer-documents'
        and so.name = d.storage_path
    );

  if v_missing_files > 0 then
    raise exception 'Ada fail dokumen yang belum lengkap dalam Storage';
  end if;

  new.amount_sen := v_total;
  new.status := 'pending';
  new.verified_at := null;
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- F. E-mail retry, keyed on when the order BECAME report_ready
-- ---------------------------------------------------------------------
-- Attempt 1 = the existing zs_orders_notify_report_ready trigger.
-- Attempts 2..6 = up to 5 retries, at least 15 minutes apart, within 3 days.
-- zs-notify writes notify_sent / notify_failed for every attempt (draft in
-- supabase/functions/zs-notify/index.ts) and sends at most once per order
-- (primary key on zs_notification_log). Replacing an old report does not
-- change status, so it never starts a new e-mail.
create or replace function public.zs_retry_report_notifications()
returns void language plpgsql security definer set search_path = '' as $$
declare r record; v_retries int;
begin
  for r in
    select o.id, t.ready_at
      from public.orders o
      cross join lateral (
        select max(e.created_at) as ready_at
          from public.zs_order_events e
         where e.order_id = o.id and e.kind = 'status_changed' and e.meta->>'to' = 'report_ready') t
     where o.status = 'report_ready'
       and t.ready_at is not null
       and t.ready_at < now() - interval '10 minutes'
       and t.ready_at > now() - interval '3 days'
       and not exists (select 1 from public.zs_notification_log l
                        where l.kind = 'report_ready' and l.ref_id = o.id)
  loop
    select count(*) into v_retries from public.zs_order_events e
     where e.order_id = r.id and e.kind = 'notify_retry' and e.created_at >= r.ready_at;

    if v_retries >= 5 then
      if not exists (select 1 from public.zs_order_events e
                      where e.order_id = r.id and e.kind = 'error'
                        and e.meta->>'reason' = 'notify_gave_up' and e.created_at >= r.ready_at) then
        insert into public.zs_order_events (order_id, kind, detail, meta)
        values (r.id, 'error', 'E-mel laporan siap gagal selepas 5 cubaan semula. Hubungi pelanggan secara manual.',
                jsonb_build_object('reason', 'notify_gave_up', 'retries', v_retries));
      end if;
      continue;
    end if;

    perform net.http_post(
      url := 'https://vletiqtwzzrktttzxyej.supabase.co/functions/v1/zs-notify',
      body := jsonb_build_object('type', 'report_ready', 'id', r.id, 'attempt', v_retries + 2, 'source', 'retry'),
      headers := '{"Content-Type": "application/json"}'::jsonb,
      timeout_milliseconds := 10000);

    insert into public.zs_order_events (order_id, kind, detail, meta)
    values (r.id, 'notify_retry', 'Cubaan semula e-mel ' || (v_retries + 1) || '/5',
            jsonb_build_object('attempt', v_retries + 2, 'retry', v_retries + 1));
  end loop;
end; $$;

select cron.schedule('zs-notify-retry', '*/15 * * * *', $$ select public.zs_retry_report_notifications() $$);

-- ---------------------------------------------------------------------
-- G. Orphan payment proofs (files uploaded but never linked to a payments row)
-- ---------------------------------------------------------------------
-- Customers cannot delete storage files, so a failed insert can leave a proof
-- behind. zs-cleanup (service role) lists them with this function and removes
-- them through the Storage API after 24 hours.
create or replace function public.zs_orphan_payment_proofs(p_min_age interval default interval '24 hours')
returns table (name text) language sql stable security definer set search_path = '' as $$
  select so.name from storage.objects so
   where so.bucket_id = 'payment-proofs'
     and so.created_at < now() - p_min_age
     and not exists (select 1 from public.payments p where p.proof_path = so.name)
   order by so.created_at
   limit 500
$$;

-- ---------------------------------------------------------------------
-- Function privileges: trigger/cron functions are never called by browsers.
-- ---------------------------------------------------------------------
revoke execute on function
  public.zs_after_payment_review(), public.zs_after_report_insert(), public.zs_archive_report(),
  public.zs_log_order_status(), public.zs_retry_report_notifications(),
  public.zs_orphan_payment_proofs(interval)
  from public, anon, authenticated;
revoke execute on function public.zs_prepare_payment() from public, anon, authenticated;
grant execute on function public.zs_orphan_payment_proofs(interval) to service_role;

commit;
