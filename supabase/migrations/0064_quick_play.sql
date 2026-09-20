-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0064 · Quick Play: one human, one bot
--
-- THE BOT IS A PLAYER ROW, NOT A NEW CODE PATH. It gets a seat, a bankroll,
-- gives, and a session token like anybody else, and it acts by calling
-- offer_decide / place_bid / pass_turn — the same functions the human uses,
-- with the same FOR UPDATE, the same turn_seq check and the same money
-- validation. Nothing about the money rules is re-implemented for it, which
-- is the only reason adding an opponent to this game is safe at all.
--
-- WHO DECIDES is a separate question from WHO ACTS. bot_act() takes a choice
-- and executes it; what the choice should be is decided upstream — by an LLM
-- when one answers, and by df20_bot_heuristic() when it does not. The
-- heuristic is not a stub: a free-tier LLM WILL be rate limited (1,000
-- requests a day against ~665 rooms a day and climbing), and when it is, a
-- draft with a running countdown cannot simply stop. So the fallback is the
-- thing that makes the LLM optional rather than load-bearing.
--
-- Re-runnable.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.players
  add column if not exists is_bot boolean not null default false;
alter table public.rooms
  add column if not exists is_solo boolean not null default false;

comment on column public.players.is_bot is
  'true for the Quick Play opponent. Acts through the ordinary RPCs.';
comment on column public.rooms.is_solo is
  'true when seat 2 is a bot. Set at creation and never changed, like content_mode.';

-- ── how much does the bot want this card? ─────────────────────────────────
-- There is no value_score on category_library_items yet, so taste comes from
-- a hash of the name: stable for a given item (the bot does not change its
-- mind about Josh Allen halfway through a draft), different across items, and
-- different across rooms so two drafts are not identical. 0..100.
--
-- This is deliberately NOT a ranking of real-world quality. It gives the bot
-- consistent opinions to bid from, which is all the economics need. When a
-- real value_score column arrives this function is the single place to change.
create or replace function public.df20_bot_appetite(p_room uuid, p_item text)
returns int language sql immutable as $$
  select (abs(hashtext(coalesce(p_item,'') || '|' || p_room::text)) % 101)
$$;

-- ── the fallback decision ─────────────────────────────────────────────────
-- Pure economics against the same numbers the board shows. Returns the same
-- shape the LLM is asked for, so the two are interchangeable at the call site.
-- SECURITY DEFINER because rooms/players/lots are deny-all; without it this
-- works when called from inside df20_bot_turn and dies when called directly.
-- Reads players.gives_USED — gives_left is computed in df20_public_state and
-- is not a column, which plpgsql does not catch until the bot's first turn.
create or replace function public.df20_bot_heuristic(p_code text)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_room public.rooms; v_lot public.lots; v_bot public.players;
  v_opp public.players; v_appetite int; v_max int; v_ceiling int; v_next int;
  v_gives_left int; v_open int; v_opp_open int;
  v_can_take boolean; v_can_give boolean;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code));
  if not found then return jsonb_build_object('action','none','why','no room'); end if;
  select * into v_bot from public.players where room_id = v_room.id and is_bot;
  if not found then return jsonb_build_object('action','none','why','no bot'); end if;
  select * into v_opp from public.players where room_id = v_room.id and not is_bot;

  select * into v_lot from public.lots
   where room_id = v_room.id and status in ('offered','bidding')
   order by created_at desc limit 1;
  if not found then return jsonb_build_object('action','none','why','no live lot'); end if;
  if v_lot.on_the_clock_player_id is distinct from v_bot.id then
    return jsonb_build_object('action','none','why','not the bot turn');
  end if;

  v_open       := public.df20_open_slots(v_room.id, v_bot.id);
  v_opp_open   := public.df20_open_slots(v_room.id, v_opp.id);
  v_gives_left := greatest(v_room.gives_per_player - v_bot.gives_used, 0);
  v_appetite   := public.df20_bot_appetite(v_room.id, v_lot.item_name);
  v_max        := public.df20_max_legal_bid(v_bot.bankroll_cents, v_room.min_bid_cents,
                                            v_open, v_room.allow_broke);
  v_can_take   := v_max >= v_room.min_bid_cents and v_open > 0;
  v_can_give   := v_opp_open > 0 and v_gives_left > 0;

  if v_lot.status = 'offered' then
    -- The bot goes broke too. Mirrors offer_decide's branch order exactly:
    -- force when Take is unaffordable, or the solo draft stalls in the way
    -- Force-or-Take exists to prevent.
    if not v_can_take and v_open > 0 then
      return jsonb_build_object('action','force','why',
        format('broke with %s slot(s) owed, taking it free', v_open));
    end if;
    if v_appetite < 30 and v_can_give then
      return jsonb_build_object('action','give','why',
        format('appetite %s, giving it away', v_appetite));
    end if;
    if v_can_take then
      return jsonb_build_object('action','take','why',
        format('appetite %s, taking at the minimum', v_appetite));
    end if;
    return jsonb_build_object('action','discard','why','nothing legal but letting it go');
  end if;

  v_ceiling := (v_max * v_appetite) / 100;
  v_next := v_lot.current_bid_cents + v_room.min_bid_cents;
  if v_next <= least(v_ceiling, v_max) then
    return jsonb_build_object('action','bid','amount_cents', v_next, 'why',
      format('appetite %s, ceiling %s, raising to %s', v_appetite, v_ceiling, v_next));
  end if;
  return jsonb_build_object('action','pass','why',
    format('appetite %s puts the ceiling at %s, %s is too rich',
           v_appetite, v_ceiling, v_next));
