-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0041 · players may bid themselves broke
--
-- The Reserve Rule — always keep the minimum bid for every other slot you
-- still owe — was a safety net the trend does not actually use. On TikTok
-- people spend to zero on somebody they want and live with what Force-or-Take
-- gives them afterwards. That moment IS the format, and the rule forbade it.
--
-- THE HARD CAP IS UNTOUCHED. Nobody may ever bid more than they hold, under
-- either setting. Force-or-Take is untouched. The only thing that moves is
-- whether the reserve is subtracted before the cap is applied.
--
-- ONE CONDITIONAL, IN ONE FUNCTION. df20_max_legal_bid has nine callers, so
-- branching at the call sites would be nine chances to drift. The branch goes
-- inside, and every caller passes the room's flag.
--
-- The fourth parameter is deliberately NOT defaulted. A defaulted one leaves
-- the old three-argument version resolvable and every call ambiguous — the
-- exact trap df20_seed_category and df20_cache_wikipedia already fell into.
-- Distinct arities with no default cannot be ambiguous.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.rooms
  add column if not exists allow_broke boolean not null default true;

comment on column public.rooms.allow_broke is
  'true (default): a bid may spend the whole bankroll, and Force-or-Take '
  'covers the slots that can no longer be afforded. false: the original '
  'Reserve Rule, which keeps back the minimum for every other open slot.';

-- ── the money rule ────────────────────────────────────────────────────────
create or replace function public.df20_max_legal_bid(
  p_bankroll int, p_min_bid int, p_open int, p_allow_broke boolean
) returns int language plpgsql immutable as $$
declare v int;
begin
  if p_open <= 0 then return 0; end if;

  if coalesce(p_allow_broke, true) then
    -- Bid to zero if you like. What happens next is Force-or-Take's problem,
    -- which is exactly how the trend plays.
    v := p_bankroll;
  else
    -- THE RESERVE RULE, byte for byte as it was in 0004.
    v := p_bankroll - (p_min_bid * (p_open - 1));
    -- Underfunded room: the reserve cannot be met at all. Degrade to exactly
    -- one minimum bid rather than locking the player out of every action.
    if v < p_min_bid then
      if p_bankroll >= p_min_bid then v := p_min_bid; else v := 0; end if;
    end if;
  end if;

  return greatest(least(v, p_bankroll), 0);   -- HARD CAP, both branches
end $$;

-- ── the callers, each passing the room's own flag ─────────────────────────
-- Restated from 0004 and 0021 with ONE line changed each: the fourth
-- argument. No money rule, no state transition and no validation order is
-- touched — which is the only reason it is safe to restate functions this
-- important.
--
-- df20_public_state is included: it reports max_legal_bid_cents to both
-- clients so the Rail can draw the reserved zone, and a Rail still drawing a
-- reserve the server no longer enforces would be a lie on screen.

create or replace function public.df20_can_outbid(p_room uuid, p_player uuid, p_amount int)
returns boolean language plpgsql stable as $$
declare v_min int; v_bank int; v_open int; v_broke boolean;
begin
  select min_bid_cents, allow_broke into v_min, v_broke from public.rooms where id = p_room;
  select bankroll_cents into v_bank from public.players where id = p_player;
  if v_bank is null then return false; end if;
  v_open := public.df20_open_slots(p_room, p_player);
  if v_open <= 0 then return false; end if;              -- roster full, no stake
  return public.df20_max_legal_bid(v_bank, v_min, v_open, v_broke) > p_amount;
end $$;

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
                                     public.df20_open_slots(v_room.id, v_me.id),
                                     v_room.allow_broke);
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
                                     public.df20_open_slots(v_room.id, v_me.id),
                                     v_room.allow_broke);
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
                                       public.df20_open_slots(v_room.id, v_opener.id),
                                       v_room.allow_broke);
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

grant execute on function public.place_bid(text, uuid, int, int)    to anon, authenticated;
grant execute on function public.offer_decide(text, uuid, text)     to anon, authenticated;
grant execute on function public.expire_turn(text)                  to anon, authenticated;

