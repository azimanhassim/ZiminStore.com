-- =====================================================================
-- ZiminStore: processing queue, automatic status, history, report archive,
-- leased e-mail claims with retry and attempt logging, duplicate-payment guards.
--
-- STATUS: DRAFT FOR REVIEW. NOT APPLIED. NOT APPROVED TO RUN.
-- Rollback: supabase/migrations/20261118_processing_queue_rollback.sql
-- Deploy order after approval: this migration -> zs-notify v4 -> zs-cleanup -> website.
--
-- Runs as ONE transaction: if any step or pre-check fails, nothing is changed.
--
-- A. public.zs_order_events     history + error log (admin read-only).
-- B. public.zs_report_archive   metadata of replaced/removed reports.
--    Archive-in-place (keeping the old PDF) is switched on ONLY if a live test in
--    this transaction proves a customer cannot read a report file once its
--    public.reports row is gone. Otherwise the archive trigger is not created.
--    The website keeps an old PDF only when the archive row for that exact report
--    exists after the delete; with no trigger (not created, disabled or rolled
--    back) there is no row and the PDF is deleted exactly as today.
-- C. Automatic order status     payment verified -> payment_verified;
--                               report inserted  -> processing / report_ready
--                               (row lock on the order, DISTINCT documents).
-- D. Status history             every orders.status change, with from/to.
-- E. Duplicate payment guards   one PENDING proof per order (unique index);
--                               no new proof once a payment is VERIFIED.
-- F. Leased notification claims zs_notification_log gets state/lease/token columns;
--                               a claim that was never sent can be taken over
--                               after its lease expires; only the holder of the
--                               current claim_token can finish it.
-- G. E-mail retry               keyed on the time the order BECAME report_ready.
-- H. Orphan payment proofs      helper for zs-cleanup (service role only).
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 0. Pre-checks and backups
-- ---------------------------------------------------------------------
do $$
declare v_pk text[];
begin
  if exists (select 1 from public.payments where status = 'pending'
             group by order_id having count(*) > 1) then
    raise exception 'DIHENTIKAN: ada pesanan dengan lebih daripada satu bukti bayaran pending. Selesaikan dahulu.';
  end if;

  if to_regclass('public.zs_notification_log') is null then
    raise exception 'DIHENTIKAN: public.zs_notification_log tidak wujud.';
  end if;
  -- The primary key must be EXACTLY (kind, ref_id), in that order.
  select array_agg(a.attname::text order by k.ord) into v_pk
    from pg_constraint c
    cross join lateral unnest(c.conkey) with ordinality as k(attnum, ord)
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = k.attnum
   where c.conrelid = 'public.zs_notification_log'::regclass and c.contype = 'p';
  if v_pk is distinct from array['kind','ref_id'] then
    raise exception 'DIHENTIKAN: primary key zs_notification_log ialah %, dijangka (kind, ref_id).', coalesce(v_pk::text, 'tiada');
  end if;
  if (select format_type(atttypid, atttypmod) from pg_attribute
       where attrelid = 'public.zs_notification_log'::regclass and attname = 'kind') <> 'text'
     or (select format_type(atttypid, atttypmod) from pg_attribute
       where attrelid = 'public.zs_notification_log'::regclass and attname = 'ref_id') <> 'uuid' then
    raise exception 'DIHENTIKAN: jenis lajur zs_notification_log bukan (kind text, ref_id uuid).';
  end if;

  if not exists (select 1 from pg_extension where extname = 'pg_net')
     or not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise exception 'DIHENTIKAN: pg_net dan pg_cron mesti dihidupkan.';
  end if;
end $$;

-- Backup of anything the rollback must restore exactly (kept until removed by hand).
create table if not exists public.zs_migration_backup (
  key        text primary key,
  acl        aclitem[],
  note       text,
  created_at timestamptz not null default now()
);
alter table public.zs_migration_backup enable row level security;   -- no policies: not reachable from the API
revoke all on public.zs_migration_backup from anon, authenticated;
insert into public.zs_migration_backup (key, acl, note)
select '20261118:zs_prepare_payment:acl', p.proacl,
       'proacl of public.zs_prepare_payment() before migration 20261118 (NULL = default privileges)'
  from pg_proc p where p.oid = 'public.zs_prepare_payment()'::regprocedure
on conflict (key) do nothing;     -- re-running never overwrites the original backup

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
-- triggers (table owner) or zs-notify (service role). No update/delete policies.
drop policy if exists zs_order_events_admin_insert on public.zs_order_events;
create policy zs_order_events_admin_insert on public.zs_order_events
  for insert to authenticated
  with check ((select public.is_admin()) and actor = (select auth.uid())
              and kind in ('processing_started','action_required','note'));

