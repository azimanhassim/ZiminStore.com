-- =====================================================================
-- ZiminStore: Telegram notification when a payment proof is submitted.
-- PROPOSED, NOT YET APPLIED. One transaction.
--
-- What it changes:
--   1. Enables the pg_net extension (async HTTP from the database).
--   2. New table public.zs_notification_log: one row per notification sent,
--      so the same payment is never announced twice. RLS on, no policies,
--      no grants: only the server (service role) can read or write it.
--   3. New AFTER INSERT trigger on public.payments that calls the
--      zs-notify Edge Function with the new payment id. pg_net is
--      asynchronous: if the call fails, the payment insert still succeeds.
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

commit;

-- Undo (if ever needed):
--   drop trigger if exists zs_payments_notify on public.payments;
--   drop function if exists public.zs_notify_payment_submitted();
--   drop table if exists public.zs_notification_log;
