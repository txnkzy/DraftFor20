-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0005 · the client API
--
-- Every mutating function does the same four things:
--   1. SELECT ... FOR UPDATE on the room row, so all actions in a room queue.
--   2. Authenticate from the session token, never a client-supplied id.
--   3. Re-read bankroll / roster / lot state and re-validate against it.
--   4. Commit, bump version, broadcast.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.df20_gen_code() returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare a text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; v text; i int;
begin
  loop
    v := '';
    for i in 1..6 loop
      v := v || substr(a, 1 + floor(random() * length(a))::int, 1);
    end loop;
    exit when not exists (select 1 from public.rooms where code = v);
  end loop;
  return v;
end $$;
revoke all on function public.df20_gen_code() from anon, authenticated;

-- ── CREATE ROOM ────────────────────────────────────────────────────────────
create or replace function public.create_room(
  p_title text, p_roster_size int, p_bankroll_cents int, p_min_bid_cents int,
  p_timer_seconds int, p_host_name text, p_is_private boolean default true,
  p_gives_per_player int default 2, p_brand_accent text default null,
  p_brand_logo_url text default null
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_pl public.players; v_uid uuid; v_pool int;
begin
  v_uid := auth.uid();

  p_title := public.df20_clean_text(p_title, 60);
  if length(p_title) = 0 then p_title := 'Football Draft'; end if;

  p_host_name := public.df20_clean_text(p_host_name, 24);
  if length(p_host_name) = 0 then raise exception 'DF20_BAD_NAME'; end if;

  if p_roster_size is null or p_roster_size < 1 or p_roster_size > 30
    then raise exception 'DF20_BAD_ROSTER_SIZE'; end if;
  if p_bankroll_cents is null or p_bankroll_cents < 0 or p_bankroll_cents > 10000000
    then raise exception 'DF20_BAD_BANKROLL'; end if;
  if p_min_bid_cents is null or p_min_bid_cents < 0 or p_min_bid_cents > 1000000
    then raise exception 'DF20_BAD_MIN_BID'; end if;
  if p_timer_seconds is null or p_timer_seconds < 3 or p_timer_seconds > 300
    then raise exception 'DF20_BAD_TIMER'; end if;
  if p_gives_per_player is null or p_gives_per_player < 0 or p_gives_per_player > 30
    then raise exception 'DF20_BAD_GIVES'; end if;

  select count(*) into v_pool from public.nfl_players;
  if v_pool < p_roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;

  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, gives_per_player,
                            is_private, brand_accent, brand_logo_url, host_profile_id)
  values (public.df20_gen_code(), p_title, p_roster_size, p_bankroll_cents,
          p_min_bid_cents, p_timer_seconds, p_gives_per_player,
          coalesce(p_is_private, true),
          public.df20_clean_text(p_brand_accent, 9),
          public.df20_clean_text(p_brand_logo_url, 500), v_uid)
  returning * into v_room;

  insert into public.players (room_id, seat, display_name, bankroll_cents, is_host, profile_id)
  values (v_room.id, 1, p_host_name, p_bankroll_cents, true, v_uid)
  returning * into v_pl;

  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code,
                            'player_id', v_pl.id, 'session_token', v_pl.session_token,
                            'seat', 1);
end $$;

-- ── JOIN ───────────────────────────────────────────────────────────────────
create or replace function public.join_room(p_code text, p_display_name text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_pl public.players; v_n int;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  if v_room.status <> 'lobby' then raise exception 'DF20_ALREADY_STARTED'; end if;

  p_display_name := public.df20_clean_text(p_display_name, 24);
  if length(p_display_name) = 0 then raise exception 'DF20_BAD_NAME'; end if;

  select count(*) into v_n from public.players where room_id = v_room.id;
  if v_n >= 2 then raise exception 'DF20_ROOM_FULL'; end if;

  insert into public.players (room_id, seat, display_name, bankroll_cents, is_host)
  values (v_room.id, 2, p_display_name, v_room.starting_bankroll_cents, false)
  returning * into v_pl;

  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);
  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code,
                            'player_id', v_pl.id, 'session_token', v_pl.session_token,
                            'seat', 2);
