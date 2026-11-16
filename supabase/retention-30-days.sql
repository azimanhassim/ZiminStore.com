-- DRAF, BELUM DIJALANKAN. Tunggu kelulusan sebelum run di SQL Editor.
-- Langkah: (1) deploy Edge Function zs-cleanup, (2) set secret CLEANUP_SECRET dalam
-- Edge Function Secrets, (3) jalankan SQL ini dengan nilai secret yang sama.
-- Fail dipadam melalui Storage API (bukan delete terus pada storage.objects).
-- Baris documents dikekalkan (nama fail untuk rekod); storage_path ditanda 'deleted'.
-- NOTA: semak dahulu trigger zs_validate_document / zs_payments tidak menghalang update ini
-- (fungsi berjalan sebagai service_role, bypass RLS).
create extension if not exists pg_cron;
select cron.schedule('zs-cleanup-daily', '30 19 * * *',   -- 03:30 waktu Malaysia
  $$ select net.http_post(
       url := 'https://vletiqtwzzrktttzxyej.supabase.co/functions/v1/zs-cleanup',
       headers := jsonb_build_object('x-cleanup-secret', '<GANTI_DENGAN_CLEANUP_SECRET>', 'Content-Type','application/json'),
       body := '{}'::jsonb) $$);