revoke all on public.zs_order_events from anon, authenticated;
grant select, insert on public.zs_order_events to authenticated;

-- ---------------------------------------------------------------------
-- B. Report archive
-- ---------------------------------------------------------------------
create table if not exists public.zs_report_archive (
  id           uuid primary key default gen_random_uuid(),
  report_id    uuid not null,          -- the deleted public.reports.id
  order_id     uuid not null,
  document_id  uuid,
  customer_id  uuid not null,
  report_path  text not null,          -- kept in bucket "similarity-reports"
  uploaded_at  timestamptz,
  archived_at  timestamptz not null default now(),
  archived_by  uuid,
  replaced_by  uuid                    -- the newer public.reports.id, if any
);
create index if not exists zs_report_archive_order_idx on public.zs_report_archive (order_id, archived_at desc);
alter table public.zs_report_archive enable row level security;

drop policy if exists zs_report_archive_admin_select on public.zs_report_archive;
create policy zs_report_archive_admin_select on public.zs_report_archive
  for select to authenticated using ((select public.is_admin()));

revoke all on public.zs_report_archive from anon, authenticated;
grant select on public.zs_report_archive to authenticated;

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

-- B1. LIVE POLICY TEST (inside this transaction, fully rolled back):
--     take the newest report whose file exists, act as its customer, confirm the
--     customer CAN read the file while the reports row exists and CANNOT read it
--     after the row is deleted. Archive-in-place is enabled only if both hold.
do $$
declare
  v_r record; v_before boolean; v_after boolean; v_result text := 'not_run';
begin
  select r.id, r.report_path, r.customer_id into v_r
    from public.reports r
    join storage.objects so on so.bucket_id = 'similarity-reports' and so.name = r.report_path
   order by r.uploaded_at desc nulls last limit 1;

  if v_r.id is null then
    v_result := 'no_sample';
  else
    begin
      perform set_config('request.jwt.claims',
        json_build_object('sub', v_r.customer_id, 'role', 'authenticated')::text, true);
      set local role authenticated;
      v_before := exists (select 1 from storage.objects
                           where bucket_id = 'similarity-reports' and name = v_r.report_path);
      reset role;

      delete from public.reports where id = v_r.id;        -- simulated replacement

      set local role authenticated;
      v_after := exists (select 1 from storage.objects
                          where bucket_id = 'similarity-reports' and name = v_r.report_path);
      reset role;
      perform set_config('request.jwt.claims', '', true);

      -- Always roll this block back (restores the deleted row and the settings).
      raise exception using errcode = 'ZS001',
        message = case when v_before and not v_after then 'pass'
                       when not v_before then 'customer_cannot_read_current'
                       else 'customer_can_read_old' end;
    exception
      when sqlstate 'ZS001' then v_result := sqlerrm;
      when others then v_result := 'test_error: ' || sqlerrm;
    end;
  end if;

  perform set_config('zs.archive_policy_test', v_result, true);
  if v_result = 'pass' then
    execute 'drop trigger if exists zs_reports_after_delete on public.reports';
    execute 'create trigger zs_reports_after_delete after delete on public.reports
               for each row execute function public.zs_archive_report()';
    raise notice 'ARKIB DIHIDUPKAN: pelanggan tidak boleh membaca PDF selepas baris reports dipadam.';
  else
    execute 'drop trigger if exists zs_reports_after_delete on public.reports';
    raise warning 'ARKIB DIHENTIKAN (%): laman akan terus memadam PDF lama semasa penggantian. Betulkan polisi storage similarity-reports, kemudian jalankan semula migrasi ini.', v_result;
  end if;
end $$;

-- The website asks this before replacing a report: true = keep the old PDF.
-- Informational for the admin UI. The website does NOT rely on it to keep a PDF:
-- it keeps an old PDF only when the archive row for that exact report exists
-- (written by the trigger in the same transaction as the delete).
create or replace function public.zs_archive_enabled()
returns boolean language sql stable security definer set search_path = '' as $$
  select public.is_admin() and exists (
    select 1 from pg_trigger t
     where t.tgrelid = 'public.reports'::regclass
       and t.tgname = 'zs_reports_after_delete'
       and not t.tgisinternal
       and t.tgenabled in ('O','A')                                   -- enabled (origin / always), not D or R
       and t.tgfoid = 'public.zs_archive_report()'::regprocedure)
$$;

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
-- D. Status history
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
--     new check. CREATE OR REPLACE keeps the function's existing grants.
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
-- F. Leased notification claims
-- ---------------------------------------------------------------------
-- state:  claimed = a sender holds it until lease_until;
--         sent    = provider accepted it (existing rows default to this);
--         unknown = outcome uncertain (no response from the provider); never
--                   retried automatically, an admin decides.
alter table public.zs_notification_log
  add column if not exists state       text not null default 'sent',
  add column if not exists lease_until timestamptz,
  add column if not exists attempts    integer not null default 1,
  add column if not exists claim_token uuid,
  add column if not exists updated_at  timestamptz not null default now();