end $$;

-- ── START: shuffle the hidden deck, deal the first card ────────────────────
create or replace function public.start_draft(p_code text, p_token uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_me public.players; v_n int; v_size int; v_pool int;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  select * into v_me from public.players
   where room_id = v_room.id and session_token = p_token;
  if not found then raise exception 'DF20_BAD_TOKEN'; end if;
  if not v_me.is_host then raise exception 'DF20_HOST_ONLY'; end if;
  if v_room.status <> 'lobby' then raise exception 'DF20_ALREADY_STARTED'; end if;

  select count(*) into v_n from public.players where room_id = v_room.id;
  if v_n <> 2 then raise exception 'DF20_NEED_TWO_PLAYERS'; end if;

  -- A room draws a small random SUBSET of the pool, sized to the game, so that
  -- scarcity is real and the deck is different every draft.
  select count(*) into v_pool from public.nfl_players;
  v_size := least(greatest(v_room.roster_size * 6, v_room.roster_size * 2 + 4), v_pool);

  insert into public.room_deck (room_id, position, nfl_player_id)
  select v_room.id, row_number() over (order by s.r), s.id
    from (select id, random() as r from public.nfl_players order by random() limit v_size) s;

  update public.rooms set status = 'live', started_at = now() where id = v_room.id;
  perform public.df20_reveal_next(v_room.id);      -- seat 1 opens the first card
  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);
  return public.df20_public_state(v_room.id);
end $$;

-- ── THE OFFER: take it at the minimum, or hand it over for nothing ─────────
create or replace function public.offer_decide(p_code text, p_token uuid, p_choice text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_room public.rooms; v_me public.players; v_lot public.lots;
  v_opp uuid; v_max int; v_can_take boolean; v_can_give boolean;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  select * into v_me from public.players
   where room_id = v_room.id and session_token = p_token;
  if not found then raise exception 'DF20_BAD_TOKEN'; end if;

  select * into v_lot from public.lots
   where room_id = v_room.id and status = 'offered' for update;
  if not found then raise exception 'DF20_NO_LIVE_LOT'; end if;
  if v_room.phase <> 'offering' then raise exception 'DF20_WRONG_PHASE'; end if;
  if v_lot.opener_player_id is distinct from v_me.id
    then raise exception 'DF20_NOT_YOUR_TURN'; end if;

  v_opp := public.df20_opponent(v_room.id, v_me.id);
  v_max := public.df20_max_legal_bid(v_me.bankroll_cents, v_room.min_bid_cents,
                                     public.df20_open_slots(v_room.id, v_me.id));
  v_can_take := v_max >= v_room.min_bid_cents
                and public.df20_open_slots(v_room.id, v_me.id) > 0;
  v_can_give := public.df20_open_slots(v_room.id, v_opp) > 0
                and v_me.gives_used < v_room.gives_per_player;

  if p_choice = 'take' then
    if not v_can_take then raise exception 'DF20_CANNOT_AFFORD'; end if;

    insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
    values (v_room.id, v_lot.id, v_me.id, 'offer_take', v_room.min_bid_cents, v_lot.turn_seq);

    if public.df20_can_outbid(v_room.id, v_opp, v_room.min_bid_cents) then
      update public.lots
         set status = 'bidding', on_the_clock_player_id = v_opp,
             turn_expires_at = now() + make_interval(secs => v_room.timer_seconds),
             turn_seq = turn_seq + 1
       where id = v_lot.id;
      update public.rooms set phase = 'bidding' where id = v_room.id;
    else
      perform public.df20_resolve_lot(v_lot.id, 'won');
    end if;

  elsif p_choice = 'give' then
    if public.df20_open_slots(v_room.id, v_opp) <= 0 then raise exception 'DF20_THEY_ARE_FULL'; end if;
    if v_me.gives_used >= v_room.gives_per_player then raise exception 'DF20_NO_GIVES_LEFT'; end if;
    perform public.df20_resolve_gift(v_lot.id, v_me.id);

  elsif p_choice = 'discard' then
    -- only legal when the opener genuinely cannot do anything else
    if v_can_take or v_can_give then raise exception 'DF20_MUST_TAKE_OR_GIVE'; end if;
    perform public.df20_discard_lot(v_lot.id);

  else
    raise exception 'DF20_BAD_CHOICE';
  end if;

  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);
  return public.df20_public_state(v_room.id);
