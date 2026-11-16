-- ZiminStore: pemadaman dokumen pelanggan selepas 30 hari.
-- SUDAH DIPASANG pada 16 Nov 2026 (migration zs_retention_30_days). Fail ini ialah rekod.
-- Edge Function zs-cleanup (supabase/functions/zs-cleanup) memadam fail melalui Storage API
-- dan menanda documents.storage_path = 'deleted/<id>'. Tiada secret diperlukan.
create extension if not exists pg_cron;
select cron.schedule('zs-cleanup-daily', '30 19 * * *',   -- 03:30 pagi waktu Malaysia
  $$ select net.http_post(
       url := 'https://vletiqtwzzrktttzxyej.supabase.co/functions/v1/zs-cleanup',
       headers := '{"Content-Type": "application/json"}'::jsonb,
       body := '{}'::jsonb,
       timeout_milliseconds := 30000) $$);

-- Semak:   select * from cron.job_run_details order by start_time desc limit 5;
-- Hentikan: select cron.unschedule('zs-cleanup-daily');
