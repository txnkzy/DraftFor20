-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0048 · every `revoke ... from anon, authenticated` in this
--                     repo has been a no-op, and here is why
--
-- Postgres grants EXECUTE on a new function to PUBLIC by default. anon and
-- authenticated are members of PUBLIC, so
--
--     revoke all on function public.df20_reveal_next(uuid) from anon, authenticated;
--
-- removes a grant those roles never had and leaves the PUBLIC one untouched.
-- Every internal function this codebase believed it had sealed since 0004 has
-- in fact been callable by anyone holding the publishable key. Verified, not
-- theorised:
--
--     curl -X POST "$URL/rest/v1/rpc/df20_gen_code" \
--          -H "apikey: $ANON_KEY" -d '{}'
--     "FKMWDK"
--
-- 100 of 103 app functions were reachable. The exposed set includes the two
-- rules the product rests on:
--
--   df20_reveal_next(uuid)     deals the next card — a caller could turn over
--                              the deck of a room they are merely watching
--   df20_add_to_roster(...)    writes a roster entry with no money check at
--                              all, which is the whole auction bypassed
--   df20_fill_pool(...)        replaces a live room's item pool
--   df20_resolve_lot/_gift     ends a lot in a chosen direction
--   df20_purge_old_rooms()     deletes rooms
--   df20_seed_category(...)    writes to the shared public library
--
-- THE FIX IS TO REVOKE FROM PUBLIC, NOT FROM THE ROLES. The 69 functions that
-- are genuinely the client API were each given an explicit
-- `grant execute ... to anon, authenticated`, and an explicit grant survives a
-- revoke from PUBLIC — so the client API is unaffected and only the functions
-- that were riding the default grant lose access.
--
-- Extension functions (pg_trgm) are deliberately excluded: they are not ours
-- to re-permission, and trigram matching runs inside SECURITY DEFINER
-- functions that would keep working regardless.
--
-- Re-runnable.
-- ═══════════════════════════════════════════════════════════════════════════

do $$
declare r record; v_n int := 0;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      left join pg_depend d on d.objid = p.oid and d.deptype = 'e'   -- extension-owned
     where n.nspname = 'public'
       and d.objid is null
  loop
    execute format('revoke all on function %s from public', r.sig);
    v_n := v_n + 1;
  end loop;
  raise notice 'revoked PUBLIC execute on % app functions', v_n;
end $$;

-- ── and assert the hole is actually closed ────────────────────────────────
-- Two directions, because either failure is silent: an internal function that
-- is still reachable, or a client RPC that lost its grant and will now 404
-- the moment somebody tries to create a room.
do $$
declare
  v_exposed text[] := '{}';
  v_broken  text[] := '{}';
  r record;
  -- the client API. If any of these stops being executable the app is down,
  -- so they are named rather than inferred.
  v_client text[] := array[
    'public.create_room(text,integer,integer,integer,integer,text,boolean,integer,text,text,text,uuid,text)',
    'public.join_room(text,text)',
    'public.start_draft(text,uuid)',
    'public.place_bid(text,uuid,integer,integer)',
    'public.pass_turn(text,uuid,integer)',
    'public.offer_decide(text,uuid,text)',
    'public.expire_turn(text)',
    'public.get_room_state(text)',
    'public.submit_vote(text,uuid,uuid)',
    'public.list_free_categories()',
    'public.df20_match_category(text,integer)',
    'public.df20_rate_limit(text,text,integer,integer)',
    'public.my_premium()',
    'public.get_audience_state(text,text)',
    'public.cast_audience_vote(text,text,uuid)',
    'public.get_obs_state(uuid)'
  ];
  f text;
begin
  -- 1. nothing internal may remain reachable by anon
  for r in
    select p.oid, p.oid::regprocedure::text as sig, p.proacl
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      left join pg_depend d on d.objid = p.oid and d.deptype = 'e'
     where n.nspname = 'public'
       and d.objid is null
       and not (coalesce(p.proacl::text, '') like '%anon=X%'
             or coalesce(p.proacl::text, '') like '%authenticated=X%')
  loop
    if has_function_privilege('anon', r.oid, 'EXECUTE') then
      v_exposed := v_exposed || r.sig;
    end if;
  end loop;

  -- 2. everything the client actually calls must still work
  foreach f in array v_client loop
    if to_regprocedure(f) is null then
      v_broken := v_broken || (f || ' (missing)');
    elsif not has_function_privilege('anon', to_regprocedure(f)::oid, 'EXECUTE') then
      v_broken := v_broken || (f || ' (anon lost EXECUTE)');
    end if;
  end loop;

  if coalesce(array_length(v_exposed, 1), 0) > 0 then
    raise exception E'DF20_INTERNAL_STILL_EXPOSED\n  %', array_to_string(v_exposed, E'\n  ');
  end if;
  if coalesce(array_length(v_broken, 1), 0) > 0 then
    raise exception E'DF20_CLIENT_API_BROKEN\n  %', array_to_string(v_broken, E'\n  ');
  end if;

  raise notice 'ok: internal functions sealed, % client RPCs still reachable',
    array_length(v_client, 1);
end $$;
