-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0021 · a custom clock, and no clock at all
--
-- timer_seconds = 0 means NO LIMIT: the counter-bid window stays open until
-- somebody raises or passes. Everything else about the clock is unchanged.
--
-- The four functions below are reproduced from 0005 and 0010 BYTE FOR BYTE
-- except that every
--     now() + make_interval(secs => v_room.timer_seconds)
-- is now
--     public.df20_turn_deadline(v_room.timer_seconds)
-- which returns NULL at zero. No money rule, no validation and no state
-- transition is touched — the diff is one expression in four places, which is
-- the only reason it is safe to restate functions this important.
--
-- Everything downstream already treats a null deadline correctly, which is
-- why this works at all:
--   · place_bid's  "now() > v_lot.turn_expires_at + 400ms"  is NULL, and
--     plpgsql treats a NULL condition as false, so a bid is never late.
--   · expire_turn returns early on a null deadline, so the idempotent
--     expiry call is a no-op.
--   · df20_sweep_expired's "turn_expires_at < now() - 2s" never matches a
--     null, so the pg_cron backstop skips these rooms.
--   · the client's expiry driver bails on a null expires_at, so nothing is
--     scheduled in the browser either.
-- ═══════════════════════════════════════════════════════════════════════════

-- the whole feature, in one function
create or replace function public.df20_turn_deadline(p_seconds int)
returns timestamptz language sql stable as $$
  select case when coalesce(p_seconds, 0) <= 0
              then null
              else now() + make_interval(secs => p_seconds) end
$$;
revoke all on function public.df20_turn_deadline(int) from anon, authenticated;

-- ── the clock bound is now "0, or 3 to 300" ───────────────────────────────
do $$ begin
  alter table public.rooms drop constraint rooms_timer_seconds_check;
exception when undefined_object then null; end $$;
alter table public.rooms
  add constraint rooms_timer_seconds_check
  check (timer_seconds = 0 or (timer_seconds between 3 and 300));

-- ── df20_reveal_next ────────────────────────────────────────────────
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

  if v_o1 = 0 and v_o2 = 0 then
    update public.rooms
       set phase = 'complete', status = 'complete',
           completed_at = coalesce(completed_at, now())
     where id = p_room;
    return;
  end if;

  if v_o1 > 0 and v_o2 > 0 then
    v_opener := case when v_room.opener_seat = 1 then v_p1 else v_p2 end;
  elsif v_o1 > 0 then v_opener := v_p1;
  else                v_opener := v_p2;
  end if;

  select d.position as pos, d.item_name as nm into v_card
    from public.room_deck d
   where d.room_id = p_room and d.revealed_at is null
   order by d.position limit 1;

  if not found then
    update public.rooms
       set phase = 'complete', status = 'complete',
           completed_at = coalesce(completed_at, now())
     where id = p_room;
    return;
  end if;

  update public.room_deck set revealed_at = now()
   where room_id = p_room and position = v_card.pos;

  insert into public.lots
    (room_id, item_name, opener_player_id, status,
     current_bid_cents, high_bidder_player_id, on_the_clock_player_id,
     turn_expires_at, turn_seq)
  values
    (p_room, v_card.nm, v_opener.id, 'offered',
     v_room.min_bid_cents, v_opener.id, v_opener.id,
     public.df20_turn_deadline(v_room.timer_seconds), 1)
  returning id into v_lot;

  insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
  values (p_room, v_lot, null, 'reveal', v_room.min_bid_cents, 1);

  update public.rooms set phase = 'offering' where id = p_room;
end $$;

-- ── offer_decide ────────────────────────────────────────────────
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

-- ── place_bid ────────────────────────────────────────────────
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
         turn_expires_at = public.df20_turn_deadline(v_room.timer_seconds),
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

-- ── expire_turn ────────────────────────────────────────────────
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
               turn_expires_at = public.df20_turn_deadline(v_room.timer_seconds),
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


-- ── the two places a timer is validated ───────────────────────────────────
-- Both restated from 0017 / 0010 with one guard widened and nothing else
-- changed.

