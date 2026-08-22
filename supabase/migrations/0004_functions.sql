-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0004 · internal game logic
--
-- THE MONEY RULES LIVE HERE AND NOWHERE ELSE. Unchanged from v1:
--   open(P)          = roster_size - players P has already won
--   reserve(P)       = min_bid x (open(P) - 1)
--   max_legal_bid(P) = bankroll(P) - reserve(P)
-- ═══════════════════════════════════════════════════════════════════════════

-- ── HARD CAP + RESERVE RULE ────────────────────────────────────────────────
create or replace function public.df20_max_legal_bid(p_bankroll int, p_min_bid int, p_open int)
returns int language plpgsql immutable as $$
declare v int;
begin
  if p_open <= 0 then return 0; end if;
  v := p_bankroll - (p_min_bid * (p_open - 1));
  -- Underfunded room: the reserve cannot be met at all. Degrade to exactly one
  -- minimum bid rather than locking the player out of every legal action.
  if v < p_min_bid then
    if p_bankroll >= p_min_bid then v := p_min_bid; else v := 0; end if;
  end if;
  return greatest(least(v, p_bankroll), 0);   -- HARD CAP
end $$;

create or replace function public.df20_open_slots(p_room uuid, p_player uuid)
returns int language sql stable as $$
  select greatest(
    (select roster_size from public.rooms where id = p_room)
    - (select count(*)::int from public.roster_entries
        where room_id = p_room and player_id = p_player), 0)
$$;

create or replace function public.df20_opponent(p_room uuid, p_player uuid)
returns uuid language sql stable as $$
  select id from public.players
   where room_id = p_room and id is distinct from p_player limit 1
$$;

create or replace function public.df20_is_broke(p_room uuid, p_player uuid)
returns boolean language plpgsql stable as $$
declare v_min int; v_bank int;
begin
  select min_bid_cents into v_min from public.rooms where id = p_room;
  select bankroll_cents into v_bank from public.players where id = p_player;
  return v_bank < v_min and public.df20_open_slots(p_room, p_player) > 0;
end $$;

-- can this player legally bid STRICTLY MORE than p_amount?
create or replace function public.df20_can_outbid(p_room uuid, p_player uuid, p_amount int)
returns boolean language plpgsql stable as $$
declare v_min int; v_bank int; v_open int;
begin
  select min_bid_cents into v_min from public.rooms where id = p_room;
  select bankroll_cents into v_bank from public.players where id = p_player;
  if v_bank is null then return false; end if;
  v_open := public.df20_open_slots(p_room, p_player);
  if v_open <= 0 then return false; end if;              -- roster full, no stake
  return public.df20_max_legal_bid(v_bank, v_min, v_open) > p_amount;
end $$;

create or replace function public.df20_deck_remaining(p_room uuid)
returns int language sql stable as $$
  select count(*)::int from public.room_deck
   where room_id = p_room and revealed_at is null
$$;

-- ── text safety. React escapes on render; this strips what escaping does not
--    cover: control characters, zero-width joiners and bidi overrides, which
--    are how you smuggle a misleading display name past a human reader. ─────
create or replace function public.df20_clean_text(p_in text, p_max int)
returns text language plpgsql immutable as $$
declare v text;
begin
  v := coalesce(p_in, '');
  v := regexp_replace(v, E'[\\x00-\\x1F\\x7F]', '', 'g');
  v := regexp_replace(v, E'[\\u200B-\\u200F\\u202A-\\u202E\\u2066-\\u2069\\uFEFF]', '', 'g');
  v := regexp_replace(v, E'\\s+', ' ', 'g');
  v := btrim(v);
  if length(v) > p_max then v := left(v, p_max); end if;
  return v;
end $$;

