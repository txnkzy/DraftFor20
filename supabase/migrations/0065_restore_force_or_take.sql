-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0065 · Force-or-Take, restored and made the last word
--
-- THIS HAS NOW BEEN LOST TWICE. First on 8 Sep, unnoticed for twelve days,
-- which killed ~550 drafts. Restored 20 Sep; gone again within two hours.
--
-- The cause is structural, not careless. FOUR files define offer_decide:
--   0005_rpc.sql              no force
--   0021_timer.sql            no force
--   0041_allow_broke.sql      no force
--   0055_force_or_take.sql    force
-- Three of the four delete the branch. Any one applied after 0055 — a bundle
-- run in the wrong order, someone re-applying a single file, two people
-- numbering from the same point — puts the game back where a broke player
-- with slots owed and a full opponent has no legal move, and their draft can
-- never finish.
--
-- 0060 asserted the branch existed and failed loudly. Not enough: it catches
-- the bundle and nothing else. So this file RESTORES rather than asserts. It
-- is generated from 0055 and must run LAST, after every file that could
-- overwrite it. Re-running it is always safe and always correct, which is the
-- property an assertion does not have.
--
-- If you add a fifth definer of offer_decide, put the force branch in it or
-- move this file after it. There is no third option.
--
-- Re-runnable. MUST BE LAST.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.offer_decide(p_code text, p_token uuid, p_choice text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_room public.rooms; v_me public.players; v_lot public.lots;
  v_opp uuid; v_max int; v_open int;
  v_can_take boolean; v_can_give boolean; v_can_force boolean;
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

  v_opp  := public.df20_opponent(v_room.id, v_me.id);
  v_open := public.df20_open_slots(v_room.id, v_me.id);
  v_max  := public.df20_max_legal_bid(v_me.bankroll_cents, v_room.min_bid_cents,
                                      v_open, v_room.allow_broke);
  v_can_take  := v_max >= v_room.min_bid_cents and v_open > 0;
  v_can_give  := public.df20_open_slots(v_room.id, v_opp) > 0
                 and v_me.gives_used < v_room.gives_per_player;
  -- FORCE is exactly the case Take is not: slots owed, money short.
  v_can_force := v_open > 0 and not v_can_take;

  if p_choice = 'take' then
    if not v_can_take then raise exception 'DF20_CANNOT_AFFORD'; end if;

    insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
    values (v_room.id, v_lot.id, v_me.id, 'offer_take', v_room.min_bid_cents, v_lot.turn_seq);

    if public.df20_can_outbid(v_room.id, v_opp, v_room.min_bid_cents) then
      update public.lots
         set status = 'bidding', on_the_clock_player_id = v_opp,
             turn_expires_at = public.df20_turn_deadline(v_room.timer_seconds),
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

  elsif p_choice = 'force' then
    -- Never a way to dodge paying: if Take is available, Take is the price.
    if v_can_take then raise exception 'DF20_MUST_TAKE_OR_GIVE'; end if;
    if v_open <= 0 then raise exception 'DF20_ROSTER_FULL'; end if;
    perform public.df20_force_lot(v_lot.id, v_me.id);

  elsif p_choice = 'discard' then
    -- only when there is genuinely nothing to do with this card
    if v_can_take or v_can_give or v_can_force then raise exception 'DF20_MUST_TAKE_OR_GIVE'; end if;
    perform public.df20_discard_lot(v_lot.id);

  else
    raise exception 'DF20_BAD_CHOICE';
  end if;

  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);
  return public.df20_public_state(v_room.id);
end $$;

create or replace function public.expire_turn(p_code text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_lot public.lots; v_opener public.players;
        v_opp uuid; v_max int; v_open int;
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
    select * into v_opener from public.players where id = v_lot.opener_player_id;
    v_open := public.df20_open_slots(v_room.id, v_opener.id);
    v_max  := public.df20_max_legal_bid(v_opener.bankroll_cents, v_room.min_bid_cents,
                                        v_open, v_room.allow_broke);
    if v_max >= v_room.min_bid_cents and v_open > 0 then
      insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
      values (v_room.id, v_lot.id, v_opener.id, 'offer_take', v_room.min_bid_cents, v_lot.turn_seq);

      v_opp := public.df20_opponent(v_room.id, v_opener.id);
      if public.df20_can_outbid(v_room.id, v_opp, v_room.min_bid_cents) then
        update public.lots
           set status = 'bidding', on_the_clock_player_id = v_opp,
               turn_expires_at = public.df20_turn_deadline(v_room.timer_seconds),
               turn_seq = turn_seq + 1
         where id = v_lot.id;
        update public.rooms set phase = 'bidding' where id = v_room.id;
      else
        perform public.df20_resolve_lot(v_lot.id, 'won');
      end if;
    elsif v_open > 0 then
      perform public.df20_force_lot(v_lot.id, v_opener.id);
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

grant execute on function public.offer_decide(text, uuid, text) to anon, authenticated;
grant execute on function public.expire_turn(text)              to anon, authenticated;

do $$
begin
  if pg_get_functiondef(to_regprocedure('public.offer_decide(text,uuid,text)')) !~ 'force'
    then raise exception 'offer_decide has no force branch after 0065'; end if;
  if pg_get_functiondef(to_regprocedure('public.expire_turn(text)')) !~ 'force'
    then raise exception 'expire_turn has no force branch after 0065'; end if;
  raise notice 'Force-or-Take restored (0065 ran last, as it must)';
end $$;
