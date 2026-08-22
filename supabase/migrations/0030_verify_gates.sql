-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0030 · the verification gate reaches the paths it claimed to
--
-- 0016 added df20_require_verified() and wired it to the custom-category
-- paths. It was never wired to the other two things the policy names:
--
--   custom categories  gated since 0016          ✓
--   premium purchase   never checked             ✗
--   admin functions    never checked             ✗
--
-- Both are fixed here. df20_is_admin() gaining a verification requirement is
-- the risky one — it is the check that guards the panel used to grant admin —
-- so the helper is DEFENSIVE in exactly the way 0016 is: an auth.users row it
-- cannot read counts as verified. The only way to lose admin is an explicit
-- null email_confirmed_at, never a permissions hiccup reading the table.
--
-- NOTE FOR WHOEVER READS THIS NEXT: with the project's "Confirm email"
-- setting OFF, Supabase stamps email_confirmed_at at signup and every check
-- here passes for everyone. These gates only start biting once that setting
-- is turned on in the dashboard. The code cannot turn it on.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.df20_email_verified(p_uid uuid)
returns boolean language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_confirmed timestamptz;
begin
  if p_uid is null then return false; end if;
  begin
    select u.email_confirmed_at into v_confirmed from auth.users u where u.id = p_uid;
  exception when others then
    return true;   -- column or table unreadable: do not invent a lockout
  end;
  return v_confirmed is not null;
end $$;
revoke all on function public.df20_email_verified(uuid) from anon, authenticated;

-- ── admin now requires a confirmed address ────────────────────────────────
create or replace function public.df20_is_admin()
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select (select auth.uid()) is not null
     and public.df20_email_verified((select auth.uid()))
     and (
       exists (select 1 from public.profiles p
                where p.id = (select auth.uid()) and p.is_admin)
       or exists (select 1 from public.df20_config c,
                       lateral unnest(string_to_array(c.value, ',')) u
                   where c.key = 'admin_user_ids'
                     and btrim(u) = (select auth.uid())::text)
     )
$$;
grant execute on function public.df20_is_admin() to anon, authenticated;

-- ── what the billing route asks before it opens a checkout session ───────
-- Answered here rather than read off the JWT so there is one definition of
-- "verified" in the system, and it is the database's.
create or replace function public.my_verification()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_uid uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then
    return jsonb_build_object('signed_in', false, 'verified', false);
  end if;
  return jsonb_build_object('signed_in', true,
                            'verified', public.df20_email_verified(v_uid));
end $$;
grant execute on function public.my_verification() to anon, authenticated;