alter table public.zs_notification_log drop constraint if exists zs_notification_log_state_check;
alter table public.zs_notification_log add constraint zs_notification_log_state_check
  check (state in ('claimed','sent','unknown'));

-- Claim: free, or a previous claim whose lease has expired. Each successful claim gets a
-- NEW random claim_token; the caller receives (token, lease_until). No row = not claimed.
create or replace function public.zs_claim_notification(p_kind text, p_ref uuid, p_lease_seconds integer default 300)
returns table (claim_token uuid, lease_until timestamptz)
language plpgsql security definer set search_path = '' as $$
declare v_lease interval := make_interval(secs => greatest(p_lease_seconds, 30));
begin
  return query
  insert into public.zs_notification_log as l
         (kind, ref_id, state, lease_until, attempts, claim_token, created_at, updated_at)
  values (p_kind, p_ref, 'claimed', now() + v_lease, 1, gen_random_uuid(), now(), now())
  on conflict (kind, ref_id) do update
     set state = 'claimed', lease_until = now() + v_lease, attempts = l.attempts + 1,
         claim_token = gen_random_uuid(), updated_at = now()
   where l.state = 'claimed' and l.lease_until < now()
  returning l.claim_token, l.lease_until;
end; $$;

-- Finish: 'sent' (accepted), 'unknown' (no response) or 'released' (definite failure:
-- lease ends now so a retry may claim it). Updates ONLY the claim holding p_token, so a
-- process whose lease expired and was taken over cannot overwrite the new claim.
-- Returns true if this token still owned the claim.
create or replace function public.zs_finish_notification(p_kind text, p_ref uuid, p_token uuid, p_outcome text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_n int;
begin
  if p_outcome not in ('sent','unknown','released') then
    raise exception 'outcome tidak sah: %', p_outcome;
  end if;
  update public.zs_notification_log
     set state       = case p_outcome when 'released' then 'claimed' else p_outcome end,
         lease_until = case p_outcome when 'released' then now() else null end,
         claim_token = null,
         updated_at  = now()
   where kind = p_kind and ref_id = p_ref and state = 'claimed' and claim_token = p_token;
  get diagnostics v_n = row_count;
  return v_n = 1;
end; $$;

-- ---------------------------------------------------------------------
-- G. E-mail retry, keyed on when the order BECAME report_ready
-- ---------------------------------------------------------------------
-- Attempt 1 = the existing zs_orders_notify_report_ready trigger.
-- Retries (max 5, every 15 min, within 3 days) only while the log has no row
-- or holds an EXPIRED claim. 'sent' and 'unknown' are never retried.
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
      left join public.zs_notification_log l on l.kind = 'report_ready' and l.ref_id = o.id
     where o.status = 'report_ready'
       and t.ready_at is not null
       and t.ready_at < now() - interval '10 minutes'
       and t.ready_at > now() - interval '3 days'
       and (l.ref_id is null or (l.state = 'claimed' and l.lease_until < now()))
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
-- H. Orphan payment proofs (uploaded, never linked to a payments row)
-- ---------------------------------------------------------------------
-- Never returns a file younger than 24 hours, whatever p_min_age is passed.
create or replace function public.zs_orphan_payment_proofs(p_min_age interval default interval '24 hours')
returns table (name text, created_at timestamptz) language sql stable security definer set search_path = '' as $$
  select so.name, so.created_at from storage.objects so
   where so.bucket_id = 'payment-proofs'
     and so.created_at < now() - greatest(p_min_age, interval '24 hours')
     and not exists (select 1 from public.payments p where p.proof_path = so.name)
   order by so.created_at
   limit 500
$$;

-- ---------------------------------------------------------------------
-- Function privileges (zs_prepare_payment's grants are NOT changed here;
-- its original ACL is in zs_migration_backup for the rollback).
-- ---------------------------------------------------------------------
revoke execute on function
  public.zs_after_payment_review(), public.zs_after_report_insert(), public.zs_archive_report(),
  public.zs_log_order_status(), public.zs_retry_report_notifications(),
  public.zs_orphan_payment_proofs(interval),
  public.zs_claim_notification(text, uuid, integer), public.zs_finish_notification(text, uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.zs_orphan_payment_proofs(interval) to service_role;
grant execute on function public.zs_claim_notification(text, uuid, integer) to service_role;
grant execute on function public.zs_finish_notification(text, uuid, uuid, text) to service_role;
revoke execute on function public.zs_archive_enabled() from public, anon;
grant execute on function public.zs_archive_enabled() to authenticated;

commit;
