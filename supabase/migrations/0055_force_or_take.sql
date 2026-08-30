-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0055 · Force-or-Take, the half of 0041 that was never built
--
-- 0041 let a player bid themselves to zero and said in its own header that
-- "Force-or-Take covers the slots that can no longer be afforded". There was
-- no Force. A broke opener had three doors and all three were shut:
--
--   Take    — needs max_legal_bid >= min_bid, and theirs is 0
--   Give    — needs a give, and gives_per_player defaults to 2
--   Discard — legal precisely because the other two are not
--
-- So they discarded. And discarded. The deck is roster_size * 6, so there is
-- always another card, and none of them could ever reach a roster they still
-- owed slots on. The draft ended with open_slots > 0, which isBusted() reads
-- as "busted · disqualified" on the results card. A player who spent hard —
-- the exact moment 0041 exists to permit — was punished with a loss screen
-- and a button that did nothing but deal the next unplayable card.
--
-- THE FORCE: if the opener cannot cover the minimum but still owes slots, the
-- card lands on THEIR roster at $0. Not the opponent's — a player out of
-- money is not thereby entitled to stuff someone else's board. This is the
-- floor of the format: spend everything on the one you want, and take what
-- the deck hands you afterwards.
--
-- Discard survives for the one case that is genuinely nothing-to-do: the
-- opener's roster is full. offer_decide now rejects 'discard' whenever a
-- force is available, so the dead end is unreachable rather than merely
-- unattractive.
--
-- Re-runnable. Restates offer_decide and expire_turn from 0041 byte for byte
-- apart from the force branch; no money rule and no validation order moves.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── the action vocabulary learns one word ─────────────────────────────────
-- A forced pick is NOT offer_take (nothing was paid) and NOT offer_give
-- (nobody chose it). Reusing either would make the bid history lie about how
-- a card got where it is, and the history is the thing people rewatch.
alter table public.bid_events drop constraint if exists bid_events_action_check;
alter table public.bid_events add constraint bid_events_action_check
  check (action in ('reveal','offer_take','offer_give','discard','raise',
                    'pass','timeout_pass','won','blocked_win','offer_forced'));

-- ── a forced pick is free, but it is NOT a gift ───────────────────────────
-- It is priced at 0 and flagged gifted, both of which are true. But the
-- roster row rendered "given" and the results card counted it in "N players
-- were handed over for free", and nobody handed it over. Same objection as
-- the bid_events vocabulary above: free and given are different facts.
alter table public.roster_entries add column if not exists forced boolean not null default false;
alter table public.lots           add column if not exists forced boolean not null default false;

comment on column public.roster_entries.forced is
  'true when the card landed here because the owner could not cover the '
  'minimum bid, not because anybody gave it to them. Priced at 0 and flagged '
  'gifted alongside this, because it WAS free — but the board must not say '
  '"given" about a card nobody gave.';

-- ── the force itself ──────────────────────────────────────────────────────
-- Shaped like df20_resolve_gift, with two differences: it lands on the player
-- passed in rather than their opponent, and it does not spend a give. Priced
-- at 0 and flagged gifted, because on the results card it is free — the one
-- thing about it that is true from every angle.
create or replace function public.df20_force_lot(p_lot uuid, p_player uuid)
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_lot public.lots; v_pick int;
begin
  select * into v_lot from public.lots where id = p_lot for update;
  if v_lot.status not in ('offered', 'bidding') then return; end if;
  if public.df20_open_slots(v_lot.room_id, p_player) <= 0 then
    raise exception 'DF20_ROSTER_FULL';
  end if;

  perform public.df20_add_to_roster(v_lot.room_id, p_player, v_lot.item_name, 0, true);

  -- Flag the row we just inserted. Going through df20_add_to_roster rather
  -- than adding a sixth argument to it is deliberate: 0010 already had to
  -- DROP an earlier six-argument overload of that function, and a defaulted
  -- parameter would make every positional call ambiguous again. The room row
  -- is locked by the caller, so max(pick_number) is still ours.
  select max(pick_number) into v_pick from public.roster_entries
   where room_id = v_lot.room_id and player_id = p_player;
  update public.roster_entries set forced = true
   where room_id = v_lot.room_id and player_id = p_player and pick_number = v_pick;

  update public.lots
     set status = 'resolved', winner_player_id = p_player, final_price_cents = 0,
         gifted = true, forced = true, on_the_clock_player_id = null,
         turn_expires_at = null, resolved_at = now()
   where id = p_lot;

  insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
  values (v_lot.room_id, p_lot, p_player, 'offer_forced', 0, v_lot.turn_seq);

  perform public.df20_advance(v_lot.room_id);
end $$;
revoke all on function public.df20_force_lot(uuid, uuid) from public;

-- ── offer_decide, with the fourth door ────────────────────────────────────
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

-- ── expire_turn, so looking away lands the same result ────────────────────
-- Timing out on an offer already defaulted to Take. It now defaults to Force
-- when Take is unaffordable, for the same reason: the clock must never be
-- able to hand a player an outcome they could not have chosen themselves.
-- It still never spends a give.
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

-- ── selfcheck ─────────────────────────────────────────────────────────────
create or replace function public.df20_selfcheck_force()
returns text language plpgsql
set search_path = public, pg_temp as $$
begin
  if to_regprocedure('public.df20_force_lot(uuid,uuid)') is null then
    raise exception 'DF20_SELFCHECK: df20_force_lot(uuid,uuid) is missing';
  end if;
  -- the constraint has to actually admit the new word, or every force fails
  -- at insert time with the lot already half-resolved
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.bid_events'::regclass
       and conname  = 'bid_events_action_check'
       and pg_get_constraintdef(oid) like '%offer_forced%') then
    raise exception 'DF20_SELFCHECK: bid_events still rejects offer_forced';
  end if;
  return 'force-or-take ok';
end $$;
revoke all on function public.df20_selfcheck_force() from public;

select public.df20_selfcheck_force();
