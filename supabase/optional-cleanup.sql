-- =====================================================================
-- ZiminStore: OPTIONAL clean-up from the final audit (NOT YET APPLIED)
--
-- The audit (supabase/audit-final.sql) returned 101 PASS, 0 FAIL, 0 SEMAK.
-- Nothing here is required for security. These are small tidy-ups.
-- Review first, then run in Supabase SQL Editor if you agree.
-- =====================================================================

-- 1. Supabase advisor warning: SECURITY DEFINER functions callable via /rest/v1/rpc.
--    Trigger functions never need EXECUTE for the browser roles; triggers still fire.
revoke execute on function
  public.handle_new_user(),
  public.zs_handle_new_user(),
  public.zs_prepare_order(),
  public.zs_prepare_payment(),
  public.zs_validate_document(),
  public.zs_validate_report(),
  public.zs_payment_update_timestamp()
  from public, anon, authenticated;

-- is_admin(): visitors don't need it. Signed-in users MUST keep it,
-- because every RLS policy calls it.
revoke execute on function public.is_admin() from public, anon;
grant  execute on function public.is_admin() to authenticated;

-- 2. Two registration triggers exist on auth.users. Both create the profile with
--    role 'customer'; the second one does nothing. Keep only the zs_ one, and let it
--    also store the phone number from the registration form.
drop trigger if exists on_auth_user_created on auth.users;

create or replace function public.zs_handle_new_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name, phone, role)
  values (
    new.id,
    nullif(trim(coalesce(new.raw_user_meta_data ->> 'full_name', '')), ''),
    nullif(left(regexp_replace(coalesce(new.raw_user_meta_data ->> 'phone', ''), '[^0-9+ -]', '', 'g'), 20), ''),
    'customer'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;
revoke execute on function public.zs_handle_new_user() from public, anon, authenticated;

-- 3. Not SQL: Dashboard -> Authentication -> Policies -> enable
--    "Leaked password protection".
