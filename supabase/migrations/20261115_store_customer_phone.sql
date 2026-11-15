-- =====================================================================
-- ZiminStore: keep customers' phone numbers in public.profiles
-- (so the admin portal can show a "WhatsApp pelanggan" button).
-- PROPOSED, NOT YET APPLIED. One transaction.
--
-- Why an upsert: auth.users has two sign-up triggers. on_auth_user_created
-- (handle_new_user) runs first and creates the profile WITHOUT a phone, so
-- zs_handle_new_user must fill the phone in on conflict instead of doing
-- nothing. Role is never taken from the sign-up data and never changed here.
--
-- Changes: replaces public.zs_handle_new_user(); copies phone numbers from
-- sign-up data into existing profiles that have none.
-- Does NOT change: tables, columns, policies, other triggers, roles.
-- Privacy: profiles RLS already limits phone to the customer and admins.
-- =====================================================================
begin;

create or replace function public.zs_handle_new_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_phone text := nullif(left(regexp_replace(coalesce(new.raw_user_meta_data ->> 'phone', ''), '[^0-9+ -]', '', 'g'), 20), '');
begin
  insert into public.profiles (id, full_name, phone, role)
  values (
    new.id,
    nullif(trim(coalesce(new.raw_user_meta_data ->> 'full_name', '')), ''),
    v_phone,
    'customer'
  )
  on conflict (id) do update
    set phone = coalesce(nullif(public.profiles.phone, ''), excluded.phone);
  return new;
end;
$$;
revoke execute on function public.zs_handle_new_user() from public, anon, authenticated;

-- Existing customers: copy the phone from their registration where the profile has none.
update public.profiles p
   set phone = nullif(left(regexp_replace(coalesce(u.raw_user_meta_data ->> 'phone', ''), '[^0-9+ -]', '', 'g'), 20), '')
  from auth.users u
 where u.id = p.id
   and coalesce(p.phone, '') = ''
   and coalesce(u.raw_user_meta_data ->> 'phone', '') <> '';

commit;