end $$;

-- ── PLACE BID ── unchanged logic, the part that must not regress ───────────
create or replace function public.place_bid(
  p_code text, p_token uuid, p_amount_cents int, p_expected_turn_seq int
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_me public.players; v_lot public.lots; v_opp uuid; v_max int;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  select * into v_me from public.players
   where room_id = v_room.id and session_token = p_token;
  if not found then raise exception 'DF20_BAD_TOKEN'; end if;
  select * into v_lot from public.lots
   where room_id = v_room.id and status = 'bidding' for update;
  if not found then raise exception 'DF20_NO_LIVE_LOT'; end if;

  if v_room.phase <> 'bidding'                       then raise exception 'DF20_WRONG_PHASE'; end if;
  if v_lot.on_the_clock_player_id is distinct from v_me.id
                                                     then raise exception 'DF20_NOT_YOUR_TURN'; end if;
  if v_lot.turn_seq <> p_expected_turn_seq           then raise exception 'DF20_STALE'; end if;
  if now() > v_lot.turn_expires_at + interval '400 milliseconds'
                                                     then raise exception 'DF20_EXPIRED'; end if;
  if p_amount_cents is null or p_amount_cents <= v_lot.current_bid_cents
                                                     then raise exception 'DF20_TOO_LOW'; end if;
  if public.df20_open_slots(v_room.id, v_me.id) <= 0 then raise exception 'DF20_ROSTER_FULL'; end if;

  -- HARD CAP + RESERVE RULE against the bankroll as it is RIGHT NOW
  v_max := public.df20_max_legal_bid(v_me.bankroll_cents, v_room.min_bid_cents,
                                     public.df20_open_slots(v_room.id, v_me.id));
  if p_amount_cents > v_me.bankroll_cents then raise exception 'DF20_OVER_BANKROLL'; end if;
  if p_amount_cents > v_max               then raise exception 'DF20_OVER_RESERVE'; end if;

  v_opp := public.df20_opponent(v_room.id, v_me.id);
  update public.lots
     set current_bid_cents = p_amount_cents, high_bidder_player_id = v_me.id,
         on_the_clock_player_id = v_opp,
         turn_expires_at = now() + make_interval(secs => v_room.timer_seconds),
         turn_seq = turn_seq + 1
   where id = v_lot.id
  returning * into v_lot;

  insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
  values (v_room.id, v_lot.id, v_me.id, 'raise', p_amount_cents, v_lot.turn_seq);

  if not public.df20_can_outbid(v_room.id, v_opp, p_amount_cents) then
    perform public.df20_resolve_lot(v_lot.id, 'blocked_win');
  end if;

  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);
  return public.df20_public_state(v_room.id);
end $$;

-- ── PASS ───────────────────────────────────────────────────────────────────
create or replace function public.pass_turn(p_code text, p_token uuid, p_expected_turn_seq int)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_me public.players; v_lot public.lots;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  select * into v_me from public.players
   where room_id = v_room.id and session_token = p_token;
  if not found then raise exception 'DF20_BAD_TOKEN'; end if;
  select * into v_lot from public.lots
   where room_id = v_room.id and status = 'bidding' for update;
  if not found then raise exception 'DF20_NO_LIVE_LOT'; end if;

  if v_room.phase <> 'bidding' then raise exception 'DF20_WRONG_PHASE'; end if;
  if v_lot.on_the_clock_player_id is distinct from v_me.id
    then raise exception 'DF20_NOT_YOUR_TURN'; end if;
  if v_lot.turn_seq <> p_expected_turn_seq then raise exception 'DF20_STALE'; end if;

  insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
  values (v_room.id, v_lot.id, v_me.id, 'pass', v_lot.current_bid_cents, v_lot.turn_seq);

  perform public.df20_resolve_lot(v_lot.id, 'won');
  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);
  return public.df20_public_state(v_room.id);