create or replace function public.create_room(
  p_title text, p_roster_size int, p_bankroll_cents int, p_min_bid_cents int,
  p_timer_seconds int, p_host_name text, p_is_private boolean default true,
  p_gives_per_player int default 2, p_brand_accent text default null,
  p_brand_logo_url text default null,
  p_pool_source text default 'builtin', p_pool_ref uuid default null
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_pl public.players; v_uid uuid; v_accent text; v_n int;
begin
  if coalesce(p_pool_source, 'builtin') in ('wikipedia','saved') then
    v_uid := public.df20_require_verified();
  else
    v_uid := public.df20_ensure_profile();   -- null when signed out, which is fine
  end if;

  if coalesce(p_pool_source, 'builtin') = 'saved' then
    if not exists (select 1 from public.user_categories
                    where id = p_pool_ref and owner_id = v_uid) then
      raise exception 'DF20_NOT_YOUR_DECK';
    end if;
  end if;

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
  -- 0 is the no-limit sentinel; 1 and 2 seconds are still nonsense
  if p_timer_seconds is null
     or not (p_timer_seconds = 0 or p_timer_seconds between 3 and 300)
    then raise exception 'DF20_BAD_TIMER'; end if;
  if p_gives_per_player is null or p_gives_per_player < 0 or p_gives_per_player > 30
    then raise exception 'DF20_BAD_GIVES'; end if;

  v_accent := public.df20_clean_text(p_brand_accent, 9);
  if v_accent = '' then v_accent := null; end if;
  if v_accent is not null and v_accent !~ '^#[0-9A-Fa-f]{6}$'
    then raise exception 'DF20_BAD_ACCENT'; end if;

  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, gives_per_player,
                            is_private, brand_accent, brand_logo_url, host_profile_id)
  values (public.df20_gen_code(), p_title, p_roster_size, p_bankroll_cents,
          p_min_bid_cents, p_timer_seconds, p_gives_per_player,
          coalesce(p_is_private, true), v_accent,
          public.df20_clean_logo_url(p_brand_logo_url), v_uid)
  returning * into v_room;

  v_n := public.df20_fill_pool(v_room.id, coalesce(p_pool_source, 'builtin'), p_pool_ref);
  if v_n < p_roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;

  insert into public.players (room_id, seat, display_name, bankroll_cents, is_host, profile_id)
  values (v_room.id, 1, p_host_name, p_bankroll_cents, true, v_uid)
  returning * into v_pl;

  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code,
                            'player_id', v_pl.id, 'session_token', v_pl.session_token,
                            'seat', 1, 'pool_size', v_n);
end $$;
grant execute on function public.create_room(text,int,int,int,int,text,boolean,int,text,text,text,uuid) to anon, authenticated;

create or replace function public.setup_lock_items(
  p_setup_token uuid, p_category text, p_items text[],
  p_roster_size int, p_bankroll_cents int, p_min_bid_cents int,
  p_timer_seconds int, p_gives_per_player int default 2
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; s text; v_clean text; v_n int; v_result uuid; v_code text;
begin
  select * into v_room from public.rooms where setup_token = p_setup_token for update;
  if not found then raise exception 'DF20_SETUP_LINK_SPENT'; end if;
  if v_room.setup_expires_at < now() then raise exception 'DF20_SETUP_LINK_EXPIRED'; end if;

  p_category := public.df20_clean_text(p_category, 60);
  if length(p_category) = 0 then raise exception 'DF20_BAD_CATEGORY'; end if;

  if p_roster_size is null or p_roster_size < 1 or p_roster_size > 30
    then raise exception 'DF20_BAD_ROSTER_SIZE'; end if;
  if p_bankroll_cents is null or p_bankroll_cents < 0 or p_bankroll_cents > 10000000
    then raise exception 'DF20_BAD_BANKROLL'; end if;
  if p_min_bid_cents is null or p_min_bid_cents < 0 or p_min_bid_cents > 1000000
    then raise exception 'DF20_BAD_MIN_BID'; end if;
  -- 0 is the no-limit sentinel; 1 and 2 seconds are still nonsense
  if p_timer_seconds is null
     or not (p_timer_seconds = 0 or p_timer_seconds between 3 and 300)
    then raise exception 'DF20_BAD_TIMER'; end if;

  -- sanitise, length-check and de-duplicate case-insensitively
  foreach s in array coalesce(p_items, '{}'::text[]) loop
    v_clean := public.df20_clean_text(s, 60);
    if length(v_clean) >= 1 then
      if exists (select 1 from public.room_pool
                  where room_id = v_room.id and lower(name) = lower(v_clean)) then
        raise exception 'DF20_DUPLICATE_ITEM';
      end if;
      insert into public.room_pool (room_id, name) values (v_room.id, v_clean);
    end if;
  end loop;

  select count(*) into v_n from public.room_pool where room_id = v_room.id;
  if v_n < p_roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;
  if v_n > 500 then raise exception 'DF20_POOL_TOO_BIG'; end if;

  v_code   := public.df20_gen_code();
  v_result := gen_random_uuid();

  update public.rooms
     set code = v_code, title = p_category, category_name = p_category,
         roster_size = p_roster_size, starting_bankroll_cents = p_bankroll_cents,
         min_bid_cents = p_min_bid_cents, timer_seconds = p_timer_seconds,
         gives_per_player = coalesce(p_gives_per_player, 2),
         pool_source = 'manual',
         setup_locked_at = now(),
         setup_token = null,             -- the link is GONE, not read-only
         setup_result_token = v_result
   where id = v_room.id;

  return jsonb_build_object('code', v_code, 'item_count', v_n,
                            'setup_result_token', v_result);
end $$;
grant execute on function public.setup_lock_items(uuid,text,text[],int,int,int,int,int) to anon, authenticated;
