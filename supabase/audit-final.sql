-- =====================================================================
-- ZiminStore: FINAL SECURITY AUDIT (READ-ONLY)
--
-- One SELECT statement. It reads the system catalogs only and changes
-- nothing (no insert/update/delete/alter/create/drop/grant/revoke).
-- Run it ONCE in Supabase Dashboard -> SQL Editor, then export the result
-- (CSV) or copy the whole table and send it back.
--
-- Columns:  kod | bahagian | semakan | keputusan | butiran
--   keputusan = PASS  : check passed
--               FAIL  : real gap, must be fixed
--               SEMAK : could not be proven automatically, needs a human look
--               INFO  : inventory row (policies, triggers, functions)
--
-- Heuristics used: a policy counts as "admin only" when its text calls
-- is_admin() or compares with 'admin'; as "own rows" when it uses auth.uid().
-- =====================================================================
with
tbl(name) as (values ('profiles'),('orders'),('documents'),('payments'),('reports')),
bkt(id) as (values ('customer-documents'),('payment-proofs'),('similarity-reports')),
pol as (
  select schemaname as sch, tablename as tab, policyname as name, permissive, roles::text[] as roles, cmd,
         coalesce(qual,'') as q, coalesce(with_check,'') as w
  from pg_policies
  where (schemaname = 'public' and tablename in (select name from tbl))
     or (schemaname = 'storage' and tablename = 'objects')
),
-- one row per policy per real command (ALL -> SELECT/INSERT/UPDATE/DELETE)
pc as (
  select p.*, c as op,
         case when c = 'INSERT' then coalesce(nullif(p.w,''), p.q)
              when c = 'UPDATE' then p.q || ' ' || p.w
              else p.q end as gate
  from pol p
  cross join lateral unnest(case when p.cmd = 'ALL' then array['SELECT','INSERT','UPDATE','DELETE'] else array[p.cmd] end) c
),
-- policies that let NON-admin signed-in users through
cust as (
  select * from pc
  where permissive = 'PERMISSIVE'
    and roles && array['authenticated','public']
    and gate !~* '(is_admin\(|''admin'')'
),
adm as (
  select * from pc
  where permissive = 'PERMISSIVE'
    and roles && array['authenticated','public']
    and gate ~* '(is_admin\(|''admin'')'
),
restr as (select * from pc where permissive = 'RESTRICTIVE'),
fn as (
  select p.oid, p.proname, p.prosecdef, p.proconfig, pg_get_functiondef(p.oid) as def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prokind = 'f'
),
trg as (
  select n.nspname as sch, c.relname as tab, t.tgname, p.proname as fname,
         case when p.prokind = 'f' then pg_get_functiondef(p.oid) else '' end as def,
         (t.tgtype & 2) <> 0 as before_, (t.tgtype & 4) <> 0 as on_ins, (t.tgtype & 16) <> 0 as on_upd,
         t.tgenabled
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  join pg_proc p on p.oid = t.tgfoid
  where not t.tgisinternal
    and ((n.nspname = 'public' and c.relname in (select name from tbl))
      or (n.nspname = 'auth' and c.relname = 'users'))
),
need(tab, col) as (values
  ('profiles','id'),('profiles','full_name'),('profiles','role'),('profiles','phone'),
  ('orders','id'),('orders','order_number'),('orders','customer_id'),('orders','document_count'),
  ('orders','total_sen'),('orders','status'),('orders','created_at'),('orders','updated_at'),
  ('documents','id'),('documents','order_id'),('documents','customer_id'),('documents','original_filename'),
  ('documents','storage_path'),('documents','file_type'),
  ('payments','id'),('payments','order_id'),('payments','customer_id'),('payments','amount_sen'),
  ('payments','proof_path'),('payments','status'),('payments','verified_at'),('payments','created_at'),
  ('reports','id'),('reports','order_id'),('reports','document_id'),('reports','customer_id'),('reports','report_path')
),
cols as (
  select table_name as tab, column_name as col from information_schema.columns where table_schema = 'public'
),
-- helper: column privilege that does not error when the column is missing
cp(tab, col, priv, ok) as (
  select n.tab, n.col, v.priv,
         case when exists (select 1 from cols c where c.tab = n.tab and c.col = n.col)
              then has_column_privilege('authenticated', format('public.%I', n.tab), n.col, v.priv) end
  from need n cross join (values ('INSERT'),('UPDATE')) v(priv)
),
r as (
-- ---------------------------------------------------------------- A. Structure
select 'A1' kod, 'Struktur' bahagian, 'Lajur diperlukan oleh index.html: ' || n.tab || '.' || n.col semakan,
       case when exists (select 1 from cols c where c.tab = n.tab and c.col = n.col) then 'PASS' else 'FAIL' end keputusan,
       case when exists (select 1 from cols c where c.tab = n.tab and c.col = n.col) then 'wujud' else 'TIADA: portal akan gagal pada bahagian ini' end butiran
from need n
union all
select 'A2', 'Struktur', 'Foreign key ' || x.child || '.order_id -> orders.id',
       case when exists (
         select 1 from pg_constraint k
         where k.contype = 'f' and k.conrelid = format('public.%I', x.child)::regclass
           and k.confrelid = 'public.orders'::regclass) then 'PASS' else 'FAIL' end,
       'Diperlukan untuk memuatkan dokumen/bayaran/laporan bersama pesanan'
from (values ('documents'),('payments'),('reports')) x(child)
where to_regclass('public.' || x.child) is not null and to_regclass('public.orders') is not null
union all
-- ---------------------------------------------------------------- B. RLS
select 'B1', 'RLS', 'RLS aktif: ' || t.name,
       case when c.relrowsecurity then 'PASS' else 'FAIL' end,
       case when c.relrowsecurity then 'enabled' else 'RLS TIDAK AKTIF: semua baris terdedah' end
from tbl t left join pg_class c on c.oid = to_regclass('public.' || t.name)
union all
select 'B2', 'RLS', 'Polisi untuk anon/public: ' || p.tab || ' / ' || p.name,
       'FAIL', 'roles=' || array_to_string(p.roles, ',') || ' cmd=' || p.cmd || ' : pengguna belum log masuk juga terlibat'
from pol p where p.roles && array['anon','public']
union all
select 'B3', 'RLS', 'Polisi terbuka (true): ' || p.sch || '.' || p.tab || ' / ' || p.name,
       'FAIL', 'cmd=' || p.cmd || ' using=' || p.q || ' check=' || p.w
from pol p
where p.permissive = 'PERMISSIVE' and (btrim(p.q) = 'true' or btrim(p.w) = 'true')
union all
-- overlapping permissive policies on the same public table + command (they are OR-ed)
select 'B4', 'Pertindihan', 'Polisi bertindih: public.' || tab || ' ' || op,
       'SEMAK', count(*) || ' polisi permissive digabung dengan OR: ' || string_agg(name, ' | ' order by name)
from pc where sch = 'public' and permissive = 'PERMISSIVE'
group by tab, op having count(*) > 1
union all
-- overlapping storage policies per bucket + command
select 'B5', 'Pertindihan', 'Polisi storage bertindih: ' || b.id || ' ' || pc.op,
       'SEMAK', count(*) || ' polisi: ' || string_agg(pc.name, ' | ' order by pc.name)
from pc join bkt b on (pc.q || pc.w) like '%' || b.id || '%'
where pc.sch = 'storage' and pc.permissive = 'PERMISSIVE'
group by b.id, pc.op having count(*) > 1
union all
select 'B6', 'Pertindihan', 'Polisi storage tanpa nama bucket: ' || p.name,
       'SEMAK', 'cmd=' || p.cmd || ' : terpakai kepada SEMUA bucket. using=' || p.q || ' check=' || p.w
from pol p
where p.sch = 'storage' and p.q || p.w !~ 'bucket_id'
union all
select 'B7', 'Pertindihan', 'Polisi RESTRICTIVE: ' || p.sch || '.' || p.tab || ' / ' || p.name,
       'SEMAK', 'cmd=' || p.cmd || ' using=' || p.q || ' check=' || p.w
from pol p where p.permissive = 'RESTRICTIVE'
union all
-- ---------------------------------------------------------------- C. Role
select 'C1', 'Role', 'Pelanggan tidak boleh tukar profiles.role',
       case
         when not exists (select 1 from cust where tab = 'profiles' and op = 'UPDATE') then 'PASS'
         when (select ok from cp where tab = 'profiles' and col = 'role' and priv = 'UPDATE') is false then 'PASS'
         when exists (select 1 from trg where tab = 'profiles' and before_ and on_upd and def ~* 'role') then 'PASS'
         else 'FAIL' end,
       case
         when not exists (select 1 from cust where tab = 'profiles' and op = 'UPDATE') then 'Tiada polisi UPDATE pelanggan pada profiles'
         when (select ok from cp where tab = 'profiles' and col = 'role' and priv = 'UPDATE') is false then 'Kebenaran lajur: authenticated tidak boleh UPDATE role'
         when exists (select 1 from trg where tab = 'profiles' and before_ and on_upd and def ~* 'role')
           then 'Trigger pengawal: ' || (select string_agg(tgname, ', ') from trg where tab = 'profiles' and before_ and on_upd and def ~* 'role')
         else 'Polisi ' || (select string_agg(distinct name, ', ') from cust where tab = 'profiles' and op = 'UPDATE')
              || ' membenarkan UPDATE dan lajur role boleh ditulis, tiada trigger pengawal' end
union all
select 'C2', 'Role', 'Pelanggan tidak boleh INSERT/DELETE profil sendiri (cara lain jadi admin)',
       case when exists (select 1 from cust where tab = 'profiles' and op in ('INSERT','DELETE'))
                 and coalesce((select ok from cp where tab = 'profiles' and col = 'role' and priv = 'INSERT'), false)
            then 'FAIL' else 'PASS' end,
       coalesce('Polisi: ' || (select string_agg(distinct name || ' (' || op || ')', ', ') from cust where tab = 'profiles' and op in ('INSERT','DELETE')),
                'Tiada polisi INSERT/DELETE pelanggan pada profiles')
union all
select 'C3', 'Role', 'Trigger pendaftaran pada auth.users wujud',
       case when exists (select 1 from trg where sch = 'auth' and on_ins and tgenabled <> 'D') then 'PASS' else 'FAIL' end,
       coalesce((select string_agg(tgname || ' -> ' || fname, ', ') from trg where sch = 'auth'),
                'Tiada: profil tidak dicipta semasa daftar')
union all
select 'C4', 'Role', 'Trigger pendaftaran tidak mengambil role daripada data pendaftaran',
       case when exists (select 1 from trg where sch = 'auth' and def ~* 'raw_user_meta_data\s*->>?\s*''role''') then 'FAIL'
            when exists (select 1 from trg where sch = 'auth') then 'PASS' else 'SEMAK' end,
       case when exists (select 1 from trg where sch = 'auth' and def ~* 'raw_user_meta_data\s*->>?\s*''role''')
            then 'Fungsi menyalin role dari raw_user_meta_data: sesiapa boleh daftar sebagai admin'
            else 'Tiada rujukan role dari metadata' end
union all
select 'C5', 'Role', 'Bilangan admin',
       case when (select count(*) from public.profiles where role = 'admin') between 1 and 3 then 'PASS' else 'SEMAK' end,
       (select count(*) from public.profiles where role = 'admin')::text || ' admin'
where to_regclass('public.profiles') is not null
union all
-- ---------------------------------------------------------------- D. Price / status
select 'D1', 'Harga', 'Pelanggan tidak boleh UPDATE pesanan',
       case when not exists (select 1 from cust where tab = 'orders' and op = 'UPDATE') then 'PASS'
            when exists (select 1 from trg where tab = 'orders' and before_ and on_upd) then 'SEMAK'
            else 'FAIL' end,
       coalesce('Polisi UPDATE pelanggan: ' || (select string_agg(distinct name, ', ') from cust where tab = 'orders' and op = 'UPDATE')
                || coalesce('; trigger: ' || (select string_agg(tgname, ', ') from trg where tab = 'orders' and before_ and on_upd), ''),
                'Hanya admin boleh UPDATE orders')
union all
select 'D2', 'Harga', 'Harga (total_sen) ditetapkan oleh database semasa INSERT',
       case when (select ok from cp where tab = 'orders' and col = 'total_sen' and priv = 'INSERT') is false then 'PASS'
            when exists (select 1 from trg where tab = 'orders' and before_ and on_ins and def ~* 'total_sen\s*:?=') then 'PASS'
            when exists (select 1 from cust where tab = 'orders' and op = 'INSERT' and gate ~* 'total_sen') then 'SEMAK'
            else 'FAIL' end,
       coalesce('Trigger: ' || (select string_agg(tgname, ', ') from trg where tab = 'orders' and before_ and on_ins and def ~* 'total_sen\s*:?='),
                'Pelanggan boleh menghantar sebarang total_sen semasa mencipta pesanan')
union all
select 'D3', 'Harga', 'Status pesanan baharu ditetapkan oleh database semasa INSERT',
       case when (select ok from cp where tab = 'orders' and col = 'status' and priv = 'INSERT') is false then 'PASS'
            when exists (select 1 from trg where tab = 'orders' and before_ and on_ins and def ~* 'status\s*:?=') then 'PASS'
            when exists (select 1 from cust where tab = 'orders' and op = 'INSERT' and gate ~* 'pending_payment') then 'PASS'
            else 'FAIL' end,
       coalesce('Trigger/polisi: ' || nullif(concat_ws(', ',
                  (select string_agg(tgname, ', ') from trg where tab = 'orders' and before_ and on_ins and def ~* 'status\s*:?='),
                  (select string_agg(distinct name, ', ') from cust where tab = 'orders' and op = 'INSERT' and gate ~* 'pending_payment')), ''),
                'Pelanggan boleh mencipta pesanan terus dengan status report_ready')
union all
select 'D4', 'Bayaran', 'Pelanggan tidak boleh UPDATE bayaran (contoh: status=verified)',
       case when not exists (select 1 from cust where tab = 'payments' and op = 'UPDATE') then 'PASS'
            when exists (select 1 from trg where tab = 'payments' and before_ and on_upd) then 'SEMAK'
            else 'FAIL' end,
       coalesce('Polisi UPDATE pelanggan: ' || (select string_agg(distinct name, ', ') from cust where tab = 'payments' and op = 'UPDATE'),
                'Hanya admin boleh UPDATE payments')
union all
select 'D5', 'Bayaran', 'Bayaran baharu: status dan amaun ditetapkan oleh database',
       case when exists (select 1 from trg where tab = 'payments' and before_ and on_ins and def ~* 'status\s*:?=' and def ~* 'amount_sen\s*:?=') then 'PASS'
            when exists (select 1 from cust where tab = 'payments' and op = 'INSERT' and gate ~* '''pending''') then 'SEMAK'
            else 'FAIL' end,
       case when exists (select 1 from trg where tab = 'payments' and before_ and on_ins and def ~* 'status\s*:?=' and def ~* 'amount_sen\s*:?=')
            then 'Trigger: ' || (select string_agg(tgname, ', ') from trg where tab = 'payments' and before_ and on_ins)
            when exists (select 1 from cust where tab = 'payments' and op = 'INSERT' and gate ~* '''pending''')
            then 'Polisi memaksa status pending, tetapi amount_sen masih dari pelayar (hanya maklumat, admin tetap semak resit)'
            else 'Pelanggan boleh INSERT bayaran dengan status verified sendiri' end
union all
select 'D6', 'Bayaran', 'Pelanggan tidak boleh INSERT laporan',
       case when exists (select 1 from cust where tab = 'reports' and op = 'INSERT') then 'FAIL' else 'PASS' end,
       coalesce('Polisi: ' || (select string_agg(distinct name, ', ') from cust where tab = 'reports' and op = 'INSERT'), 'Hanya admin')
union all
select 'D7', 'Bayaran', 'Pelanggan tidak boleh UPDATE/DELETE dokumen atau laporan',
       case when exists (select 1 from cust where tab in ('documents','reports') and op in ('UPDATE','DELETE')) then 'SEMAK' else 'PASS' end,
       coalesce('Polisi: ' || (select string_agg(distinct tab || '.' || name || ' (' || op || ')', ', ') from cust where tab in ('documents','reports') and op in ('UPDATE','DELETE')), 'Tiada')
union all
select 'D8', 'Akses', 'SELECT pelanggan terhad kepada baris sendiri: ' || t.name,
       case when exists (select 1 from cust where tab = t.name and op = 'SELECT' and gate !~* 'auth\.uid\(\)') then 'FAIL' else 'PASS' end,
       coalesce('Polisi tanpa auth.uid(): ' || (select string_agg(distinct name, ', ') from cust where tab = t.name and op = 'SELECT' and gate !~* 'auth\.uid\(\)'),
                'Semua polisi SELECT pelanggan menggunakan auth.uid()')
from tbl t
union all
-- ---------------------------------------------------------------- E. Storage
select 'E1', 'Storage', 'Bucket wujud dan private: ' || b.id,
       case when sb.id is null then 'FAIL' when sb.public then 'FAIL' else 'PASS' end,
       case when sb.id is null then 'Bucket tiada' when sb.public then 'PUBLIC: sesiapa yang tahu laluan boleh muat turun'
            else 'private; had saiz=' || coalesce(sb.file_size_limit::text, 'tiada') || '; jenis=' || coalesce(array_to_string(sb.allowed_mime_types, ','), 'tiada had') end
from bkt b left join storage.buckets sb on sb.id = b.id
union all
select 'E2', 'Storage', 'Had saiz/jenis fail pada bucket: ' || b.id,
       case when sb.file_size_limit is not null and sb.allowed_mime_types is not null then 'PASS' else 'SEMAK' end,
       'Disyorkan supaya had dikuatkuasakan oleh server, bukan pelayar sahaja'
from bkt b join storage.buckets sb on sb.id = b.id
union all
select 'E3', 'Storage', 'Pelanggan hanya boleh baca fail sendiri: ' || b.id,
       case when exists (select 1 from cust c where c.sch = 'storage' and c.op = 'SELECT'
                           and (c.gate like '%' || b.id || '%' or c.gate !~ 'bucket_id')
                           and c.gate !~* '(auth\.uid\(\)|foldername)') then 'FAIL' else 'PASS' end,
       coalesce('Polisi terlalu luas: ' || (select string_agg(distinct c.name, ', ') from cust c where c.sch = 'storage' and c.op = 'SELECT'
                           and (c.gate like '%' || b.id || '%' or c.gate !~ 'bucket_id') and c.gate !~* '(auth\.uid\(\)|foldername)'),
                'Semua polisi SELECT pelanggan menyemak pemilik/folder')
from bkt b
union all
select 'E4', 'Storage', 'Pelanggan tidak boleh upload ke similarity-reports',
       case when exists (select 1 from cust c where c.sch = 'storage' and c.op = 'INSERT'
                           and (c.gate like '%similarity-reports%' or c.gate !~ 'bucket_id')) then 'FAIL' else 'PASS' end,
       coalesce('Polisi: ' || (select string_agg(distinct c.name, ', ') from cust c where c.sch = 'storage' and c.op = 'INSERT'
                           and (c.gate like '%similarity-reports%' or c.gate !~ 'bucket_id')), 'Hanya admin')
union all
select 'E5', 'Storage', 'Upload pelanggan terhad kepada folder sendiri: ' || b.id,
       case when exists (select 1 from cust c where c.sch = 'storage' and c.op = 'INSERT'
                           and (c.gate like '%' || b.id || '%' or c.gate !~ 'bucket_id')
                           and c.gate !~* '(auth\.uid\(\)|foldername)') then 'FAIL' else 'PASS' end,
       'Laluan mesti bermula dengan <customer_id>/'
from bkt b where b.id <> 'similarity-reports'
union all
select 'E6', 'Storage', 'Pelanggan tidak boleh tulis ganti / padam fail: ' || b.id,
       case when exists (select 1 from cust c where c.sch = 'storage' and c.op in ('UPDATE','DELETE')
                           and (c.gate like '%' || b.id || '%' or c.gate !~ 'bucket_id')) then 'SEMAK' else 'PASS' end,
       coalesce('Polisi: ' || (select string_agg(distinct c.name || ' (' || c.op || ')', ', ') from cust c where c.sch = 'storage' and c.op in ('UPDATE','DELETE')
                           and (c.gate like '%' || b.id || '%' or c.gate !~ 'bucket_id')), 'Tiada')
from bkt b
union all
-- ---------------------------------------------------------------- F. Admin can work
select 'F1', 'Admin', 'Fungsi public.is_admin() selamat',
       case when not exists (select 1 from fn where proname = 'is_admin') then 'FAIL'
            when exists (select 1 from fn where proname = 'is_admin' and prosecdef and array_to_string(proconfig, ',') ~* 'search_path') then 'PASS'
            else 'SEMAK' end,
       coalesce((select 'security_definer=' || prosecdef || ' config=' || coalesce(array_to_string(proconfig, ','), 'tiada search_path')
                 from fn where proname = 'is_admin' limit 1), 'Tiada fungsi is_admin')
union all
select 'F2', 'Admin', 'Admin boleh ' || x.what,
       case when exists (select 1 from adm a where a.sch = x.sch and a.tab = x.tab and a.op = x.op
                           and (x.b is null or a.gate like '%' || x.b || '%' or a.gate !~ 'bucket_id'))
            then 'PASS' else 'FAIL' end,
       x.sch || '.' || x.tab || ' ' || x.op || coalesce(' (' || x.b || ')', '')
from (values
  ('lihat semua profil pelanggan','public','profiles','SELECT',null),
  ('lihat semua pesanan','public','orders','SELECT',null),
  ('kemas kini status pesanan','public','orders','UPDATE',null),
  ('lihat semua dokumen','public','documents','SELECT',null),
  ('lihat semua bayaran','public','payments','SELECT',null),
  ('sahkan / tolak bayaran','public','payments','UPDATE',null),
  ('rekod laporan','public','reports','INSERT',null),
  ('lihat semua laporan','public','reports','SELECT',null),
  ('muat turun dokumen pelanggan','storage','objects','SELECT','customer-documents'),
  ('lihat bukti bayaran','storage','objects','SELECT','payment-proofs'),
  ('upload laporan PDF','storage','objects','INSERT','similarity-reports'),
  ('muat turun laporan','storage','objects','SELECT','similarity-reports')
) x(what, sch, tab, op, b)
union all
select 'F3', 'Admin', 'Kebenaran lajur untuk portal: ' || c.tab || '.' || c.col || ' ' || c.priv,
       case when c.ok then 'PASS' when c.ok is null then 'FAIL' else 'FAIL' end,
       case when c.ok is null then 'lajur tiada' when c.ok then 'dibenarkan' else 'authenticated TIDAK boleh ' || c.priv || ': portal akan gagal' end
from cp c
where (c.tab, c.col, c.priv) in (
  ('orders','customer_id','INSERT'),('orders','document_count','INSERT'),('orders','status','UPDATE'),
  ('documents','order_id','INSERT'),('documents','storage_path','INSERT'),
  ('payments','order_id','INSERT'),('payments','proof_path','INSERT'),('payments','status','UPDATE'),
  ('reports','order_id','INSERT'),('reports','document_id','INSERT'),('reports','report_path','INSERT'))
union all
select 'F4', 'Admin', 'Kebenaran lajur yang index.html hantar: ' || c.tab || '.' || c.col || ' ' || c.priv,
       case when c.ok then 'PASS' else 'SEMAK' end,
       case when c.ok then 'dibenarkan (nilai mesti ditimpa oleh trigger/polisi, lihat D2/D3/D5)'
            when c.ok is null then 'lajur tiada (lihat A1)'
            else 'Ditolak: index.html menghantar lajur ini dan permintaan akan GAGAL dengan "permission denied"' end
from cp c
where (c.tab, c.col, c.priv) in (
  ('orders','total_sen','INSERT'),('orders','status','INSERT'),('payments','amount_sen','INSERT'),
  ('payments','status','INSERT'),('payments','verified_at','UPDATE'),('orders','updated_at','UPDATE'))
union all
select 'F5', 'Fungsi', 'SECURITY DEFINER tanpa search_path: ' || proname,
       'SEMAK', 'Tetapkan search_path = '''' untuk elak serangan search_path'
from fn where prosecdef and coalesce(array_to_string(proconfig, ','), '') !~* 'search_path'
union all
-- ---------------------------------------------------------------- I. Inventory
select 'I1', 'Inventori polisi', p.sch || '.' || p.tab || ' / ' || p.name, 'INFO',
       regexp_replace(p.permissive || ' ' || p.cmd || ' to ' || array_to_string(p.roles, ',') || ' | using: ' || p.q || ' | check: ' || p.w, '\s+', ' ', 'g')
from pol p
union all
select 'I2', 'Inventori trigger', t.sch || '.' || t.tab || ' / ' || t.tgname, 'INFO',
       (case when t.before_ then 'BEFORE' else 'AFTER' end) || (case when t.on_ins then ' INSERT' else '' end)
       || (case when t.on_upd then ' UPDATE' else '' end) || ' -> ' || t.fname || (case when t.tgenabled = 'D' then ' (DISABLED)' else '' end)
from trg t
union all
select 'I3', 'Inventori fungsi', f.proname, 'INFO',
       'security_definer=' || f.prosecdef || '; config=' || coalesce(array_to_string(f.proconfig, ','), '-') || '; ' ||
       left(regexp_replace(f.def, '\s+', ' ', 'g'), 1500)
from fn f
)
select kod, bahagian, semakan, keputusan, regexp_replace(butiran, '\s+', ' ', 'g') as butiran
from r
order by case keputusan when 'FAIL' then 0 when 'SEMAK' then 1 when 'PASS' then 2 else 3 end, kod, semakan;
