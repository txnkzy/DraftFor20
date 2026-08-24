-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0042 · the last direct table write, and a check that keeps
--                     0041 from silently coming undone
--
-- 0041 scoped the grants on public.profiles to the columns the app actually
-- writes. That closed the escalation, but it also broke the one place that
-- still wrote the table directly: HostClient.saveProfile() used a PostgREST
-- upsert, and PostgREST compiles an upsert to
--
--     insert ... on conflict (id) do update set id = excluded.id, ...
--
-- which needs UPDATE on `id`. Granting that back would work and would even be
-- safe (profiles_update_own's WITH CHECK pins id to auth.uid(), so the column
-- cannot be pointed at anyone else) — but it would leave the client holding a
-- write grant on a table that carries premium_until and stripe_customer_id,
-- and the next column added to that table would be exposed by default. That
-- is the shape of the bug 0041 just fixed.
--
-- So the write moves behind a SECURITY DEFINER function instead, exactly like
-- save_export_style, and `authenticated` keeps no write grant on profiles at
-- all. SELECT stays: RLS already scopes it to the caller's own row and two
-- pages read their own branding back.
--
-- Re-runnable.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── the profile write, as an RPC ──────────────────────────────────────────
-- Same validation the room branding already goes through: an accent must be
-- a hex colour, and a logo must live in our own storage bucket, because both
-- are rendered into an image other people end up looking at.
create or replace function public.save_profile(
  p_display_name text, p_brand_accent text, p_brand_logo_url text
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_uid uuid; v_name text; v_accent text;
begin
  -- creates the row on first save, and returns null when signed out
  v_uid := public.df20_ensure_profile();
  if v_uid is null then raise exception 'DF20_SIGNIN_REQUIRED'; end if;

  v_name := public.df20_clean_text(p_display_name, 40);
  if v_name = '' then v_name := null; end if;

  v_accent := public.df20_clean_text(p_brand_accent, 9);
  if v_accent = '' then v_accent := null; end if;
  if v_accent is not null and v_accent !~ '^#[0-9A-Fa-f]{6}$'
    then raise exception 'DF20_BAD_ACCENT'; end if;

  update public.profiles
     set display_name    = v_name,
         brand_accent    = v_accent,
         -- raises DF20_BAD_LOGO_URL on anything outside our storage bucket
         brand_logo_url  = public.df20_clean_logo_url(p_brand_logo_url),
         updated_at      = now()
   where id = v_uid;

  -- email is NOT taken from the caller. df20_ensure_profile reads it from
  -- auth.users, which is the only place it is authoritative.
  return (select jsonb_build_object(
                   'display_name', p.display_name,
                   'brand_accent', p.brand_accent,
                   'brand_logo_url', p.brand_logo_url)
            from public.profiles p where p.id = v_uid);
end $$;
grant execute on function public.save_profile(text, text, text) to authenticated;

-- ── nothing writes profiles directly any more ─────────────────────────────
revoke insert, update, delete, truncate, references on public.profiles from anon, authenticated;
revoke all on public.profiles from anon;
grant select on public.profiles to authenticated;

-- ── the assertion that keeps this fixed ───────────────────────────────────
-- df20_selfcheck() asserts that things EXIST. This asserts that things are
-- NOT reachable, which is the half that was missing when profiles shipped
-- with a blanket grant. Called from the end of the bundle next to selfcheck.
create or replace function public.df20_grant_check()
returns text language plpgsql stable as $$
declare
  v_bad text[] := '{}';
  c text;
  -- columns a signed-in caller must never be able to write to their own row.
  -- premium_until IS the premium gate; stripe_customer_id is the identity the
  -- billing portal opens a session for.
  v_locked text[] := array['premium_until','premium_source','subscription_status',
                           'stripe_customer_id','stripe_subscription_id',
                           'export_watermark','export_logo_url','export_accent',
                           'export_handle','id','created_at'];
begin
  foreach c in array v_locked loop
    if has_column_privilege('authenticated', 'public.profiles', c, 'UPDATE') then
      v_bad := v_bad || ('authenticated can UPDATE profiles.' || c);
    end if;
  end loop;

  if has_table_privilege('authenticated', 'public.profiles', 'INSERT') then
    v_bad := v_bad || 'authenticated can INSERT profiles (use save_profile)';
  end if;

  foreach c in array array['SELECT','INSERT','UPDATE','DELETE'] loop
    if has_table_privilege('anon', 'public.profiles', c) then
      v_bad := v_bad || ('anon can ' || c || ' profiles');
    end if;
    if has_table_privilege('anon', 'public.templates', c) then
      v_bad := v_bad || ('anon can ' || c || ' templates');
    end if;
  end loop;

  -- the read path the whole deck-secrecy rule rests on
  if has_table_privilege('anon', 'public.room_deck', 'SELECT')
     or has_table_privilege('authenticated', 'public.room_deck', 'SELECT') then
    v_bad := v_bad || 'room_deck is directly readable';
  end if;

  if coalesce(array_length(v_bad, 1), 0) > 0 then
    raise exception E'DF20_GRANT_CHECK_FAILED\n  %', array_to_string(v_bad, E'\n  ');
  end if;

  return format('ok - %s locked columns, anon shut out of profiles/templates, deck sealed',
                array_length(v_locked, 1));
end $$;
revoke all on function public.df20_grant_check() from anon, authenticated;

-- ── pin search_path on every remaining df20_ function ─────────────────────
-- All of these are SECURITY INVOKER, so none of them was the classic definer
-- hijack. Pinning them anyway costs nothing and clears the advisor, and means
-- a function that later becomes SECURITY DEFINER does not have to remember.
-- Generated rather than listed: a hardcoded signature list is the thing that
-- goes stale.
--
-- RUNS LAST, deliberately: it pins whatever exists at the time it runs, so
-- putting it above df20_grant_check() would skip the function this migration
-- had just created. That is exactly how the first pass left two behind.
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname like 'df20\_%'
              and p.proconfig is null
              and p.prokind = 'f'
  loop
    execute format('alter function %s set search_path = public, pg_temp', r.sig);
  end loop;
end $$;
