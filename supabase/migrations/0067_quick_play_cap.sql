-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0067 · Quick Play: three a day free, unlimited on premium
--
-- ENFORCED IN create_solo_room, NOT THE UI. The RPC is reachable with curl
-- and the anon key is public, so a client-side count is decoration. The old
-- five-argument form is DROPPED rather than left beside the new one, because
-- a signature without p_device_key bypasses the cap entirely.
--
-- WHAT IDENTIFIES A PLAYER. 97% of rooms are created anonymously, so there is
-- usually no account to count against. The cap keys on a device key stamped
-- into an httpOnly cookie — the same arrangement the audience vote uses, with
-- the same honest limit: clearing cookies gets you three more. Signed in it
-- keys on the account, which cookie-clearing cannot dodge.
--
-- MISSING KEY MEANS ALLOWED, which on its own is a free bypass — just omit
-- it. So solo rooms are created through /api/solo/create, which reads and
-- stamps the cookie SERVER-SIDE so the key is not the caller's to withhold,
-- and applies a loose per-IP backstop for anyone calling the RPC directly
-- with no cookie at all. Allowing the keyless case remains right at the SQL
-- layer: refusing a first-time player over a cookie that has not been issued
-- yet is the worst possible trade.
--
-- WHY IT IS SOFT. Quick Play exists to rescue the ~1 room in 4 that never
-- finds a second player. A hostile gate on it would cost more than it earns,
-- so three is enough to decide whether you like the game, two-player rooms
-- stay unlimited, and the message says so.
--
-- Also exposes lots.id from df20_bot_turn, so the route can budget one LLM
-- call per CARD instead of per turn: "do I want this" is asked once, and the
-- raises after it are arithmetic the heuristic does for free. ~25 calls a
-- draft becomes ~10.
--
-- Also renames the opponent to DraftFor20Bot. Existing rooms keep 'The
-- House': renaming a player inside a finished draft would rewrite a results
-- card somebody may already have posted.
--
-- Re-runnable.
-- ═══════════════════════════════════════════════════════════════════════════

-- Applied live on 2026-09-20; see git history for the full bodies of
-- df20_solo_quota, create_solo_room (6-arg) and df20_bot_turn.
alter table public.rooms add column if not exists solo_key text;

comment on column public.rooms.solo_key is
  'Who a Quick Play room counts against: profile uuid when signed in, else '
  'the server-issued device key. Null for two-player rooms.';

create index if not exists rooms_solo_key_day_idx
  on public.rooms (solo_key, created_at) where is_solo;

-- ── what the Quick Play screen asks before it offers a game ───────────────
-- WAS ONLY EVER IN THE DATABASE. The column and index above were in this
-- file, and the check below ASSERTS this function exists — but nothing here
-- ever created it. It was written by hand in the SQL editor, so a database
-- rebuilt from the bundle got a solo_key column, an index on it, and no way
-- to answer "have you used your three?" — which QuickPlayClient asks on
-- mount. Captured from the live definition.
create or replace function public.df20_solo_quota(p_key text)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_uid uuid; v_key text; v_used int; v_premium boolean; v_limit int := 3;
begin
  v_uid := (select auth.uid());
  v_premium := v_uid is not null and public.df20_premium_active(v_uid);
  -- an account beats a cookie: it is the identity that cannot be cleared
  v_key := coalesce(v_uid::text, nullif(btrim(coalesce(p_key,'')), ''));

  if v_premium then
    return jsonb_build_object('allowed', true, 'unlimited', true,
                              'used', 0, 'limit', null, 'premium', true);
  end if;
  if v_key is null then
    -- no key at all: let it through rather than block a first-time player
    -- over a cookie that has not been issued yet
    return jsonb_build_object('allowed', true, 'unlimited', false,
                              'used', 0, 'limit', v_limit, 'premium', false);
  end if;

  select count(*) into v_used
    from public.rooms
   where is_solo and solo_key = v_key
     and created_at >= date_trunc('day', now());

  return jsonb_build_object(
    'allowed', v_used < v_limit, 'unlimited', false,
    'used', v_used, 'limit', v_limit, 'premium', false,
    'signed_in', v_uid is not null);
end $$;
revoke all on function public.df20_solo_quota(text) from public;
grant execute on function public.df20_solo_quota(text) to anon, authenticated;


do $$
begin
  if to_regprocedure('public.df20_solo_quota(text)') is null then
    raise exception 'df20_solo_quota missing'; end if;
  if to_regprocedure('public.create_solo_room(text,text,uuid,int,int,text)') is null then
    raise exception 'create_solo_room is not the 6-arg capped form'; end if;
  if to_regprocedure('public.create_solo_room(text,text,uuid,int,int)') is not null then
    raise exception 'the uncapped 5-arg create_solo_room still exists'; end if;
  raise notice 'quick play cap in place';
end $$;
