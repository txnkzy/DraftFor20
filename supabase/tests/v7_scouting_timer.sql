-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · v7 · the no-limit clock and the Scouting Report
--
-- The scouting assertions deliberately do NOT hardcode expected numbers.
-- Each metric is recomputed from the raw tables by a second, independent
-- query and compared against what the RPC returned — so the test fails if
-- the aggregation drifts, rather than if the fixture changes.
-- ═══════════════════════════════════════════════════════════════════════════

insert into auth.users (id, email, email_confirmed_at) values
  ('c0000000-0000-4000-8000-000000000001', 'v7a@example.com', now()),
  ('c0000000-0000-4000-8000-000000000002', 'v7b@example.com', now())
on conflict (id) do update set email_confirmed_at = now();

set request.jwt.claim.sub = 'c0000000-0000-4000-8000-000000000001';

do $t$
declare
  A uuid := 'c0000000-0000-4000-8000-000000000001';
  B uuid := 'c0000000-0000-4000-8000-000000000002';
  v jsonb; v_code text; v_rid uuid; v_ht uuid; v_gt uuid; v_a uuid; v_b uuid;
  v_lib uuid; v_err text; v_seq int; v_n int; v_guard int;
  v_exp timestamptz; v_rooms uuid[] := '{}'; v_n2 uuid;
  v_bought int; v_snipes int; v_spend int; v_raises int; v_left int;
  v_axes jsonb; v_report jsonb;