end $$;
grant execute on function public.df20_bot_heuristic(text) to anon, authenticated;

-- ── what the decider gets to see ──────────────────────────────────────────
-- Everything a human opponent could see at this moment and nothing more. In
-- particular NOT the deck: the whole leak rule exists so that no player,
-- human or otherwise, knows what is coming. A bot that could read room_deck
-- would be cheating, and worse, it would be cheating invisibly.
create or replace function public.df20_bot_turn(p_code text)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_room public.rooms; v_lot public.lots; v_bot public.players; v_opp public.players;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code));
  if not found then return jsonb_build_object('turn', false, 'why', 'no room'); end if;
  if not v_room.is_solo then return jsonb_build_object('turn', false, 'why', 'not solo'); end if;
  if v_room.status <> 'live' then
    return jsonb_build_object('turn', false, 'why', 'room is ' || v_room.status);
  end if;

  select * into v_bot from public.players where room_id = v_room.id and is_bot;
  select * into v_opp from public.players where room_id = v_room.id and not is_bot;
  if v_bot.id is null then return jsonb_build_object('turn', false, 'why', 'no bot'); end if;

  select * into v_lot from public.lots
   where room_id = v_room.id and status in ('offered','bidding')
   order by created_at desc limit 1;
  if not found then return jsonb_build_object('turn', false, 'why', 'no live lot'); end if;
  if v_lot.on_the_clock_player_id is distinct from v_bot.id then
    return jsonb_build_object('turn', false, 'why', 'human is on the clock');
  end if;

  return jsonb_build_object(
    'turn', true,
    'turn_seq', v_lot.turn_seq,
    'phase', v_lot.status,                       -- 'offered' | 'bidding'
    'category', v_room.category_name,
    'item', v_lot.item_name,
    'current_bid_cents', v_lot.current_bid_cents,
    'min_bid_cents', v_room.min_bid_cents,
    'allow_broke', v_room.allow_broke,
    'me', jsonb_build_object(
      'name', v_bot.display_name,
      'bankroll_cents', v_bot.bankroll_cents,
      'open_slots', public.df20_open_slots(v_room.id, v_bot.id),
      'gives_left', greatest(v_room.gives_per_player - v_bot.gives_used, 0),
      'max_legal_bid_cents', public.df20_max_legal_bid(
          v_bot.bankroll_cents, v_room.min_bid_cents,
          public.df20_open_slots(v_room.id, v_bot.id), v_room.allow_broke),
      'roster', coalesce((select jsonb_agg(jsonb_build_object(
                            'item', e.item_name, 'price_cents', e.price_cents)
                            order by e.pick_number)
                     from public.roster_entries e where e.player_id = v_bot.id), '[]'::jsonb)),
    'opponent', jsonb_build_object(
      'name', v_opp.display_name,
      'bankroll_cents', v_opp.bankroll_cents,
      'open_slots', public.df20_open_slots(v_room.id, v_opp.id),
      'gives_left', greatest(v_room.gives_per_player - v_opp.gives_used, 0),
      'roster', coalesce((select jsonb_agg(jsonb_build_object(
                            'item', e.item_name, 'price_cents', e.price_cents)
                            order by e.pick_number)
                     from public.roster_entries e where e.player_id = v_opp.id), '[]'::jsonb)),
    'fallback', public.df20_bot_heuristic(p_code)
  );
end $$;
grant execute on function public.df20_bot_turn(text) to anon, authenticated;

