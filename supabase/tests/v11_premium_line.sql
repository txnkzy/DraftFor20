-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · v11 · where the paywall sits now
--
--   FREE     the premade shelf, signed in or not
--   PREMIUM  any host-supplied pool, and the audience vote
-- ═══════════════════════════════════════════════════════════════════════════

insert into auth.users (id, email, email_confirmed_at) values
  ('e0000000-0000-4000-8000-000000000001', 'v11free@example.com', now()),
  ('e0000000-0000-4000-8000-000000000002', 'v11paid@example.com', now())
on conflict (id) do update set email_confirmed_at = now();

do $t$
declare
  FREE uuid := 'e0000000-0000-4000-8000-000000000001';
  PAID uuid := 'e0000000-0000-4000-8000-000000000002';
  v jsonb; v_lib uuid; v_deck uuid; v_err text; v_code text; v_ht uuid;
  v_rid uuid; v_rooms uuid[] := '{}'; v_guard int;
begin
  update public.profiles set premium_until = null where id = FREE;
  update public.profiles set premium_until = now() + interval '30 days',
                             premium_source = 'admin_grant' where id = PAID;

  insert into public.category_library (name, name_norm)
  values ('V11 Shelf', public.df20_norm_category('V11 Shelf'))
  on conflict (name_norm) do update set name = excluded.name returning id into v_lib;
  insert into public.category_library_items (library_id, name)
  select v_lib, 'V11 Item ' || g from generate_series(1, 30) g on conflict do nothing;

  -- ── FREE keeps the shelf, signed out and signed in ──────────────────────
  perform set_config('request.jwt.claim.sub', '', true);
  v := public.create_room('V11 Shelf', 2, 2000, 100, 15, 'Anon', true, 2,
                          null, null, 'library', v_lib);
  v_rooms := v_rooms || (v->>'room_id')::uuid;
  assert v->>'code' is not null, 'a signed-out visitor can still play the shelf';

  perform set_config('request.jwt.claim.sub', FREE::text, true);
  v := public.create_room('V11 Shelf', 2, 2000, 100, 15, 'Free', true, 2,
                          null, null, 'library', v_lib);
  v_rooms := v_rooms || (v->>'room_id')::uuid;
  assert v->>'code' is not null, 'a free account can still play the shelf';
  raise notice 'PASS  the premade shelf stays free, account or not';

  -- ── FREE is refused every host-supplied pool ────────────────────────────
  v_err := null;
  begin perform public.create_room('X', 2, 2000, 100, 15, 'Free', true, 2,
                                   null, null, 'wikipedia', gen_random_uuid());
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_PREMIUM_REQUIRED%',
    'a typed category must be premium, got: ' || coalesce(v_err, 'allowed');

  v_err := null;
  begin perform public.create_pending_room('standard');
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_PREMIUM_REQUIRED%',
    'a setup link must be premium, got: ' || coalesce(v_err, 'allowed');
  raise notice 'PASS  a free account is refused typed and handed-off categories';

  -- ── PREMIUM gets them ───────────────────────────────────────────────────
  perform set_config('request.jwt.claim.sub', PAID::text, true);
  v := public.create_pending_room('standard');
  assert v->>'setup_token' is not null, 'premium can mint a setup link';
  raise notice 'PASS  a premium account can';

  -- ── the audience vote is FREE, including for a free host ───────────────
  -- 0033 briefly gated this and 0034 put it back: the vote link is how
  -- somebody with no prior contact meets the product, so it must work on a
  -- draft hosted by an account that has never paid anything.
  perform set_config('request.jwt.claim.sub', FREE::text, true);
  update public.profiles set premium_until = null, premium_source = null where id = FREE;

  v := public.create_room('V11 Shelf', 1, 2000, 100, 300, 'Free', true, 0,
                          null, null, 'library', v_lib);
  v_code := v->>'code'; v_ht := (v->>'session_token')::uuid;
  v_rid := (v->>'room_id')::uuid; v_rooms := v_rooms || v_rid;
  perform public.join_room(v_code, 'Bo');
  perform public.start_draft(v_code, v_ht);
  v_guard := 0;
  while (select status from public.rooms where id = v_rid) <> 'complete' and v_guard < 20 loop
    v_guard := v_guard + 1;
    if exists (select 1 from public.lots where room_id = v_rid and status = 'offered') then
      perform public.offer_decide(v_code,
        (select p.session_token from public.lots l join public.players p on p.id = l.opener_player_id
          where l.room_id = v_rid and l.status = 'offered'), 'take');
    elsif exists (select 1 from public.lots where room_id = v_rid and status = 'bidding') then
      perform public.pass_turn(v_code,
        (select p.session_token from public.lots l join public.players p on p.id = l.on_the_clock_player_id
          where l.room_id = v_rid and l.status = 'bidding'),
        (select turn_seq from public.lots where room_id = v_rid and status = 'bidding'));
    end if;
  end loop;

  assert not public.df20_premium_active(FREE), 'fixture: the host really is on the free plan';

  -- a total stranger, no account, no plan, nobody signed in
  perform set_config('request.jwt.claim.sub', '', true);
  v := public.get_audience_state(v_code, 'voter-strangeraaaaaaa');
  assert v->>'status' = 'open',
    'a free host''s draft must still accept votes, got: ' || (v->>'status');
  assert jsonb_array_length(v->'players') = 2, 'and must show both rosters';
  assert v->'tally' = 'null'::jsonb, 'still blind until they vote';

  v := public.cast_audience_vote(v_code, 'voter-strangeraaaaaaa',
    (select id from public.players where room_id = v_rid order by seat limit 1));
  assert (v->'tally'->>'total')::int = 1,
    'a stranger with no account can vote on a free host''s draft';
  raise notice 'PASS  the audience vote is free — free host, anonymous voter, no plan anywhere';

  -- ── cleanup ─────────────────────────────────────────────────────────────
  perform set_config('request.jwt.claim.sub', '', true);
  delete from public.rooms where id = any(v_rooms);
  delete from public.rooms where host_profile_id in (FREE, PAID);
  delete from public.category_library where id = v_lib;
  update public.profiles set premium_until = null, premium_source = null
   where id in (FREE, PAID);

  raise notice '───────────────────────────────────────────────';
  raise notice 'v11 SUITE PASSED';
end $t$;