end $$;

-- ── EXPIRE ── unauthenticated and idempotent; both clients race to call it ─
create or replace function public.expire_turn(p_code text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_lot public.lots; v_opener public.players;
        v_opp uuid; v_max int;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;

  select * into v_lot from public.lots
   where room_id = v_room.id and status in ('offered','bidding') for update;
  if not found then return public.df20_public_state(v_room.id); end if;
  if v_lot.turn_expires_at is null or now() <= v_lot.turn_expires_at then
    return public.df20_public_state(v_room.id);          -- not expired: no-op
  end if;

  if v_lot.status = 'offered' then
    -- Timing out on an offer defaults to TAKE: you are out the minimum bid, not
    -- a roster spot. It never auto-spends a give, because giving is a weapon
    -- with a budget and nobody should lose one by looking away.
    select * into v_opener from public.players where id = v_lot.opener_player_id;
    v_max := public.df20_max_legal_bid(v_opener.bankroll_cents, v_room.min_bid_cents,
                                       public.df20_open_slots(v_room.id, v_opener.id));
    if v_max >= v_room.min_bid_cents then
      insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
      values (v_room.id, v_lot.id, v_opener.id, 'offer_take', v_room.min_bid_cents, v_lot.turn_seq);

      v_opp := public.df20_opponent(v_room.id, v_opener.id);
      if public.df20_can_outbid(v_room.id, v_opp, v_room.min_bid_cents) then
        update public.lots
           set status = 'bidding', on_the_clock_player_id = v_opp,
               turn_expires_at = now() + make_interval(secs => v_room.timer_seconds),
               turn_seq = turn_seq + 1
         where id = v_lot.id;
        update public.rooms set phase = 'bidding' where id = v_room.id;
      else
        perform public.df20_resolve_lot(v_lot.id, 'won');
      end if;
    else
      perform public.df20_discard_lot(v_lot.id);
    end if;
  else
    insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
    values (v_room.id, v_lot.id, v_lot.on_the_clock_player_id, 'timeout_pass',
            v_lot.current_bid_cents, v_lot.turn_seq);
    perform public.df20_resolve_lot(v_lot.id, 'won');
  end if;

  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);
  return public.df20_public_state(v_room.id);
end $$;

-- ── POST-DRAFT VOTE ────────────────────────────────────────────────────────
create or replace function public.submit_vote(p_code text, p_token uuid, p_winner_player_id uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_me public.players;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  select * into v_me from public.players
   where room_id = v_room.id and session_token = p_token;
  if not found then raise exception 'DF20_BAD_TOKEN'; end if;
  if v_room.status <> 'complete' then raise exception 'DF20_NOT_COMPLETE'; end if;
  if not exists (select 1 from public.players
                  where id = p_winner_player_id and room_id = v_room.id)
    then raise exception 'DF20_BAD_VOTE'; end if;

  insert into public.votes (room_id, voter_player_id, winner_player_id)
  values (v_room.id, v_me.id, p_winner_player_id)
  on conflict (room_id, voter_player_id)
  do update set winner_player_id = excluded.winner_player_id;

  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);
  return public.df20_public_state(v_room.id);
end $$;

create or replace function public.get_room_state(p_code text)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  select id into v_id from public.rooms where code = upper(btrim(p_code));
  if not found then return null; end if;
  return public.df20_public_state(v_id);
end $$;

grant execute on function public.create_room(text, int, int, int, int, text, boolean, int, text, text) to anon, authenticated;
grant execute on function public.join_room(text, text)              to anon, authenticated;
grant execute on function public.start_draft(text, uuid)            to anon, authenticated;
grant execute on function public.offer_decide(text, uuid, text)     to anon, authenticated;
grant execute on function public.place_bid(text, uuid, int, int)    to anon, authenticated;
grant execute on function public.pass_turn(text, uuid, int)         to anon, authenticated;
grant execute on function public.expire_turn(text)                  to anon, authenticated;
grant execute on function public.submit_vote(text, uuid, uuid)      to anon, authenticated;
grant execute on function public.get_room_state(text)               to anon, authenticated;
