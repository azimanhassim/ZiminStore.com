-- =====================================================================
-- ZiminStore notifications:
--   * Telegram message to the admin when a payment proof is submitted.
--   * E-mail to the customer when an order becomes report_ready.
-- PROPOSED, NOT YET APPLIED. One transaction.
--
-- What it changes:
--   1. Enables the pg_net extension (async HTTP from the database).
--   2. New table public.zs_notification_log: one row per notification sent,
--      so the same payment is never announced twice. RLS on, no policies,
--      no grants: only the server (service role) can read or write it.
--   3. New AFTER INSERT trigger on public.payments and AFTER UPDATE trigger
--      on public.orders (only when status changes to report_ready) that call
--      the zs-notify Edge Function with the row id. pg_net is asynchronous:
--      if the call fails, the payment/order change still succeeds.
-- What it does NOT change: existing tables, columns, policies, triggers,
-- functions, storage or data.
-- =====================================================================
begin;

create extension if not exists pg_net with schema extensions;

create table if not exists public.zs_notification_log (
  kind       text        not null,
  ref_id     uuid        not null,
  created_at timestamptz not null default now(),
  primary key (kind, ref_id)
);
alter table public.zs_notification_log enable row level security;
revoke all on public.zs_notification_log from anon, authenticated;

create or replace function public.zs_notify_payment_submitted()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform net.http_post(
    url     := 'https://vletiqtwzzrktttzxyej.supabase.co/functions/v1/zs-notify',
    body    := jsonb_build_object('type', 'payment_submitted', 'id', new.id),
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 5000
  );
  return null;
end;
$$;
revoke execute on function public.zs_notify_payment_submitted() from public, anon, authenticated;

drop trigger if exists zs_payments_notify on public.payments;
create trigger zs_payments_notify
  after insert on public.payments
  for each row execute function public.zs_notify_payment_submitted();

create or replace function public.zs_notify_report_ready()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.status = 'report_ready' and old.status is distinct from 'report_ready' then
    perform net.http_post(
      url     := 'https://vletiqtwzzrktttzxyej.supabase.co/functions/v1/zs-notify',
      body    := jsonb_build_object('type', 'report_ready', 'id', new.id),
      headers := '{"Content-Type": "application/json"}'::jsonb,
      timeout_milliseconds := 5000
    );
  end if;
  return null;
end;
$$;
revoke execute on function public.zs_notify_report_ready() from public, anon, authenticated;

drop trigger if exists zs_orders_notify_report_ready on public.orders;
create trigger zs_orders_notify_report_ready
  after update of status on public.orders
  for each row execute function public.zs_notify_report_ready();

commit;

-- Undo (if ever needed):
--   drop trigger if exists zs_payments_notify on public.payments;
--   drop trigger if exists zs_orders_notify_report_ready on public.orders;
--   drop function if exists public.zs_notify_report_ready();
--   drop function if exists public.zs_notify_payment_submitted();
--   drop table if exists public.zs_notification_log;