-- ── the bot acts ──────────────────────────────────────────────────────────
-- Holds the bot's session token so nothing outside the database ever does,
-- then calls the SAME rpc a human calls. Every check runs again: the row
-- lock, the turn check, the turn_seq check, the hard cap, the reserve, the
-- gives cap, Force-or-Take. An illegal choice from the LLM is rejected here
-- exactly as it would be from a person with a modified client.
--
-- REACHABLE WITH CURL, and that is fine. The worst a stranger can do is make
-- the bot act on a turn that is already the bot's, in a room with one human
-- in it — which is to say, play someone's solo game badly for them. Nothing
-- it can do is illegal, and there is no second player to defraud.
create or replace function public.bot_act(
  p_code text, p_choice text, p_amount_cents int default null
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_room public.rooms; v_bot public.players; v_lot public.lots; v_seq int;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code));
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  if not v_room.is_solo then raise exception 'DF20_NOT_SOLO'; end if;

  select * into v_bot from public.players where room_id = v_room.id and is_bot;
  if not found then raise exception 'DF20_NO_BOT'; end if;

  select * into v_lot from public.lots
   where room_id = v_room.id and status in ('offered','bidding')
   order by created_at desc limit 1;
  if not found then raise exception 'DF20_NO_LIVE_LOT'; end if;
  if v_lot.on_the_clock_player_id is distinct from v_bot.id then
    raise exception 'DF20_NOT_YOUR_TURN';
  end if;
  v_seq := v_lot.turn_seq;

  if p_choice in ('take','give','force','discard') then
    return public.offer_decide(p_code, v_bot.session_token, p_choice);
  elsif p_choice = 'bid' then
    return public.place_bid(p_code, v_bot.session_token,
                            coalesce(p_amount_cents, 0), v_seq);
  elsif p_choice = 'pass' then
    return public.pass_turn(p_code, v_bot.session_token, v_seq);
  end if;
  raise exception 'DF20_BAD_CHOICE';
end $$;
revoke all on function public.bot_act(text, text, int) from public;
grant execute on function public.bot_act(text, text, int) to anon, authenticated;

-- ── one call: make the room, seat the bot, start ──────────────────────────
-- Quick Play exists because 28% of rooms never finish and the commonest
-- reason is that nobody else turned up. A flow that still asked the player
-- to create a room, then wait, then press start would not fix that. So this
-- returns a room that is already live with a card face up.
--
-- It COMPOSES create_room rather than duplicating it — that function now
-- takes fourteen arguments and carries the pool selection, the content mode
-- and the premium check, none of which should exist twice.
create or replace function public.create_solo_room(
  p_host_name     text,
  p_pool_source   text default 'builtin',
  p_pool_ref      uuid default null,
  p_roster_size   int  default 5,
  p_timer_seconds int  default 20
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_made jsonb; v_room public.rooms; v_bot_id uuid; v_name text;
begin
  -- a solo room always has a clock. With timer_seconds 0 the countdown is
  -- null, and expire_turn — the thing that rescues a draft when the browser
  -- driving the bot goes away — has no deadline to fire on. A no-limit solo
  -- room would simply hang forever.
  if coalesce(p_timer_seconds, 0) < 5 then p_timer_seconds := 20; end if;

  v_made := public.create_room(
    'Quick Play', p_roster_size, 2000, 100, p_timer_seconds,
    public.df20_clean_text(p_host_name, 24), true, 2,
    null, null, p_pool_source, p_pool_ref, 'standard', true);

  select * into v_room from public.rooms where id = (v_made->>'room_id')::uuid;
  update public.rooms set is_solo = true where id = v_room.id;

  -- The opponent's name is printed on the board, the bid history, the vote
  -- screen and the results card. It ends in 'Bot' deliberately: on a card
  -- somebody posts, the person looking at it should be able to tell that the
  -- loser was software. 'The House' read as a casino, and worse, as a person.
  v_name := 'DraftFor20Bot';
  insert into public.players (room_id, seat, display_name, bankroll_cents,
                              is_host, is_bot, gives_used)
  values (v_room.id, 2, v_name, v_room.starting_bankroll_cents, false, true, 0)
  returning id into v_bot_id;

  -- start it immediately: there is nobody to wait for
  perform public.start_draft(v_room.code, (v_made->>'session_token')::uuid);

  return v_made
       || jsonb_build_object('is_solo', true,
                             'bot_player_id', v_bot_id,
                             'bot_name', v_name);
end $$;
grant execute on function public.create_solo_room(text, text, uuid, int, int)
  to anon, authenticated;

-- ── assertions ────────────────────────────────────────────────────────────
do $$
declare v_bad text[] := '{}';
begin
  if to_regprocedure('public.create_solo_room(text,text,uuid,int,int)') is null
    then v_bad := v_bad || 'create_solo_room missing'; end if;
  if to_regprocedure('public.bot_act(text,text,int)') is null
    then v_bad := v_bad || 'bot_act missing'; end if;
  if to_regprocedure('public.df20_bot_turn(text)') is null
    then v_bad := v_bad || 'df20_bot_turn missing'; end if;
  if to_regprocedure('public.df20_bot_heuristic(text)') is null
    then v_bad := v_bad || 'df20_bot_heuristic missing'; end if;

  -- the bot must never be able to read the deck; df20_bot_turn is the only
  -- thing it sees, and room_deck must not appear anywhere in it
  if pg_get_functiondef(to_regprocedure('public.df20_bot_turn(text)')) ~* 'room_deck'
    then v_bad := v_bad || 'df20_bot_turn touches room_deck — the bot can see the future'; end if;

  if coalesce(array_length(v_bad,1),0) > 0 then
    raise exception E'DF20_QUICKPLAY_CHECK_FAILED\n  %', array_to_string(v_bad, E'\n  ');
  end if;
  raise notice 'quick play ok - bot acts through the ordinary rpcs, deck sealed';
end $$;
