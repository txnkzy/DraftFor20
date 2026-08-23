-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · v3 · custom categories, setup links, and the leak test
-- ═══════════════════════════════════════════════════════════════════════════
-- create_pending_room requires an account, so the suite signs in the way
-- Supabase does: a jwt claim that auth.uid() reads.
insert into auth.users (id, email, email_confirmed_at)
values ('11111111-1111-1111-1111-111111111111', 'host@example.com', now())
  on conflict (id) do update set email_confirmed_at = now();
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

-- The setup-link and typed-category paths became premium in 0033. This suite
-- exercises category mechanics, not the paywall — v11_premium_line owns that —
-- so the test host is given a plan rather than rewriting every assertion
-- around a gate it is not trying to test.
insert into public.profiles (id, email)
values ('11111111-1111-1111-1111-111111111111', 'host@example.com')
on conflict (id) do nothing;
update public.profiles
   set premium_until = now() + interval '1 day', premium_source = 'admin_grant'
 where id = '11111111-1111-1111-1111-111111111111';

do $t$
declare
  v jsonb; v_room uuid; v_setup uuid; v_code text; v_res uuid;
  v_ht uuid; v_gt uuid; v_a uuid; v_b uuid; v_err text; v_state jsonb;
  v_items text[]; i int; v_lib uuid; v_guard int; v_actor uuid; v_blob text;
  SENTINEL text := 'Zzyzx Sentinel Marker';
