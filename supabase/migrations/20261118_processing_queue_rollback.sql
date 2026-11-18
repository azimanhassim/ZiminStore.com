-- =====================================================================
-- ROLLBACK for 20261118_processing_queue.sql
-- STATUS: DRAFT. Run only if the migration was applied and must be undone.
--
-- One transaction. Restores zs_prepare_payment to the exact live version read on
-- 18 Nov 2026, removes every trigger, index, cron job and function the migration
-- added. The two tables are KEPT by default (they hold history and the archive
-- index of replaced reports); dropping them is a separate, commented step below.
-- Old report PDFs stay in the "similarity-reports" bucket either way.
-- =====================================================================

begin;

-- Cron job (only if present)
select cron.unschedule(jobid) from cron.job where jobname = 'zs-notify-retry';

-- Triggers
drop trigger if exists zs_payments_after_review on public.payments;
drop trigger if exists zs_reports_after_insert  on public.reports;
drop trigger if exists zs_reports_after_delete  on public.reports;
drop trigger if exists zs_orders_log_status     on public.orders;

-- Duplicate-proof index
drop index if exists public.zs_payments_one_pending;

-- zs_prepare_payment: original live definition (without the "already verified" check)
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

-- New functions
drop function if exists public.zs_after_payment_review();
drop function if exists public.zs_after_report_insert();
drop function if exists public.zs_archive_report();
drop function if exists public.zs_log_order_status();
drop function if exists public.zs_retry_report_notifications();
drop function if exists public.zs_orphan_payment_proofs(interval);

commit;

-- ---------------------------------------------------------------------
-- OPTIONAL, IRREVERSIBLE: delete the history and the archive index.
-- Old PDFs remain in storage but would no longer be listed anywhere.
-- Uncomment only if that is really wanted.
-- ---------------------------------------------------------------------
-- begin;
-- drop table if exists public.zs_report_archive;
-- drop table if exists public.zs_order_events;
-- commit;
