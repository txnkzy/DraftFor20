-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · v12 · bidding yourself broke, and the toggle that forbids it
--
-- The assertion that matters: with allow_broke on, a player can spend to
-- EXACTLY zero with slots still open, and the books still balance afterwards.
-- The Hard Cap is checked in both modes, because the whole risk of this
-- change is that removing the reserve accidentally removes the cap with it.
-- ═══════════════════════════════════════════════════════════════════════════

do $t$
declare
  v jsonb; v_code text; v_rid uuid; v_ht uuid; v_gt uuid;
  v_a uuid; v_b uuid; v_lib uuid; v_err text; v_seq int;
  v_bank int; v_spent int; v_open int; v_rooms uuid[] := '{}';
begin
  select id into v_lib from public.category_library
   where name_norm = public.df20_norm_category('Football Draft');

  -- ── 1. the rule itself, both ways ───────────────────────────────────────
  assert public.df20_max_legal_bid(2000, 100, 5, false) = 1600, 'reserve keeps 4 x min back';
  assert public.df20_max_legal_bid(2000, 100, 5, true)  = 2000, 'broke-allowed spends it all';
  assert public.df20_max_legal_bid(300,  100, 5, false) = 100,  'underfunded still degrades';
  assert public.df20_max_legal_bid(300,  100, 5, true)  = 300,  'and is unrestricted when broke is allowed';

  -- THE HARD CAP, which must survive both branches. This is the thing that
  -- must never break: it is the only rule standing between a bid and a
  -- negative bankroll.
  -- the cap is "never more than the bankroll", which is an upper bound, not
  -- an equality: with the reserve on, $500 across 5 slots correctly caps at
  -- one minimum bid because the other four have to be covered.
  assert public.df20_max_legal_bid(500, 100, 5, true)  = 500, 'broke on: the whole bankroll';
  assert public.df20_max_legal_bid(500, 100, 5, false) = 100, 'broke off: reserve keeps 4 x min back';
  assert public.df20_max_legal_bid(500, 100, 5, true)  <= 500, 'HARD CAP (broke on)';
  assert public.df20_max_legal_bid(500, 100, 5, false) <= 500, 'HARD CAP (broke off)';
  assert public.df20_max_legal_bid(99, 100, 1, true)   <= 99,  'cannot bid what you do not hold';
  assert public.df20_max_legal_bid(0,   100, 3, true)  = 0,   'nothing to bid with';
  assert public.df20_max_legal_bid(500, 100, 0, true)  = 0,   'roster full, no stake';
  raise notice 'PASS  one conditional: reserve differs, the Hard Cap does not';

  -- ── 2. a real draft, bidding to exactly zero ────────────────────────────
  v := public.create_room('Broke Test', 3, 2000, 100, 300, 'Ari', true, 0,
                          null, null, 'library', v_lib, 'standard', true);
  v_code := v->>'code'; v_ht := (v->>'session_token')::uuid;
  v_a := (v->>'player_id')::uuid; v_rid := (v->>'room_id')::uuid;
  v_rooms := v_rooms || v_rid;
  assert (select allow_broke from public.rooms where id = v_rid), 'room stored the setting';

  v := public.join_room(v_code, 'Bo');
  v_gt := (v->>'session_token')::uuid; v_b := (v->>'player_id')::uuid;
  perform public.start_draft(v_code, v_ht);

  -- seat 1 takes, seat 2 shoves the entire bankroll in on the first card
  perform public.offer_decide(v_code, v_ht, 'take');
  select turn_seq into v_seq from public.lots where room_id = v_rid and status = 'bidding';
  v := public.place_bid(v_code, v_gt, 2000, v_seq);

  select bankroll_cents into v_bank from public.players where id = v_b;
  select public.df20_open_slots(v_rid, v_b) into v_open;
  assert v_bank = 0, format('seat 2 should be at zero, is %s', v_bank);
  assert v_open > 0, 'with slots still owed — the state the Reserve Rule existed to prevent';
  raise notice 'PASS  a player bid to exactly $0 with % slots still open', v_open;

  -- ── 3. Force-or-Take takes over, which is the entire point ─────────────
  -- The broke player opens the next card. They cannot take it, so the flow
  -- the Reserve Rule existed to avoid is now the flow that handles it.
  if exists (select 1 from public.lots where room_id = v_rid and status = 'offered'
               and opener_player_id = v_b) then
    v_err := null;
    begin perform public.offer_decide(v_code, v_gt, 'take');
    exception when others then v_err := sqlerrm; end;
    assert v_err like '%DF20_CANNOT_AFFORD%',
      format('a broke opener must be refused a take, got: %s', coalesce(v_err, 'accepted'));
    raise notice 'PASS  broke opener refused the take — Force-or-Take is in control';

    -- This room was built with zero gives, so the broke opener has neither a
    -- take nor a give: discard is the only legal move, and it must be
    -- available or the draft would deadlock right here.
    v_err := null;
    begin perform public.offer_decide(v_code, v_gt, 'give');
    exception when others then v_err := sqlerrm; end;
    assert v_err like '%DF20_NO_GIVES_LEFT%',
      format('no gives were configured, expected refusal, got: %s', coalesce(v_err,'accepted'));

    perform public.offer_decide(v_code, v_gt, 'discard');
    raise notice 'PASS  broke, no gives left: discard is available and the draft moves on';
  end if;

  -- ── 4. the draft still finishes, and the books still balance ────────────
  for i in 1..40 loop
    exit when (select status from public.rooms where id = v_rid) = 'complete';

    if exists (select 1 from public.lots where room_id = v_rid and status = 'offered') then
      -- take, else give, else discard: whichever the server will accept.
      -- A broke opener with no gives has only the third, and if none of them
      -- worked the draft would be deadlocked, which the guard below catches.
      declare v_tok uuid; v_done boolean := false;
      begin
        select p.session_token into v_tok from public.lots l
          join public.players p on p.id = l.opener_player_id
         where l.room_id = v_rid and l.status = 'offered';
        foreach v_err in array array['take','give','discard'] loop
          begin
            perform public.offer_decide(v_code, v_tok, v_err);
            v_done := true;
            exit;
          exception when others then null;
          end;
        end loop;
        assert v_done, 'DEADLOCK: the opener had no legal move at all';
      end;

    elsif exists (select 1 from public.lots where room_id = v_rid and status = 'bidding') then
      perform public.pass_turn(v_code,
        (select p.session_token from public.lots l join public.players p on p.id = l.on_the_clock_player_id
          where l.room_id = v_rid and l.status = 'bidding'),
        (select turn_seq from public.lots where room_id = v_rid and status = 'bidding'));
    end if;
  end loop;

  assert (select status from public.rooms where id = v_rid) = 'complete',
    'a draft where somebody went broke still terminates';

  -- NOBODY EVER WENT NEGATIVE. The safety net, checked directly.
  assert not exists (select 1 from public.players where room_id = v_rid and bankroll_cents < 0),
    'a bankroll went negative — the Hard Cap failed';
  -- separate subqueries, not a join: joining players to roster_entries
  -- repeats each bankroll once per card won and inflates the total
  select (select coalesce(sum(bankroll_cents), 0) from public.players where room_id = v_rid)
       + (select coalesce(sum(price_cents), 0) from public.roster_entries where room_id = v_rid)
    into v_spent;
  assert v_spent = 4000, format('books do not balance: %s of 4000', v_spent);
  raise notice 'PASS  draft completed, no negative bankroll, books balance at $40';

  delete from public.rooms where id = any(v_rooms);
  raise notice '───────────────────────────────────────────────';
  raise notice 'v12 SUITE PASSED';
end $t$;
