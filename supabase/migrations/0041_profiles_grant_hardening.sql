-- 0041_profiles_grant_hardening.sql
--
-- profiles and templates were left with blanket table grants to anon and
-- authenticated. RLS is what actually holds them shut, and for anon it does:
-- there is no anon policy, so every read and write is denied. For a SIGNED-IN
-- caller it does not, because profiles_update_own permits any update to the
-- caller's own row -- and premium_until lives on that row.
--
-- The gap: PATCH /rest/v1/profiles?id=eq.<own uid>
--           {"premium_until":"2099-01-01T00:00:00Z"}
-- grants the caller permanent premium. df20_premium_active() reads that column
-- and nothing else, exactly as designed, so every gate in the app opens.
--
-- The fix is column-scoped grants. The app only ever writes the five identity
-- and branding columns (HostClient.tsx saveProfile); premium_until,
-- premium_source, subscription_status and the stripe_* columns are written
-- solely by df20_apply_billing_event / df20_revoke_premium / admin_set_premium,
-- which are SECURITY DEFINER and bypass grants. export_* is written by
-- save_export_style, likewise SECURITY DEFINER. So nothing legitimate loses a
-- write path here.
--
-- Re-runnable. Grants are idempotent and revokes on already-revoked
-- privileges are a no-op.

-- anon has no policy on either table and therefore no legitimate access at all
revoke all on public.profiles  from anon;
revoke all on public.templates from anon;

-- drop the blanket write grants before re-issuing them per column
revoke insert, update, delete, truncate, references on public.profiles from authenticated;

-- what the app genuinely writes, and nothing else
grant select on public.profiles to authenticated;
grant insert (id, email, display_name, brand_accent, brand_logo_url)
  on public.profiles to authenticated;
grant update (email, display_name, brand_accent, brand_logo_url)
  on public.profiles to authenticated;

-- templates carries no privileged column, but it does not need DDL-adjacent
-- privileges either
revoke truncate, references on public.templates from authenticated;

-- Assert the hole is actually shut, both ways round, the way v6_premium.sql
-- asserts the watermark. A blanket re-grant on profiles (a future
-- "grant all on all tables in schema public to authenticated" would do it)
-- silently reopens permanent free premium for every signed-in user, so this
-- fails loudly rather than waiting to be noticed.
do $$
declare v_bad text[] := '{}';
begin
  -- privileged columns must NOT be writable by a signed-in caller
  if has_column_privilege('authenticated','public.profiles','premium_until','UPDATE')
    then v_bad := v_bad || 'authenticated can UPDATE profiles.premium_until'; end if;
  if has_column_privilege('authenticated','public.profiles','premium_source','UPDATE')
    then v_bad := v_bad || 'authenticated can UPDATE profiles.premium_source'; end if;
  if has_column_privilege('authenticated','public.profiles','subscription_status','UPDATE')
    then v_bad := v_bad || 'authenticated can UPDATE profiles.subscription_status'; end if;
  if has_column_privilege('authenticated','public.profiles','stripe_customer_id','UPDATE')
    then v_bad := v_bad || 'authenticated can UPDATE profiles.stripe_customer_id'; end if;
  if has_table_privilege('anon','public.profiles','SELECT')
    then v_bad := v_bad || 'anon can SELECT profiles'; end if;

  -- NO assertion here that the branding columns are still writable. 0042
  -- revokes every write grant on this table and moves the write behind
  -- save_profile(), so asserting the grants this file just issued would be
  -- asserting an intermediate state that the very next migration removes on
  -- purpose. df20_grant_check() in 0042 is the assertion that describes the
  -- end state; this one only has to say the privileged columns are shut.

  if coalesce(array_length(v_bad,1),0) > 0 then
    raise exception E'DF20_PROFILE_GRANTS_WRONG\n  %', array_to_string(v_bad, E'\n  ');
  end if;
  raise notice 'profiles grants ok - premium columns are RPC-only';
end $$;