create or replace function public.df20_public_state(p_room uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp set timezone = 'UTC' as $$
declare v_room public.rooms;
begin
  select * into v_room from public.rooms where id = p_room;
  if not found then return null; end if;

  return jsonb_build_object(
    'server_now', to_jsonb(now()),
    'room', to_jsonb(v_room) - 'setup_token' - 'setup_result_token' - 'obs_token',
    'deck_remaining', public.df20_deck_remaining(p_room),
    'players', coalesce((
        select jsonb_agg(
                 (to_jsonb(pl) - 'session_token')
                 || jsonb_build_object(
                      'open_slots', public.df20_open_slots(p_room, pl.id),
                      'max_legal_bid_cents', public.df20_max_legal_bid(
                          pl.bankroll_cents, v_room.min_bid_cents,
                          public.df20_open_slots(p_room, pl.id),
                          v_room.allow_broke),
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
revoke all on function public.df20_public_state(uuid) from anon, authenticated;

-- ── create_room learns the setting ────────────────────────────────────────
-- Every earlier signature goes first. A new defaulted argument leaves the old
-- overload resolvable and makes positional calls ambiguous — the trap 0010
-- documents and 0023 already had to work around for this same function.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'create_room'
  loop
    execute 'drop function if exists ' || r.sig || ' cascade';
  end loop;
end $$;

create or replace function public.create_room(
  p_title text, p_roster_size int, p_bankroll_cents int, p_min_bid_cents int,
  p_timer_seconds int, p_host_name text, p_is_private boolean default true,
  p_gives_per_player int default 2, p_brand_accent text default null,
  p_brand_logo_url text default null,
  p_pool_source text default 'builtin', p_pool_ref uuid default null,
  p_content_mode text default 'standard',
  p_allow_broke boolean default true
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

  -- FREE IS THE SHELF. builtin and library stay open to everyone, signed in
  -- or not; anything the host supplies themselves is premium.
  if coalesce(p_pool_source, 'builtin') not in ('builtin', 'library')
     and (v_uid is null or not public.df20_premium_active(v_uid)) then
    raise exception 'DF20_PREMIUM_REQUIRED';
  end if;

  -- CONTENT CREATOR is chosen here, at creation, and never changes. The
  -- room's whole layout is decided by this column, so letting it be flipped
  -- mid-draft would mean re-laying-out a board somebody is streaming.
  p_content_mode := coalesce(nullif(btrim(lower(p_content_mode)), ''), 'standard');
  if p_content_mode not in ('standard', 'creator') then
    raise exception 'DF20_BAD_CONTENT_MODE';
  end if;
  if p_content_mode = 'creator'
     and (v_uid is null or not public.df20_premium_active(v_uid)) then
    raise exception 'DF20_PREMIUM_REQUIRED';
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
                            is_private, brand_accent, brand_logo_url, host_profile_id,
                            content_mode, allow_broke)
  values (public.df20_gen_code(), p_title, p_roster_size, p_bankroll_cents,
          p_min_bid_cents, p_timer_seconds, p_gives_per_player,
          coalesce(p_is_private, true), v_accent,
          public.df20_clean_logo_url(p_brand_logo_url), v_uid,
          p_content_mode, coalesce(p_allow_broke, true))
  returning * into v_room;

  v_n := public.df20_fill_pool(v_room.id, coalesce(p_pool_source, 'builtin'), p_pool_ref);
  if v_n < p_roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;

  insert into public.players (room_id, seat, display_name, bankroll_cents, is_host, profile_id)
  values (v_room.id, 1, p_host_name, p_bankroll_cents, true, v_uid)
  returning * into v_pl;

  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code,
                            'player_id', v_pl.id, 'session_token', v_pl.session_token,
                            'seat', 1, 'pool_size', v_n,
                            'content_mode', v_room.content_mode);
end $$;
grant execute on function public.create_room(text,int,int,int,int,text,boolean,int,text,text,text,uuid,text,boolean) to anon, authenticated;


-- PostgREST matches RPC calls against a cached copy of the schema. Without
-- this it can keep reporting the old signature for a minute or so after the
-- functions themselves have changed.
notify pgrst, 'reload schema';
