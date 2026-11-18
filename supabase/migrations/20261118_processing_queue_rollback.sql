-- =====================================================================
-- ROLLBACK for 20261118_processing_queue.sql
-- STATUS: DRAFT. Run only if the migration was applied and must be undone.
--
-- Order: (1) redeploy zs-notify v3 (or keep v4: it falls back to the old claim
-- when the RPC functions are gone), (2) run this file.
--
-- One transaction. Restores zs_prepare_payment's definition AND its original
-- grants (from zs_migration_backup), removes every trigger, index, cron job,
-- function and column the migration added. History tables are KEPT by default;
-- dropping them is a separate, commented, irreversible step at the end.
-- Old report PDFs stay in the "similarity-reports" bucket either way.
-- =====================================================================

begin;

-- 0. The ACL backup must exist, otherwise grants cannot be restored exactly.
do $$
begin
  if not exists (select 1 from public.zs_migration_backup where key = '20261118:zs_prepare_payment:acl') then
    raise exception 'DIHENTIKAN: sandaran ACL zs_prepare_payment tiada; rollback tidak dapat memulihkan grants dengan tepat.';
  end if;
end $$;

-- 1. Cron job (only if present)
select cron.unschedule(jobid) from cron.job where jobname = 'zs-notify-retry';

-- 2. Triggers
drop trigger if exists zs_payments_after_review on public.payments;
drop trigger if exists zs_reports_after_insert  on public.reports;
drop trigger if exists zs_reports_after_delete  on public.reports;
drop trigger if exists zs_orders_log_status     on public.orders;

-- 3. Duplicate-proof index
drop index if exists public.zs_payments_one_pending;

-- 4. zs_prepare_payment: original live definition (without the "already verified" check)
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

-- 5. zs_prepare_payment grants: put back EXACTLY the ACL saved before the migration.
do $$
declare v_acl aclitem[]; v_owner oid; g record;
begin
  select acl into v_acl from public.zs_migration_backup where key = '20261118:zs_prepare_payment:acl';
  select proowner into v_owner from pg_proc where oid = 'public.zs_prepare_payment()'::regprocedure;

  if v_acl is null then
    -- NULL ACL = PostgreSQL default privileges: owner + EXECUTE for PUBLIC.
    -- (pg_proc cannot be edited without superuser, so restore the equivalent grants.)
    for g in select r.rolname from pg_roles r
              where r.oid in (select (aclexplode(p.proacl)).grantee from pg_proc p
                               where p.oid = 'public.zs_prepare_payment()'::regprocedure)
                and r.oid <> v_owner loop
      execute format('revoke all on function public.zs_prepare_payment() from %I', g.rolname);
    end loop;
    execute 'grant execute on function public.zs_prepare_payment() to public';
    raise notice 'zs_prepare_payment: hak dipulihkan kepada lalai (pemilik + PUBLIC EXECUTE).';
    return;
  else
    -- Start from nothing (owner keeps implicit rights), then re-grant each saved entry.
    execute 'revoke all on function public.zs_prepare_payment() from public';
    for g in select r.rolname from pg_roles r
              where r.oid in (select (aclexplode(p.proacl)).grantee from pg_proc p
                               where p.oid = 'public.zs_prepare_payment()'::regprocedure)
                and r.oid <> v_owner loop
      execute format('revoke all on function public.zs_prepare_payment() from %I', g.rolname);
    end loop;
    for g in select a.grantee, a.privilege_type, a.is_grantable from aclexplode(v_acl) a
              where a.grantee <> v_owner loop
      execute format('grant %s on function public.zs_prepare_payment() to %s%s',
                     g.privilege_type,
                     case when g.grantee = 0 then 'public' else quote_ident((select rolname from pg_roles where oid = g.grantee)) end,
                     case when g.is_grantable then ' with grant option' else '' end);
    end loop;
    raise notice 'zs_prepare_payment: ACL dipulihkan kepada %', v_acl;
  end if;

  if (select proacl from pg_proc where oid = 'public.zs_prepare_payment()'::regprocedure) is distinct from v_acl then
    raise warning 'SEMAK: ACL selepas pemulihan (%) berbeza susunan/pemberi daripada sandaran (%). Bandingkan hak sebenar.',
      (select proacl from pg_proc where oid = 'public.zs_prepare_payment()'::regprocedure), v_acl;
  end if;
end $$;

-- 6. Notification log: drop the lease columns. A row still 'claimed' was never
--    confirmed as sent, so it is removed (v3 may send it). 'unknown' rows are kept
--    as sent, to avoid a possible second e-mail.
delete from public.zs_notification_log where state = 'claimed';
alter table public.zs_notification_log drop constraint if exists zs_notification_log_state_check;
alter table public.zs_notification_log
  drop column if exists state,
  drop column if exists lease_until,
  drop column if exists attempts,
  drop column if exists updated_at;

-- 7. New functions
drop function if exists public.zs_after_payment_review();
drop function if exists public.zs_after_report_insert();
drop function if exists public.zs_archive_report();
drop function if exists public.zs_archive_enabled();
drop function if exists public.zs_log_order_status();
drop function if exists public.zs_retry_report_notifications();
drop function if exists public.zs_orphan_payment_proofs(interval);
drop function if exists public.zs_claim_notification(text, uuid, integer);
drop function if exists public.zs_finish_notification(text, uuid, text);

commit;

-- ---------------------------------------------------------------------
-- OPTIONAL, IRREVERSIBLE: delete the history, the archive index and the backup.
-- Old PDFs remain in storage but would no longer be listed anywhere.
-- ---------------------------------------------------------------------
-- begin;
-- drop table if exists public.zs_report_archive;
-- drop table if exists public.zs_order_events;
-- drop table if exists public.zs_migration_backup;
-- commit;