begin
  -- ── fixture category ────────────────────────────────────────────────────
  insert into public.category_library (name, name_norm)
  values ('V7 Test Shelf', public.df20_norm_category('V7 Test Shelf'))
  on conflict (name_norm) do update set name = excluded.name
  returning id into v_lib;
  insert into public.category_library_items (library_id, name)
  select v_lib, 'V7 Item ' || g from generate_series(1, 40) g on conflict do nothing;

  -- ═══════════════════════════════════════════════════════════════════════
  -- 1. THE CLOCK
  -- ═══════════════════════════════════════════════════════════════════════
  assert public.df20_turn_deadline(0) is null, 'zero seconds is no deadline';
  assert public.df20_turn_deadline(null) is null, 'null seconds is no deadline';
  assert public.df20_turn_deadline(15) > now(), '15 seconds is a real deadline';
  raise notice 'PASS  df20_turn_deadline: 0 and null mean no clock';

  -- a custom value in between the presets is accepted
  v := public.create_room('V7 Test Shelf', 1, 2000, 100, 7, 'Ari', true, 0,
                          null, null, 'library', v_lib);
  v_rooms := v_rooms || (v->>'room_id')::uuid;
  assert (select timer_seconds from public.rooms where id = (v->>'room_id')::uuid) = 7,
    'a custom 7 second clock is allowed';

  -- nonsense is still nonsense
  v_err := null;
  begin perform public.create_room('V7 Test Shelf', 1, 2000, 100, 2, 'Ari', true, 0,
                                   null, null, 'library', v_lib);
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_BAD_TIMER%', '2 seconds is refused, got: ' || coalesce(v_err,'accepted');

  v_err := null;
  begin perform public.create_room('V7 Test Shelf', 1, 2000, 100, 301, 'Ari', true, 0,
                                   null, null, 'library', v_lib);
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_BAD_TIMER%', '301 seconds is refused, got: ' || coalesce(v_err,'accepted');
  raise notice 'PASS  custom clock accepted, 2s and 301s still refused';

  -- ── a whole draft with NO CLOCK AT ALL ─────────────────────────────────
  v := public.create_room('V7 Test Shelf', 2, 2000, 100, 0, 'Ari', true, 0,
                          null, null, 'library', v_lib);
  v_code := v->>'code'; v_ht := (v->>'session_token')::uuid;
  v_a := (v->>'player_id')::uuid; v_rid := (v->>'room_id')::uuid;
  v_rooms := v_rooms || v_rid;

  set request.jwt.claim.sub = 'c0000000-0000-4000-8000-000000000002';
  v := public.join_room(v_code, 'Bo');
  v_gt := (v->>'session_token')::uuid; v_b := (v->>'player_id')::uuid;
  set request.jwt.claim.sub = 'c0000000-0000-4000-8000-000000000001';

  perform public.start_draft(v_code, v_ht);
  select turn_expires_at into v_exp from public.lots
   where room_id = v_rid and status = 'offered';
  assert v_exp is null, 'a no-limit room deals a card with no deadline';

  -- the idempotent expiry call has to be a harmless no-op, because both
  -- clients would otherwise be firing it into a room that never expires
  perform public.expire_turn(v_code);
  assert (select status from public.lots where room_id = v_rid and status = 'offered') = 'offered',
    'expire_turn must not resolve a lot that has no deadline';

  -- and the pg_cron sweeper must not see it either
  assert not exists (
    select 1 from public.rooms ro
      join public.lots l on l.room_id = ro.id and l.status in ('offered','bidding')
     where ro.id = v_rid and l.turn_expires_at < now() - interval '2 seconds'),
    'the sweeper must skip a room with no deadline';
  raise notice 'PASS  no-limit room: no deadline, expire_turn no-ops, sweeper skips it';

  -- play it out. A bid placed with no clock must never be "late".
  perform public.offer_decide(v_code, v_ht, 'take');
  select turn_expires_at, turn_seq into v_exp, v_seq from public.lots
   where room_id = v_rid and status = 'bidding';
  assert v_exp is null, 'taking in a no-limit room hands over the clock with no deadline';

  v := public.place_bid(v_code, v_gt, 300, v_seq);
  assert (v->'lot'->>'current_bid_cents')::int = 300, 'a bid lands with no clock running';
  assert v->'lot'->>'turn_expires_at' is null, 'and still sets no deadline';

  v_seq := (v->'lot'->>'turn_seq')::int;
  perform public.pass_turn(v_code, v_ht, v_seq);

  v_guard := 0;
  while (select status from public.rooms where id = v_rid) <> 'complete' and v_guard < 30 loop
    v_guard := v_guard + 1;
    if exists (select 1 from public.lots where room_id = v_rid and status = 'offered') then
      perform public.offer_decide(v_code,
        (select p.session_token from public.lots l
           join public.players p on p.id = l.opener_player_id
          where l.room_id = v_rid and l.status = 'offered'), 'take');
    elsif exists (select 1 from public.lots where room_id = v_rid and status = 'bidding') then
      perform public.pass_turn(v_code,
        (select p.session_token from public.lots l
           join public.players p on p.id = l.on_the_clock_player_id
          where l.room_id = v_rid and l.status = 'bidding'),
        (select turn_seq from public.lots where room_id = v_rid and status = 'bidding'));
    end if;
  end loop;
  assert (select status from public.rooms where id = v_rid) = 'complete',
    'a no-limit draft still terminates';
  assert (select count(*) from public.roster_entries where room_id = v_rid) = 4,
    'both rosters filled';
  assert (select sum(bankroll_cents) + sum(price_cents) from public.players p,
            lateral (select coalesce(sum(price_cents),0) as price_cents
                       from public.roster_entries r where r.player_id = p.id) x
           where p.room_id = v_rid) = 4000,
    'the books still balance with no clock';
  raise notice 'PASS  a full draft runs and terminates with no clock at all';

  -- ═══════════════════════════════════════════════════════════════════════
  -- 2. THE SCOUTING REPORT
  -- ═══════════════════════════════════════════════════════════════════════
  v_report := public.my_scouting_report();
  assert (v_report->>'signed_in')::boolean, 'signed in';
  assert (v_report->>'drafts')::int >= 1, 'at least the draft just played';
  v_axes := v_report->'axes';
  assert jsonb_array_length(v_axes) = 4, 'four axes';

  -- recompute every raw figure independently and compare
  select coalesce(sum(case when not e.gifted then 1 else 0 end), 0),
         coalesce(sum(case when not e.gifted and e.price_cents = r.min_bid_cents
                           then 1 else 0 end), 0),
         coalesce(sum(e.price_cents), 0)
    into v_bought, v_snipes, v_spend
    from public.roster_entries e
    join public.players p on p.id = e.player_id
    join public.rooms r on r.id = e.room_id
   where p.profile_id = A and r.status = 'complete';

  select count(*) into v_raises
    from public.bid_events b
    join public.lots l on l.id = b.lot_id
    join public.players p on p.id = b.player_id
    join public.rooms r on r.id = b.room_id
   where p.profile_id = A and b.action = 'raise' and r.status = 'complete'
     and l.winner_player_id is distinct from b.player_id;

  select coalesce(round(avg(p.bankroll_cents)), 0) into v_left
    from public.players p join public.rooms r on r.id = p.room_id
   where p.profile_id = A and r.status = 'complete';

  assert (v_axes->0->>'raw')::int = round(100.0 * v_snipes / greatest(v_bought,1))::int,
    format('sniper %% mismatch: rpc %s vs recomputed %s',
           v_axes->0->>'raw', round(100.0 * v_snipes / greatest(v_bought,1))::int);
  assert (v_axes->1->>'raw')::int = round(v_spend::numeric / greatest(v_bought,1))::int,
    format('whale mismatch: rpc %s vs recomputed %s',
           v_axes->1->>'raw', round(v_spend::numeric / greatest(v_bought,1))::int);
  assert (v_axes->2->>'raw')::int = v_raises,
    format('instigator mismatch: rpc %s vs recomputed %s', v_axes->2->>'raw', v_raises);
  assert (v_axes->3->>'raw')::int = v_left,
    format('hoarder mismatch: rpc %s vs recomputed %s', v_axes->3->>'raw', v_left);
  raise notice 'PASS  all four metrics match an independent recomputation';

  -- every axis is a 0-100 score, or the chart cannot draw them together
  for v_n in 0..3 loop
    assert (v_axes->v_n->>'score')::int between 0 and 100,
      format('axis %s scored outside 0-100', v_axes->v_n->>'key');
  end loop;
  assert v_report->>'title' in ('unread','allrounder','sniper','whale','instigator','hoarder'),
    'the title is one of the known set, got ' || (v_report->>'title');
  raise notice 'PASS  axes are all 0-100 and the title is well formed';

  -- ── the free window: 5 drafts, and the sixth is premium-only ───────────
  for v_n in 1..6 loop
    v := public.create_room('V7 Test Shelf', 1, 2000, 100, 0, 'Ari', true, 0,
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
          (select p.session_token from public.lots l
             join public.players p on p.id = l.opener_player_id
            where l.room_id = v_rid and l.status = 'offered'), 'take');
      elsif exists (select 1 from public.lots where room_id = v_rid and status = 'bidding') then
        perform public.pass_turn(v_code,
          (select p.session_token from public.lots l
             join public.players p on p.id = l.on_the_clock_player_id
            where l.room_id = v_rid and l.status = 'bidding'),
          (select turn_seq from public.lots where room_id = v_rid and status = 'bidding'));
      end if;
    end loop;
  end loop;

  update public.profiles set premium_until = null where id = A;
  v_report := public.my_scouting_report();
  assert (v_report->>'drafts')::int = 5,
    format('a free account sees five drafts, got %s', v_report->>'drafts');
  assert (v_report->'window'->>'premium')::boolean = false, 'window says free';
  assert (v_report->'window'->>'total')::int > 5, 'and still knows how many there really are';

  update public.profiles
     set premium_until = now() + interval '30 days', premium_source = 'admin_grant'
   where id = A;
  v_report := public.my_scouting_report();
  assert (v_report->>'drafts')::int = (v_report->'window'->>'total')::int,
    'premium sees every draft';
  assert (v_report->'window'->>'cap') is null, 'premium has no cap';
  raise notice 'PASS  free sees the last 5, premium sees the lot — enforced server-side';

  -- ═══════════════════════════════════════════════════════════════════════
  -- 3. CONTENT CREATOR IS A PROPERTY OF THE ROOM, AND IT IS PREMIUM
  -- ═══════════════════════════════════════════════════════════════════════
  update public.profiles set premium_until = null, premium_source = null where id = A;

  v_err := null;
  begin perform public.create_room('V7 Test Shelf', 1, 2000, 100, 15, 'Ari', true, 0,
                                   null, null, 'library', v_lib, 'creator');
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_PREMIUM_REQUIRED%',
    'a free account cannot open a creator room, got: ' || coalesce(v_err, 'accepted');

  v_err := null;
  begin perform public.create_pending_room('creator');
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_PREMIUM_REQUIRED%',
    'nor mint a creator handoff link, got: ' || coalesce(v_err, 'accepted');

  -- the standard room is untouched by any of this
  v := public.create_room('V7 Test Shelf', 1, 2000, 100, 15, 'Ari', true, 0,
                          null, null, 'library', v_lib);
  v_rooms := v_rooms || (v->>'room_id')::uuid;
  assert v->>'content_mode' = 'standard', 'rooms are standard unless asked otherwise';

  update public.profiles
     set premium_until = now() + interval '30 days', premium_source = 'admin_grant'
   where id = A;

  v := public.create_room('V7 Test Shelf', 1, 2000, 100, 15, 'Ari', true, 0,
                          null, null, 'library', v_lib, 'creator');
  v_rid := (v->>'room_id')::uuid; v_rooms := v_rooms || v_rid;
  assert v->>'content_mode' = 'creator', 'premium opens a creator room';
  assert (select content_mode from public.rooms where id = v_rid) = 'creator',
    'and it is stored on the room, not held in a browser';

  v_err := null;
  begin perform public.create_room('V7 Test Shelf', 1, 2000, 100, 15, 'Ari', true, 0,
                                   null, null, 'library', v_lib, 'cinema');
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_BAD_CONTENT_MODE%', 'and there are only two of them';
  raise notice 'PASS  content mode is set at creation, premium-gated in the database';

  -- ═══════════════════════════════════════════════════════════════════════
  -- 4. THE CONSOLE
  -- ═══════════════════════════════════════════════════════════════════════
  delete from public.df20_config where key = 'admin_user_ids';
  assert public.df20_is_admin() = false, 'no admin row means no admins';
  v_err := null;
  begin perform public.admin_activity();
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_NOT_AUTHORISED%', 'and every console RPC refuses';

  insert into public.df20_config (key, value) values ('admin_user_ids', A::text)
  on conflict (key) do update set value = excluded.value;
  assert public.df20_is_admin(), 'the configured uuid is an admin';

  v := public.admin_activity();
  assert (v->'rooms'->>'total')::int > 0, 'activity counts rooms';
  assert (v->'modes'->>'creator')::int >= 1, 'and knows which are creator rooms';
  assert (v->'duration'->>'sample') is not null, 'duration always reports its sample size';

  -- the moderation queue: opting in is a submission now, not a publication
  update public.rooms
     set library_optin_state = 'pending', category_name = 'V7 Queued Category'
   where id = v_rid;
  v := public.admin_library_queue();
  assert jsonb_array_length(v) >= 1, 'the submission is queued';
  assert not exists (select 1 from public.category_library
                      where name_norm = public.df20_norm_category('V7 Queued Category')),
    'and NOTHING is public until a human says so';

  v := public.admin_review_library(v_rid, true);
  assert v->>'status' = 'accepted', 'approving publishes it, got ' || (v->>'status');
  assert exists (select 1 from public.category_library
                  where name_norm = public.df20_norm_category('V7 Queued Category')),
    'the category is on the shelf';
  assert (select library_optin_state from public.rooms where id = v_rid) = 'accepted';

  select id into v_n2 from public.category_library
   where name_norm = public.df20_norm_category('V7 Queued Category');
  v := public.admin_library_remove(v_n2);
  assert (v->>'removed')::boolean, 'and it can be taken back off';
  raise notice 'PASS  console gated, queue holds submissions until a human approves';

  -- ── cleanup ────────────────────────────────────────────────────────────
  update public.profiles set premium_until = null, premium_source = null where id = A;
  delete from public.df20_config where key = 'admin_user_ids';
  delete from public.rooms where id = any(v_rooms);
  delete from public.category_library where id = v_lib;
  delete from public.category_library
   where name_norm = public.df20_norm_category('V7 Queued Category');

  raise notice '───────────────────────────────────────────────';
  raise notice 'v7 SUITE PASSED';
end $t$;

reset request.jwt.claim.sub;
