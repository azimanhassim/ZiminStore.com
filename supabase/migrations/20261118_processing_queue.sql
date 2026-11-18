-- =====================================================================
-- ZiminStore: processing queue, automatic status, history log, retry.
-- STATUS: DRAFT FOR REVIEW. NOT APPLIED. Run only after the owner approves.
--
-- What it adds (nothing existing is dropped or loosened):
--   1. public.zs_order_events  : processing history and error log (admin-only).
--   2. Automatic order status   : payment verified  -> order payment_verified
--                                 report inserted   -> processing / report_ready
--                                 (by DISTINCT documents with a report)
--   3. Status-change history    : every orders.status change is logged.
--   4. Duplicate guard          : at most one PENDING payment proof per order.
--   5. Notification retry       : every 15 min, re-calls zs-notify for orders that
--                                 are report_ready but have no 'report_ready' entry in
--                                 zs_notification_log (zs-notify itself sends once only).
-- The browser keeps its own status update as a fallback, so applying this file
-- (or not) does not break the current website.
-- =====================================================================

-- 1. History / error log ------------------------------------------------
create table if not exists public.zs_order_events (
  id         bigint generated always as identity primary key,
  order_id   uuid not null references public.orders(id) on delete cascade,
  kind       text not null check (kind in (
               'status_changed','payment_verified','payment_rejected','report_uploaded',
               'processing_started','action_required','note','notify_retry','error')),
  actor      uuid,                       -- auth.uid() when a person did it, null for the system
  detail     text check (char_length(detail) <= 500),
  created_at timestamptz not null default now()
);
create index if not exists zs_order_events_order_idx on public.zs_order_events (order_id, created_at desc);
alter table public.zs_order_events enable row level security;

drop policy if exists zs_order_events_admin_select on public.zs_order_events;
create policy zs_order_events_admin_select on public.zs_order_events
  for select to authenticated using (public.is_admin());

-- Admins may add their own notes (processing started, action required, note) from the portal.
drop policy if exists zs_order_events_admin_insert on public.zs_order_events;
create policy zs_order_events_admin_insert on public.zs_order_events
  for insert to authenticated
  with check (public.is_admin() and actor = auth.uid()
              and kind in ('processing_started','action_required','note'));
-- No update/delete policies: the history cannot be edited from the browser.

-- 2a. Payment verified -> order payment_verified ------------------------
create or replace function public.zs_after_payment_review()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status is distinct from old.status then
    if new.status = 'verified' then
      update public.orders set status = 'payment_verified'
       where id = new.order_id and status = 'pending_payment';
      insert into public.zs_order_events (order_id, kind, actor) values (new.order_id, 'payment_verified', auth.uid());
    elsif new.status = 'rejected' then
      insert into public.zs_order_events (order_id, kind, actor) values (new.order_id, 'payment_rejected', auth.uid());
    end if;
  end if;
  return null;
end; $$;
drop trigger if exists zs_payments_after_review on public.payments;
create trigger zs_payments_after_review after update of status on public.payments
  for each row execute function public.zs_after_payment_review();

-- 2b. Report inserted -> processing / report_ready ----------------------
create or replace function public.zs_after_report_insert()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_done int; v_need int; v_next text;
begin
  select count(distinct r.document_id) into v_done from public.reports r where r.order_id = new.order_id;
  select o.document_count into v_need from public.orders o where o.id = new.order_id;
  v_next := case when v_done >= v_need then 'report_ready' else 'processing' end;
  update public.orders set status = v_next
   where id = new.order_id and status in ('payment_verified','processing','action_required','report_ready')
     and status is distinct from v_next;
  insert into public.zs_order_events (order_id, kind, actor, detail)
  values (new.order_id, 'report_uploaded', auth.uid(), v_done || '/' || v_need || ' dokumen ada laporan');
  return null;
end; $$;
drop trigger if exists zs_reports_after_insert on public.reports;
create trigger zs_reports_after_insert after insert on public.reports
  for each row execute function public.zs_after_report_insert();

-- 3. Status-change history ------------------------------------------------
create or replace function public.zs_log_order_status()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status is distinct from old.status then
    insert into public.zs_order_events (order_id, kind, actor, detail)
    values (new.id, 'status_changed', auth.uid(), old.status || ' -> ' || new.status);
  end if;
  return null;
end; $$;
drop trigger if exists zs_orders_log_status on public.orders;
create trigger zs_orders_log_status after update of status on public.orders
  for each row execute function public.zs_log_order_status();

-- 4. One pending payment proof per order ----------------------------------
-- Check first: select order_id, count(*) from public.payments where status='pending' group by 1 having count(*)>1;
create unique index if not exists zs_payments_one_pending on public.payments (order_id) where status = 'pending';

-- 5. Notification retry -----------------------------------------------------
create or replace function public.zs_retry_report_notifications()
returns void language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in
    select o.id from public.orders o
     where o.status = 'report_ready'
       and o.updated_at < now() - interval '10 minutes'
       and o.updated_at > now() - interval '3 days'
       and not exists (select 1 from public.zs_notification_log l where l.kind = 'report_ready' and l.ref_id = o.id)
       and (select count(*) from public.zs_order_events e where e.order_id = o.id and e.kind = 'notify_retry') < 5
  loop
    perform net.http_post(
      url := 'https://vletiqtwzzrktttzxyej.supabase.co/functions/v1/zs-notify',
      body := jsonb_build_object('type','report_ready','id', r.id),
      headers := '{"Content-Type": "application/json"}'::jsonb,
      timeout_milliseconds := 10000);
    insert into public.zs_order_events (order_id, kind, detail) values (r.id, 'notify_retry', 'e-mel laporan siap dicuba semula');
  end loop;
end; $$;
select cron.schedule('zs-notify-retry', '*/15 * * * *', $$ select public.zs_retry_report_notifications() $$);

-- Trigger/cron functions are never called from the browser.
revoke execute on function public.zs_after_payment_review(), public.zs_after_report_insert(),
  public.zs_log_order_status(), public.zs_retry_report_notifications() from public, anon, authenticated;

-- Undo (if ever needed):
--   select cron.unschedule('zs-notify-retry');
--   drop trigger zs_payments_after_review on public.payments; drop trigger zs_reports_after_insert on public.reports;
--   drop trigger zs_orders_log_status on public.orders; drop index public.zs_payments_one_pending;
--   drop table public.zs_order_events;
