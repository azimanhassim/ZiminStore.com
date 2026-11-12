-- =====================================================================
-- ZiminStore: READ-ONLY schema inspection
-- Run in Supabase Dashboard -> SQL Editor. It changes nothing.
-- For a single PASS/FAIL report, use audit-final.sql instead.
-- =====================================================================

-- 1. Tables and columns used by the site
select table_name, column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
  and table_name in ('profiles','orders','documents','payments','reports')
order by table_name, ordinal_position;

-- 2. Foreign keys (needed for the orders -> documents/payments/reports embeds)
select tc.table_name, kcu.column_name,
       ccu.table_schema as ref_schema, ccu.table_name as ref_table, ccu.column_name as ref_column,
       rc.delete_rule
from information_schema.table_constraints tc
join information_schema.key_column_usage kcu
  on tc.constraint_name = kcu.constraint_name and tc.table_schema = kcu.table_schema
join information_schema.constraint_column_usage ccu
  on tc.constraint_name = ccu.constraint_name
join information_schema.referential_constraints rc
  on tc.constraint_name = rc.constraint_name
where tc.constraint_type = 'FOREIGN KEY' and tc.table_schema = 'public'
order by tc.table_name;

-- 3. CHECK / UNIQUE constraints (status values, role values, order_number)
select conrelid::regclass as table_name, conname, pg_get_constraintdef(oid) as definition
from pg_constraint
where connamespace = 'public'::regnamespace and contype in ('c','u','p')
order by 1, 2;

-- 4. Is RLS enabled / forced?
select relname, relrowsecurity as rls_enabled, relforcerowsecurity as rls_forced
from pg_class
where relnamespace = 'public'::regnamespace
  and relname in ('profiles','orders','documents','payments','reports');

-- 5. All RLS policies on these tables
select tablename, policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('profiles','orders','documents','payments','reports')
order by tablename, cmd, policyname;

-- 6. Storage buckets
select id, name, public, file_size_limit, allowed_mime_types
from storage.buckets order by id;

-- 7. Storage policies
select policyname, permissive, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'storage' and tablename = 'objects'
order by policyname;

-- 8. Triggers on the site tables and on auth.users (profile creation)
select event_object_schema as schema, event_object_table as table_name,
       trigger_name, action_timing, event_manipulation, action_statement
from information_schema.triggers
where (event_object_schema = 'public'
       and event_object_table in ('profiles','orders','documents','payments','reports'))
   or (event_object_schema = 'auth' and event_object_table = 'users')
order by 1, 2, 3;

-- 9. Source of public functions (handle_new_user, is_admin, etc.)
select p.proname, p.prosecdef as security_definer,
       pg_get_function_identity_arguments(p.oid) as args,
       p.proconfig as settings,
       pg_get_functiondef(p.oid) as definition
from pg_proc p
where p.pronamespace = 'public'::regnamespace
order by p.proname;

-- 10. Table / column privileges for the browser roles
select grantee, table_name, privilege_type
from information_schema.role_table_grants
where table_schema = 'public' and grantee in ('anon','authenticated')
  and table_name in ('profiles','orders','documents','payments','reports')
order by table_name, grantee, privilege_type;

select grantee, table_name, column_name, privilege_type
from information_schema.column_privileges
where table_schema = 'public' and grantee in ('anon','authenticated')
  and table_name = 'profiles'
order by column_name, grantee, privilege_type;

-- 11. Who is admin right now?
select id, full_name, role from public.profiles where role <> 'customer';