begin
  -- ── 1. normalisation and threshold ──────────────────────────────────────
  assert public.df20_norm_category('List of  NFL Quarterbacks!') = 'nfl quarterbacks',
    'normaliser should strip "list of", punctuation and extra spaces';
  raise notice 'PASS  category normalisation';

  -- fixture must be idempotent so the suite can run twice on one database
  insert into public.category_library (name, name_norm)
  values ('Cereal Brands', public.df20_norm_category('Cereal Brands'))
  on conflict (name_norm) do update set name = excluded.name
  returning id into v_lib;
  insert into public.category_library_items (library_id, name)
  select v_lib, 'Cereal ' || g from generate_series(1, 40) g
  on conflict do nothing;

  assert (public.df20_match_category('cereal brands', 10)->>'source') = 'library',
    'exact normalised name must match';
  assert (public.df20_match_category('Cereal Brand', 10)->>'source') = 'library',
    'singular/plural must still clear 0.5';
  -- a query sharing no meaningful token with anything in the library. Note
  -- 'breakfast' would now legitimately hit the seeded Breakfast Cereals, so
  -- the negative case has to be genuinely unrelated.
  assert public.df20_match_category('knitting patterns', 10) is null,
    'an unrelated phrase must not match, got '
      || coalesce(public.df20_match_category('knitting patterns', 10)::text, 'null');
  assert public.df20_match_category('cereal brands', 999) is null,
    'a match too small for the roster must be refused';
  raise notice 'PASS  fuzzy match at 0.5, and rejects below it';

  -- ── acronym collisions. Trigram similarity alone matched these, because
  --    the shared word "teams" is most of the string. ─────────────────────
  assert public.df20_match_category('nhl teams', 10) is null,
    'nhl must not match nfl, got ' || coalesce((public.df20_match_category('nhl teams',10))->>'name','null');
  assert public.df20_match_category('wnba teams', 10) is null,
    'wnba must not match nba, got ' || coalesce((public.df20_match_category('wnba teams',10))->>'name','null');
  assert public.df20_match_category('ncaa teams', 10) is null,
    'ncaa must not match nfl, got ' || coalesce((public.df20_match_category('ncaa teams',10))->>'name','null');
  assert (public.df20_match_category('nfl teams', 10)->>'name') = 'NFL Teams',
    'the right acronym must still match';
  assert (public.df20_match_category('nba teams', 10)->>'name') = 'NBA Teams',
    'the right acronym must still match';
  raise notice 'PASS  acronyms do not blur into each other';

  -- ── aliases: people type "soda", not "Soft Drinks" ─────────────────────
  assert (public.df20_match_category('soda', 10)->>'name') = 'Soft Drinks', 'soda alias';
  assert (public.df20_match_category('candy', 10)->>'name') = 'Candy and Sweets', 'candy alias';
  assert (public.df20_match_category('cereal', 10)->>'name') = 'Breakfast Cereals', 'cereal alias';
  assert (public.df20_match_category('dogs', 10)->>'name') = 'Dog Breeds', 'dogs alias';
  raise notice 'PASS  short everyday wording resolves through aliases';

  -- ── 2. Option 1: setup link lifecycle ───────────────────────────────────
  v := public.create_pending_room();
  v_setup := (v->>'setup_token')::uuid;
  assert v ? 'setup_token', 'pending room must return a setup link';
  assert not (v ? 'code'), 'a pending room must not have a player code yet';

  v_state := public.get_setup_state(v_setup);
  assert v_state->>'status' = 'open', 'fresh setup link should be open';
  assert not (v_state::text like '%item%'), 'setup state must never carry items';

  v_items := array[SENTINEL];
  for i in 2..12 loop v_items := v_items || ('Snack ' || i); end loop;

  -- duplicates refused
  v_err := null;
  begin perform public.setup_lock_items(v_setup, 'Snack Foods',
    v_items || SENTINEL, 5, 2000, 100, 15, 2);
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_DUPLICATE_ITEM%', 'duplicate items must be refused, got '||coalesce(v_err,'accepted');

  -- too few for the roster refused
  v_err := null;
  begin perform public.setup_lock_items(v_setup, 'Snack Foods',
    array['a','b','c'], 5, 2000, 100, 15, 2);
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_POOL_TOO_SMALL%', 'short list must be refused, got '||coalesce(v_err,'accepted');

  -- the real lock-in
  v := public.setup_lock_items(v_setup, 'Snack Foods', v_items, 5, 2000, 100, 15, 2);
  v_code := v->>'code';
  v_res  := (v->>'setup_result_token')::uuid;
  assert v_code is not null, 'lock-in must mint a player code';
  assert not (v::text like '%'||SENTINEL||'%'), 'LEAK: lock-in response echoed an item';

  -- the setup link is gone, not read-only
  assert (public.get_setup_state(v_setup)->>'status') = 'gone',
    'a spent setup link must stop resolving';
  v_err := null;
  begin perform public.setup_lock_items(v_setup, 'Again', v_items, 5, 2000, 100, 15, 2);
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_SETUP_LINK_SPENT%', 'a spent link must not lock again, got '||coalesce(v_err,'accepted');
  raise notice 'PASS  setup link: validates, mints a code, then dies';

  -- ── 3. THE LEAK TEST ────────────────────────────────────────────────────
  v := public.join_room(v_code, 'Ari'); v_ht := (v->>'session_token')::uuid; v_a := (v->>'player_id')::uuid;
  assert not (v::text like '%'||SENTINEL||'%'), 'LEAK: join response carried an item';
  v := public.join_room(v_code, 'Bo');  v_gt := (v->>'session_token')::uuid; v_b := (v->>'player_id')::uuid;

  select id into v_room from public.rooms where code = v_code;
  perform public.start_draft(v_code, v_ht);

  v_blob := public.get_room_state(v_code)::text;
  if v_blob like '%'||SENTINEL||'%' then
    -- only legitimate if that card is the one currently on the block
    assert (public.get_room_state(v_code)->'lot'->>'item_name') = SENTINEL,
      'LEAK: an undealt item appeared in the public snapshot';
  end if;
  assert (select count(*) from public.room_deck
           where room_id = v_room and revealed_at is null) > 0,
    'there should be undealt cards to leak';
  raise notice 'PASS  no undealt item reaches the public snapshot';

  -- ── 4. the draft still plays on a custom pool ───────────────────────────
  v_guard := 0;
  loop
    v_state := public.get_room_state(v_code);
    exit when v_state->'room'->>'phase' = 'complete';
    v_guard := v_guard + 1; if v_guard > 200 then raise exception 'DID_NOT_TERMINATE'; end if;
    if v_state->'room'->>'phase' = 'offering' then
      v_actor := (v_state->'lot'->>'opener_player_id')::uuid;
      perform public.offer_decide(v_code, case when v_actor=v_a then v_ht else v_gt end, 'take');
    else
      v_actor := (v_state->'lot'->>'on_the_clock_player_id')::uuid;
      perform public.pass_turn(v_code, case when v_actor=v_a then v_ht else v_gt end,
                               (v_state->'lot'->>'turn_seq')::int);
    end if;
  end loop;
  assert (select count(*) from public.roster_entries where room_id = v_room) = 10,
    'both rosters should be full';
  assert (select count(distinct item_name) from public.roster_entries where room_id = v_room) = 10,
    'no item may be drafted twice';
  raise notice 'PASS  a manual category plays through to completion';

  -- ── 5. opt-in gate ──────────────────────────────────────────────────────
  assert (public.offer_library_optin(v_res)->>'status') = 'eligible',
    'a clean snack list should be offerable';
  assert (public.submit_library_optin(v_res, false)->>'status') = 'declined',
    'declining must stick';
  assert (public.offer_library_optin(v_res)->>'status') = 'declined',
    'a declined session must never be re-offered';
  raise notice 'PASS  opt-in is offered, and declining is remembered';

  -- a person-oriented list must never even be offered
  v := public.create_pending_room(); v_setup := (v->>'setup_token')::uuid;
  v_items := array[]::text[];
  for i in 1..12 loop v_items := v_items || ('Firstname Last' || i); end loop;
  v := public.setup_lock_items(v_setup, 'My Friend Group', v_items, 5, 2000, 100, 15, 2);
  v_res := (v->>'setup_result_token')::uuid;
  update public.rooms set status = 'complete' where code = v->>'code';
  assert (public.offer_library_optin(v_res)->>'status') = 'ineligible',
    'a friend group must never be offered to the public library';
  assert (public.submit_library_optin(v_res, true)->>'status') = 'ineligible',
    'and forcing accept must still refuse';
  raise notice 'PASS  real-name lists are permanently ineligible';

  raise notice '──────────  ALL v3 CATEGORY TESTS PASSED  ──────────';
