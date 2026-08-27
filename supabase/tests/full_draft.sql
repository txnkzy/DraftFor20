-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 v2 · server-authority test
-- Run in the SQL editor after applying APPLY_V7.sql. Cleans up after itself.
-- ═══════════════════════════════════════════════════════════════════════════

do $test$
declare
  v_h jsonb; v_g jsonb; v_s jsonb; v_code text; v_ht uuid; v_gt uuid;
  v_a uuid; v_b uuid; v_rid uuid; v_err text; v_actor uuid; v_guard int;
  v_bank int; v_spent int; v_seq int; v_tok uuid; v_rooms uuid[] := '{}';
begin
  -- ── 1. the money function is unchanged ──────────────────────────────────
  assert public.df20_max_legal_bid(1000, 100, 3) = 800,  'spec example';
  assert public.df20_max_legal_bid(2000, 100, 5) = 1600, '$20 / 5 slots';
  assert public.df20_max_legal_bid(2000, 100, 1) = 2000, 'last slot';
  assert public.df20_max_legal_bid(300,  100, 5) = 100,  'underfunded degrades';
  assert public.df20_max_legal_bid(0,    100, 2) = 0,    'broke';
  assert public.df20_max_legal_bid(500,  0,   5) = 500,  'min bid 0';
  raise notice 'PASS  money function unchanged';

  -- ── 2. start: deck is dealt, seat 1 opens ───────────────────────────────
  -- allow_broke defaults to TRUE now, and this suite exists to prove the
  -- Reserve Rule, so it opts in explicitly. v12 covers the new default.
  v_h := public.create_room('TEST Football Draft', 5, 2000, 100, 120, 'Ari', true, 2,
                            null, null, 'library', null, 'standard', false);
  v_code := v_h->>'code'; v_ht := (v_h->>'session_token')::uuid;
  v_a := (v_h->>'player_id')::uuid; v_rid := (v_h->>'room_id')::uuid;
  v_rooms := v_rooms || v_rid;
  v_g := public.join_room(v_code, 'Bo');
  v_gt := (v_g->>'session_token')::uuid; v_b := (v_g->>'player_id')::uuid;

  v_s := public.start_draft(v_code, v_ht);
  assert v_s->'room'->>'phase' = 'offering', 'draft opens in the offer phase';
  assert v_s->'lot'->>'status' = 'offered', 'a card is on the block';
  assert (v_s->'lot'->>'opener_player_id')::uuid = v_a, 'seat 1 opens the first card';
  assert (v_s->'lot'->>'current_bid_cents')::int = 100, 'auto-opened at the minimum';
  assert length(v_s->'lot'->>'item_name') > 0, 'the card has a name';
  assert (select count(*) from public.room_deck where room_id = v_rid) = 30,
         'deck is roster_size x 6';
  assert (v_s->>'deck_remaining')::int = 29, 'one card dealt';
  raise notice 'PASS  deck shuffled server-side, first card dealt to seat 1';

  -- ── 3. THE DECK IS HIDDEN ───────────────────────────────────────────────
  assert not exists (
    select 1 from public.room_deck d
     where d.room_id = v_rid and d.revealed_at is null
       and public.df20_public_state(v_rid)::text like '%"' || d.item_name || '"%'),
    'an undealt name leaked into the public state';
  assert public.df20_public_state(v_rid)::text not like '%room_deck%',
    'the public state must not carry the deck';
  raise notice 'PASS  no undealt name appears in the public snapshot';

  -- ── 4. the offer: take, then a real bid war ─────────────────────────────
  v_err := null;
  begin perform public.offer_decide(v_code, v_gt, 'take');
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_NOT_YOUR_TURN%', 'only the opener may decide, got: ' || coalesce(v_err,'ok');

  v_s := public.offer_decide(v_code, v_ht, 'take');
  assert v_s->'room'->>'phase' = 'bidding', 'take hands the clock to the opponent';
  assert (v_s->'lot'->>'on_the_clock_player_id')::uuid = v_b;
  v_seq := (v_s->'lot'->>'turn_seq')::int;

  -- RESERVE RULE on the live server
  v_err := null;
  begin perform public.place_bid(v_code, v_gt, 1700, v_seq);
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_OVER_RESERVE%', '$17 with 5 slots open must be refused, got: ' || coalesce(v_err,'accepted');

  v_s := public.place_bid(v_code, v_gt, 600, v_seq);
  v_seq := (v_s->'lot'->>'turn_seq')::int;

  -- STALE
  v_err := null;
  begin perform public.place_bid(v_code, v_ht, 700, v_seq - 1);
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_STALE%', 'stale sequence refused, got: ' || coalesce(v_err,'accepted');

  v_s := public.place_bid(v_code, v_ht, 700, v_seq);
  v_seq := (v_s->'lot'->>'turn_seq')::int;
  v_s := public.pass_turn(v_code, v_gt, v_seq);

  select bankroll_cents into v_bank from public.players where id = v_a;
  assert v_bank = 1300, 'Ari wins at $7, $13 left, got ' || v_bank;
  assert (select count(*) from public.roster_entries where player_id = v_a) = 1;
  assert v_s->'room'->>'phase' = 'offering', 'next card is dealt immediately';
  assert (v_s->'lot'->>'opener_player_id')::uuid = v_b, 'the opener alternates';
  raise notice 'PASS  offer -> take -> bid war -> resolve -> next card';

  -- ── 5. the give ─────────────────────────────────────────────────────────
  v_s := public.offer_decide(v_code, v_gt, 'give');
  assert (select count(*) from public.roster_entries where player_id = v_a) = 2,
         'a gift lands on the opponent roster';
  assert (select price_cents from public.roster_entries
           where player_id = v_a order by pick_number desc limit 1) = 0,
         'a gift costs the receiver nothing';
  assert (select gifted from public.roster_entries
           where player_id = v_a order by pick_number desc limit 1),
         'the gift is marked';
  assert (select gives_used from public.players where id = v_b) = 1,
         'the give is deducted from the giver budget';
  select bankroll_cents into v_bank from public.players where id = v_b;
  assert v_bank = 2000, 'giving costs the giver nothing either, got ' || v_bank;
  raise notice 'PASS  give hands the card over free and spends a give';

  -- ── 6. the give budget actually binds ───────────────────────────────────
  v_guard := 0;
  loop
    v_s := public.get_room_state(v_code);
    exit when v_s->'room'->>'phase' = 'complete';
    v_guard := v_guard + 1; if v_guard > 60 then raise exception 'STUCK'; end if;
    if v_s->'room'->>'phase' = 'offering' then
      v_actor := (v_s->'lot'->>'opener_player_id')::uuid;
      v_tok := case when v_actor = v_a then v_ht else v_gt end;
      -- always try to give; once the budget is gone the server must refuse
      v_err := null;
      begin perform public.offer_decide(v_code, v_tok, 'give');
      exception when others then v_err := sqlerrm; end;
      if v_err is not null then
        assert v_err like '%DF20_NO_GIVES_LEFT%' or v_err like '%DF20_THEY_ARE_FULL%',
               'unexpected give refusal: ' || v_err;
        perform public.offer_decide(v_code, v_tok, 'take');
      end if;
    else
      v_actor := (v_s->'lot'->>'on_the_clock_player_id')::uuid;
      perform public.pass_turn(v_code, case when v_actor = v_a then v_ht else v_gt end,
                               (v_s->'lot'->>'turn_seq')::int);
    end if;
  end loop;

  assert (select max(gives_used) from public.players where room_id = v_rid) <= 2,
         'nobody exceeded the give budget';
  assert exists (select 1 from public.bid_events
                  where room_id = v_rid and action = 'offer_give'),
         'gives were exercised';

  -- ── 7. terminal invariants ──────────────────────────────────────────────
  for v_actor in select id from public.players where room_id = v_rid loop
    assert public.df20_open_slots(v_rid, v_actor) = 0, 'every roster is full';
    select bankroll_cents into v_bank from public.players where id = v_actor;
    select coalesce(sum(price_cents),0) into v_spent
      from public.roster_entries where player_id = v_actor;
    assert v_bank >= 0, 'bankroll never negative';
    assert v_spent + v_bank = 2000,
           'spend + leftover must equal the bankroll, got ' || v_spent || ' + ' || v_bank;
    assert (select count(*) from public.roster_entries where player_id = v_actor) = 5,
           'exactly roster_size players';
  end loop;
  assert (select count(distinct item_name) from public.roster_entries where room_id = v_rid) = 10,
         'no player was drafted twice';
  raise notice 'PASS  draft terminates: two full rosters, books balance, no duplicates';

  -- ── 8. underfunded room still cannot go negative ────────────────────────
  v_h := public.create_room('TEST Broke', 5, 300, 100, 120, 'Ari', true, 0);
  v_code := v_h->>'code'; v_ht := (v_h->>'session_token')::uuid;
  v_a := (v_h->>'player_id')::uuid; v_rid := (v_h->>'room_id')::uuid;
  v_rooms := v_rooms || v_rid;
  v_g := public.join_room(v_code, 'Bo');
  v_gt := (v_g->>'session_token')::uuid; v_b := (v_g->>'player_id')::uuid;
  perform public.start_draft(v_code, v_ht);

  v_guard := 0;
  loop
    v_s := public.get_room_state(v_code);
    exit when v_s->'room'->>'phase' = 'complete';
    v_guard := v_guard + 1; if v_guard > 120 then raise exception 'BROKE_STUCK'; end if;
    if v_s->'room'->>'phase' = 'offering' then
      v_actor := (v_s->'lot'->>'opener_player_id')::uuid;
      v_tok := case when v_actor = v_a then v_ht else v_gt end;
      v_err := null;
      begin perform public.offer_decide(v_code, v_tok, 'take');
      exception when others then v_err := sqlerrm; end;
      if v_err is not null then
        perform public.offer_decide(v_code, v_tok, 'discard');
      end if;
    else
      v_actor := (v_s->'lot'->>'on_the_clock_player_id')::uuid;
      perform public.pass_turn(v_code, case when v_actor = v_a then v_ht else v_gt end,
                               (v_s->'lot'->>'turn_seq')::int);
    end if;
  end loop;

  for v_actor in select id from public.players where room_id = v_rid loop
    select bankroll_cents into v_bank from public.players where id = v_actor;
    assert v_bank >= 0, 'an underfunded room still never goes negative';
  end loop;
  raise notice 'PASS  underfunded room terminates without ever going negative';

  delete from public.rooms where id = any(v_rooms);
  raise notice '──────────  ALL v2 SERVER-AUTHORITY TESTS PASSED  ──────────';
end
$test$;