-- ── the snapshot every client renders from ─────────────────────────────────
-- Reads room_deck ONLY to count unrevealed rows. It must never expose a name
-- that has not been dealt, or the hidden deck stops being hidden.
create or replace function public.df20_public_state(p_room uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp set timezone = 'UTC' as $$
declare v_room public.rooms;
begin
  select * into v_room from public.rooms where id = p_room;
  if not found then return null; end if;

  return jsonb_build_object(
    'server_now', to_jsonb(now()),
    'room', to_jsonb(v_room),
    'deck_remaining', public.df20_deck_remaining(p_room),
    'players', coalesce((
        select jsonb_agg(
                 (to_jsonb(pl) - 'session_token')
                 || jsonb_build_object(
                      'open_slots', public.df20_open_slots(p_room, pl.id),
                      'max_legal_bid_cents', public.df20_max_legal_bid(
                          pl.bankroll_cents, v_room.min_bid_cents,
                          public.df20_open_slots(p_room, pl.id)),
                      'is_broke', public.df20_is_broke(p_room, pl.id),
                      'gives_left', greatest(v_room.gives_per_player - pl.gives_used, 0))
                 order by pl.seat)
          from public.players pl where pl.room_id = p_room), '[]'::jsonb),
    'roster', coalesce((select jsonb_agg(to_jsonb(r) order by r.player_id, r.pick_number)
                          from public.roster_entries r where r.room_id = p_room), '[]'::jsonb),
    'lot', (select to_jsonb(l) from public.lots l where l.room_id = p_room
              order by (l.status in ('offered','bidding')) desc, l.created_at desc limit 1),
    'events', coalesce((select jsonb_agg(e order by e.id)
                          from (select * from public.bid_events
                                 where room_id = p_room order by id desc limit 60) e), '[]'::jsonb),
    'votes', coalesce((select jsonb_agg(to_jsonb(v)) from public.votes v
                        where v.room_id = p_room), '[]'::jsonb)
  );
end $$;

create or replace function public.df20_broadcast(p_room uuid)
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
begin
  begin
    perform realtime.send(
      public.df20_public_state(p_room), 'state', 'room:' || p_room::text, false);
  exception when others then null;   -- fast path only; clients also poll
  end;
end $$;

create or replace function public.df20_touch(p_room uuid)
returns void language sql security definer set search_path = public, pg_temp as $$
  update public.rooms set version = version + 1 where id = p_room;
$$;

-- ── the only place a bankroll is ever debited ──────────────────────────────
create or replace function public.df20_add_to_roster(
  p_room uuid, p_player uuid, p_nfl int, p_name text, p_price int, p_gifted boolean)
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_pick int; v_bank int;
begin
  select coalesce(max(pick_number), 0) + 1 into v_pick
    from public.roster_entries where room_id = p_room and player_id = p_player;

  if p_price > 0 then
    update public.players set bankroll_cents = bankroll_cents - p_price
     where id = p_player returning bankroll_cents into v_bank;
    -- SAFETY NET. Unreachable if the Hard Cap and Reserve Rule held upstream.
    if v_bank < 0 then raise exception 'DF20_INVARIANT_NEGATIVE_BANKROLL'; end if;
  end if;

  insert into public.roster_entries
    (room_id, player_id, pick_number, nfl_player_id, item_name, price_cents, gifted)
  values (p_room, p_player, v_pick, p_nfl, p_name, p_price, p_gifted);
end $$;

-- ── DEAL: reveal the next hidden card and open it at the minimum ───────────
create or replace function public.df20_reveal_next(p_room uuid)
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_room public.rooms; v_p1 public.players; v_p2 public.players;
  v_o1 int; v_o2 int; v_opener public.players; v_card record; v_lot uuid;
begin
  select * into v_room from public.rooms where id = p_room;
  select * into v_p1 from public.players where room_id = p_room and seat = 1;
  select * into v_p2 from public.players where room_id = p_room and seat = 2;

  v_o1 := public.df20_open_slots(p_room, v_p1.id);
  v_o2 := public.df20_open_slots(p_room, v_p2.id);

  if v_o1 <= 0 and v_o2 <= 0 then
    update public.rooms
       set phase = 'complete', status = 'complete',
           completed_at = coalesce(completed_at, now())
     where id = p_room;
    return;
  end if;

  -- the alternating opener, unless their roster is already full
  if v_o1 > 0 and v_o2 > 0 then
    v_opener := case when v_room.opener_seat = 1 then v_p1 else v_p2 end;
  elsif v_o1 > 0 then v_opener := v_p1;
  else                v_opener := v_p2;
  end if;

  select d.position as pos, d.nfl_player_id as nfl, n.name as nm into v_card
    from public.room_deck d
    join public.nfl_players n on n.id = d.nfl_player_id
   where d.room_id = p_room and d.revealed_at is null
   order by d.position limit 1;

  if not found then
    -- deck exhausted with slots still owed: rosters finish short and BUST
    update public.rooms
       set phase = 'complete', status = 'complete',
           completed_at = coalesce(completed_at, now())
     where id = p_room;
    return;
  end if;

  update public.room_deck set revealed_at = now()
   where room_id = p_room and position = v_card.pos;

  insert into public.lots
    (room_id, nfl_player_id, item_name, opener_player_id, status,
     current_bid_cents, high_bidder_player_id, on_the_clock_player_id,
     turn_expires_at, turn_seq)
  values
    (p_room, v_card.nfl, v_card.nm, v_opener.id, 'offered',
     v_room.min_bid_cents, v_opener.id, v_opener.id,
     now() + make_interval(secs => v_room.timer_seconds), 1)
  returning id into v_lot;

  insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
  values (p_room, v_lot, null, 'reveal', v_room.min_bid_cents, 1);

  update public.rooms set phase = 'offering' where id = p_room;
end $$;

-- ── after a lot settles: flip the opener, deal again ───────────────────────
create or replace function public.df20_advance(p_room uuid)
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
begin
  update public.rooms
     set opener_seat = case when opener_seat = 1 then 2 else 1 end
   where id = p_room;
  perform public.df20_reveal_next(p_room);
end $$;

-- ── RESOLVE: the standing high bidder buys ─────────────────────────────────
create or replace function public.df20_resolve_lot(p_lot uuid, p_action text)
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_lot public.lots;
begin
  select * into v_lot from public.lots where id = p_lot for update;
  if v_lot.status not in ('offered', 'bidding') then return; end if;

  perform public.df20_add_to_roster(
    v_lot.room_id, v_lot.high_bidder_player_id, v_lot.nfl_player_id,
    v_lot.item_name, v_lot.current_bid_cents, false);

  update public.lots
     set status = 'resolved', winner_player_id = v_lot.high_bidder_player_id,
         final_price_cents = v_lot.current_bid_cents,
         on_the_clock_player_id = null, turn_expires_at = null, resolved_at = now()
   where id = p_lot;

  insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
  values (v_lot.room_id, p_lot, v_lot.high_bidder_player_id, p_action,
          v_lot.current_bid_cents, v_lot.turn_seq);

  perform public.df20_advance(v_lot.room_id);
end $$;

-- ── RESOLVE: the opener hands the card over for nothing ────────────────────
create or replace function public.df20_resolve_gift(p_lot uuid, p_giver uuid)
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_lot public.lots; v_to uuid;
begin
  select * into v_lot from public.lots where id = p_lot for update;
  if v_lot.status not in ('offered', 'bidding') then return; end if;

  v_to := public.df20_opponent(v_lot.room_id, p_giver);
  perform public.df20_add_to_roster(
    v_lot.room_id, v_to, v_lot.nfl_player_id, v_lot.item_name, 0, true);

  update public.players set gives_used = gives_used + 1 where id = p_giver;

  update public.lots
     set status = 'resolved', winner_player_id = v_to, final_price_cents = 0,
         gifted = true, on_the_clock_player_id = null, turn_expires_at = null,
         resolved_at = now()
   where id = p_lot;

  insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
  values (v_lot.room_id, p_lot, p_giver, 'offer_give', 0, v_lot.turn_seq);

  perform public.df20_advance(v_lot.room_id);
end $$;

-- ── RESOLVE: nobody can legally do anything with this card ─────────────────
create or replace function public.df20_discard_lot(p_lot uuid)
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_lot public.lots;
begin
  select * into v_lot from public.lots where id = p_lot for update;
  if v_lot.status not in ('offered', 'bidding') then return; end if;

  update public.lots
     set status = 'void', on_the_clock_player_id = null, turn_expires_at = null,
         resolved_at = now()
   where id = p_lot;

  insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
  values (v_lot.room_id, p_lot, null, 'discard', 0, v_lot.turn_seq);

  perform public.df20_advance(v_lot.room_id);
end $$;

revoke all on function public.df20_public_state(uuid)    from anon, authenticated;
revoke all on function public.df20_broadcast(uuid)       from anon, authenticated;
revoke all on function public.df20_touch(uuid)           from anon, authenticated;
revoke all on function public.df20_reveal_next(uuid)     from anon, authenticated;
revoke all on function public.df20_advance(uuid)         from anon, authenticated;
revoke all on function public.df20_resolve_lot(uuid, text)   from anon, authenticated;
revoke all on function public.df20_resolve_gift(uuid, uuid)  from anon, authenticated;
revoke all on function public.df20_discard_lot(uuid)         from anon, authenticated;
revoke all on function public.df20_add_to_roster(uuid, uuid, int, text, int, boolean)
  from anon, authenticated;