end $t$;

-- and prove the gate actually bites when signed out
set request.jwt.claim.sub = '';
do $g$
declare v_err text;
begin
  v_err := null;
  begin perform public.create_pending_room(); exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_SIGNIN_REQUIRED%',
    'a signed-out caller must not get a setup link, got ' || coalesce(v_err, 'a link');

  v_err := null;
  begin perform public.create_room('x',3,2000,100,15,'A',true,2,null,null,'wikipedia',null);
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_SIGNIN_REQUIRED%',
    'a signed-out caller must not use the wikipedia pool, got ' || coalesce(v_err, 'a room');

  -- but the free shelf stays open
  perform public.create_room('x',3,2000,100,15,'A',true,2,null,null,'library',
    (select id from public.category_library where name = 'Disney Animated Movies'));
  raise notice 'PASS  gate: custom paths refused signed out, free shelf still open';
end $g$;

-- an account that exists but has NOT confirmed its email
insert into auth.users (id, email, email_confirmed_at)
values ('22222222-2222-2222-2222-222222222222', 'unconfirmed@example.com', null)
  on conflict (id) do update set email_confirmed_at = null;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
do $u$
declare v_err text;
begin
  v_err := null;
  begin perform public.create_pending_room(); exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_EMAIL_UNVERIFIED%',
    'an unconfirmed account must not get a setup link, got ' || coalesce(v_err, 'a link');

  v_err := null;
  begin perform public.create_room('x',3,2000,100,15,'A',true,2,null,null,'wikipedia',null);
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_EMAIL_UNVERIFIED%',
    'an unconfirmed account must not use the wikipedia pool, got ' || coalesce(v_err, 'a room');

  -- but must still be able to play the free shelf
  perform public.create_room('x',3,2000,100,15,'A',true,2,null,null,'library',
    (select id from public.category_library where name = 'TV Sitcoms'));
  raise notice 'PASS  unconfirmed account: premium refused, free shelf still open';
end $u$;

-- and a confirmed one gets through
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
do $v$
begin
  perform public.create_pending_room();
  raise notice 'PASS  confirmed premium account can mint a setup link';
end $v$;
set request.jwt.claim.sub = '';

-- the suite borrowed a plan; give it back
update public.profiles
   set premium_until = null, premium_source = null
 where id = '11111111-1111-1111-1111-111111111111';
