-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0010 · category resolution, setup links, library opt-in
--
-- INVARIANT THIS FILE EXISTS TO PROTECT:
--   no function here ever returns an item name to a caller.
--   Items go in (once, at lock-in or from a server-side source) and come out
--   only through df20_reveal_next, one card at a time, after being dealt.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── deck reads the name directly now; no pool join ────────────────────────
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
     now() + make_interval(secs => v_room.timer_seconds), 1)
  returning id into v_lot;

  insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
  values (p_room, v_lot, null, 'reveal', v_room.min_bid_cents, 1);

  update public.rooms set phase = 'offering' where id = p_room;
end $$;

-- ── fill a room's locked pool from whichever source produced it ───────────
create or replace function public.df20_fill_pool(
  p_room uuid, p_source text, p_ref uuid
) returns int language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_n int; v_name text;
begin
  if p_source in ('builtin','library') then
    if p_ref is null then
      select id into p_ref from public.category_library
       where name_norm = public.df20_norm_category('Football Draft');
    end if;
    select name into v_name from public.category_library where id = p_ref;
    if v_name is null then raise exception 'DF20_NO_SUCH_CATEGORY'; end if;
    insert into public.room_pool (room_id, name)
      select p_room, i.name from public.category_library_items i where i.library_id = p_ref
      on conflict do nothing;
  elsif p_source = 'wikipedia' then
    select article_title into v_name from public.wikipedia_cache where id = p_ref;
    if v_name is null then raise exception 'DF20_NO_SUCH_CATEGORY'; end if;
    insert into public.room_pool (room_id, name)
      select p_room, i.name from public.wikipedia_cache_items i where i.cache_id = p_ref
      on conflict do nothing;
  else
    raise exception 'DF20_BAD_POOL_SOURCE';
  end if;

  select count(*) into v_n from public.room_pool where room_id = p_room;
  update public.rooms
     set pool_source = p_source,
         category_name = coalesce(category_name, v_name)
   where id = p_room;
  return v_n;
end $$;

-- ── fuzzy match: public library first, then the Wikipedia cache ───────────
-- Returns provenance and a COUNT. Never an item.
-- 0.5 rather than pg_trgm's default 0.3: on two-to-four-word category names
-- 0.3 matches phrases that merely share a common word, and a wrong pool ruins
-- the draft rather than looking slightly off.
create or replace function public.df20_match_category(
  p_query text, p_min_items int default 0
) returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_q text; v_id uuid; v_name text; v_n int; v_score real;
begin
  v_q := public.df20_norm_category(p_query);
  if length(v_q) = 0 then return null; end if;

  -- 1. public library, exact then fuzzy
  select l.id, l.name, similarity(l.name_norm, v_q) into v_id, v_name, v_score
    from public.category_library l
   where l.name_norm = v_q or similarity(l.name_norm, v_q) >= 0.5
   order by (l.name_norm = v_q) desc, similarity(l.name_norm, v_q) desc
   limit 1;

  if v_id is not null then
    select count(*) into v_n from public.category_library_items where library_id = v_id;
    if v_n >= p_min_items then
      return jsonb_build_object('source','library','source_id',v_id,
                                'name',v_name,'item_count',v_n,
                                'score',round(coalesce(v_score,1)::numeric,3));
    end if;
  end if;

  -- 2. internal Wikipedia cache
  select c.id, c.article_title, similarity(c.query_norm, v_q) into v_id, v_name, v_score
    from public.wikipedia_cache c
   where c.query_norm = v_q or similarity(c.query_norm, v_q) >= 0.5
   order by (c.query_norm = v_q) desc, similarity(c.query_norm, v_q) desc
   limit 1;

  if v_id is not null then
    select count(*) into v_n from public.wikipedia_cache_items where cache_id = v_id;
    if v_n >= p_min_items then
      return jsonb_build_object('source','wikipedia','source_id',v_id,
                                'name',v_name,'item_count',v_n,
                                'score',round(coalesce(v_score,1)::numeric,3));
    end if;
  end if;

  return null;
end $$;

-- ── server-only configuration. RLS-denied, read only from inside
--    SECURITY DEFINER functions. ────────────────────────────────────────────
create table if not exists public.df20_config (
  key text primary key, value text not null
);
alter table public.df20_config enable row level security;
revoke all on public.df20_config from anon, authenticated;

-- Generated, never written down. This used to be a literal, which meant the
-- secret guarding the shared category cache was sitting in source control
-- for anyone who could read the repo. It is created once, on first apply,
-- and read out of the table when you need it:
--   select value from public.df20_config where key = 'wiki_write_secret';
insert into public.df20_config (key, value)
values ('wiki_write_secret', encode(gen_random_bytes(24), 'hex'))
on conflict (key) do nothing;

-- ── store a fresh Wikipedia parse.
--
-- Gated by a shared secret rather than left open, because this writes to a
-- cache every future room can draw from: an open endpoint here lets anyone
-- poison other people's drafts. Deliberately NOT the Supabase service-role
-- key — this secret can only write parsed categories, so leaking it costs a
-- cache flush rather than the whole database.
create or replace function public.df20_cache_wikipedia(
  p_secret text, p_query text, p_title text, p_items text[]
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_q text; v_id uuid; v_n int; s text; v_clean text; v_expected text;
begin
  select value into v_expected from public.df20_config where key = 'wiki_write_secret';
  if v_expected is null or p_secret is null or p_secret <> v_expected then
    raise exception 'DF20_NOT_AUTHORISED';
  end if;

  v_q := public.df20_norm_category(p_query);
  if length(v_q) = 0 then raise exception 'DF20_BAD_CATEGORY'; end if;

  insert into public.wikipedia_cache (query_norm, article_title)
  values (v_q, public.df20_clean_text(p_title, 120))
  on conflict (query_norm) do update set article_title = excluded.article_title,
                                         fetched_at = now()
  returning id into v_id;

  delete from public.wikipedia_cache_items where cache_id = v_id;
  foreach s in array coalesce(p_items, '{}'::text[]) loop
    v_clean := public.df20_clean_text(s, 60);
    if length(v_clean) >= 2 then
      insert into public.wikipedia_cache_items (cache_id, name)
      values (v_id, v_clean) on conflict do nothing;
    end if;
  end loop;

  select count(*) into v_n from public.wikipedia_cache_items where cache_id = v_id;
  return jsonb_build_object('source','wikipedia','source_id',v_id,
                            'name',p_title,'item_count',v_n);
end $$;

-- ── real-name heuristics, used only to DISQUALIFY a manual list from the
--    public library. Tuned to over-block: wrongly publishing someone's
--    friend group is far worse than wrongly withholding cereal brands. ─────
create or replace function public.df20_looks_like_person(p text)
returns boolean language sql immutable as $$
  select coalesce(p ~ '^[A-Z][a-z''\.\-]+( [A-Z][a-z''\.\-]+){1,2}$', false)
$$;

create or replace function public.df20_person_oriented_category(p text)
returns boolean language sql immutable as $$
  select coalesce(lower(coalesce(p,'')) ~
    '(friend|coworker|co-worker|colleague|classmate|family|cousin|roommate|
      teammate|group chat|tier list|people i|my |our )', false)
$$;

-- ── CREATE ROOM, now source-aware ─────────────────────────────────────────
-- Drop every earlier signature first. The new one adds two defaulted
-- arguments, so leaving an old overload in place makes any positional call
-- ambiguous rather than resolving to the newest definition.
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
  p_pool_source text default 'builtin', p_pool_ref uuid default null
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_pl public.players; v_uid uuid; v_accent text; v_n int;
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

  v_n := public.df20_fill_pool(v_room.id, coalesce(p_pool_source,'builtin'), p_pool_ref);
  if v_n < p_roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;

  insert into public.players (room_id, seat, display_name, bankroll_cents, is_host, profile_id)
  values (v_room.id, 1, p_host_name, p_bankroll_cents, true, v_uid)
  returning * into v_pl;

  -- provenance and a count. never an item.
  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code,
                            'player_id', v_pl.id, 'session_token', v_pl.session_token,
                            'seat', 1, 'pool_size', v_n);
end $$;

-- ── OPTION 1: a pending room that exists only as a setup link ─────────────
create or replace function public.create_pending_room()
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms;
begin
  -- placeholders; the setup host sets the real numbers at lock-in
  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, host_profile_id,
                            setup_token, setup_expires_at, pool_source)
  values (null, 'Untitled draft', 5, 2000, 100, 15, auth.uid(),
          gen_random_uuid(), now() + interval '24 hours', 'manual')
  returning * into v_room;

  return jsonb_build_object('setup_token', v_room.setup_token,
                            'expires_at', v_room.setup_expires_at);
end $$;

-- Config and status only. Deliberately never returns items, not even before
-- lock-in: the setup host already has their list in their own browser, so
-- there is no reason for the server to ever hand an item list to anybody.
create or replace function public.get_setup_state(p_setup_token uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms;
begin
  select * into v_room from public.rooms where setup_token = p_setup_token;
  if not found then return jsonb_build_object('status','gone'); end if;
  if v_room.setup_expires_at < now() then return jsonb_build_object('status','expired'); end if;
  return jsonb_build_object('status','open',
    'roster_size', v_room.roster_size,
    'bankroll_cents', v_room.starting_bankroll_cents,
    'min_bid_cents', v_room.min_bid_cents,
    'timer_seconds', v_room.timer_seconds,
    'gives_per_player', v_room.gives_per_player);
end $$;

-- ── LOCK-IN: the one and only write of a manual list ──────────────────────
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
  if p_timer_seconds is null or p_timer_seconds < 3 or p_timer_seconds > 300
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

-- ── roster insert loses the pool foreign key ──────────────────────────────
create or replace function public.df20_add_to_roster(
  p_room uuid, p_player uuid, p_name text, p_price int, p_gifted boolean
) returns void language plpgsql security definer
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
    (room_id, player_id, pick_number, item_name, price_cents, gifted)
  values (p_room, p_player, v_pick, p_name, p_price, p_gifted);
end $$;
drop function if exists public.df20_add_to_roster(uuid, uuid, int, text, int, boolean);

create or replace function public.df20_resolve_lot(p_lot uuid, p_action text)
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_lot public.lots;
begin
  select * into v_lot from public.lots where id = p_lot for update;
  if v_lot.status not in ('offered', 'bidding') then return; end if;

  perform public.df20_add_to_roster(
    v_lot.room_id, v_lot.high_bidder_player_id,
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

create or replace function public.df20_resolve_gift(p_lot uuid, p_giver uuid)
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_lot public.lots; v_to uuid;
begin
  select * into v_lot from public.lots where id = p_lot for update;
  if v_lot.status not in ('offered', 'bidding') then return; end if;

  v_to := public.df20_opponent(v_lot.room_id, p_giver);
  perform public.df20_add_to_roster(v_lot.room_id, v_to, v_lot.item_name, 0, true);

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

-- ── the deck is now drawn from the room's own locked pool ─────────────────
create or replace function public.start_draft(p_code text, p_token uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_me public.players; v_n int; v_pool int; v_size int;
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

  -- A room draws a small random SUBSET of its pool, sized to the game, so
  -- scarcity is real and the deck differs every draft.
  select count(*) into v_pool from public.room_pool where room_id = v_room.id;
  if v_pool < v_room.roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;
  v_size := least(greatest(v_room.roster_size * 6, v_room.roster_size * 2 + 4), v_pool);

  insert into public.room_deck (room_id, position, item_name)
  select v_room.id, row_number() over (order by s.r), s.name
    from (select name, random() as r from public.room_pool
           where room_id = v_room.id order by random() limit v_size) s;

  update public.rooms set status = 'live', started_at = now() where id = v_room.id;
  perform public.df20_reveal_next(v_room.id);
  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);
  return public.df20_public_state(v_room.id);
end $$;

-- ── join takes the lowest free seat, because an Option 1 room has no host
--    player until someone arrives ─────────────────────────────────────────
create or replace function public.join_room(p_code text, p_display_name text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_pl public.players; v_n int; v_seat int; v_host boolean;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  if v_room.status <> 'lobby' then raise exception 'DF20_ALREADY_STARTED'; end if;

  p_display_name := public.df20_clean_text(p_display_name, 24);
  if length(p_display_name) = 0 then raise exception 'DF20_BAD_NAME'; end if;

  select count(*) into v_n from public.players where room_id = v_room.id;
  if v_n >= 2 then raise exception 'DF20_ROOM_FULL'; end if;

  select min(s) into v_seat from generate_series(1,2) s
   where not exists (select 1 from public.players
                      where room_id = v_room.id and seat = s);

  v_host := not exists (select 1 from public.players
                         where room_id = v_room.id and is_host);

  insert into public.players (room_id, seat, display_name, bankroll_cents, is_host)
  values (v_room.id, v_seat, p_display_name, v_room.starting_bankroll_cents, v_host)
  returning * into v_pl;

  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);
  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code,
                            'player_id', v_pl.id, 'session_token', v_pl.session_token,
                            'seat', v_pl.seat);
end $$;

-- ── OPT-IN: offered only to an Option 1 setup host, only after the draft,
--    only when nothing in the list looks like a real person ───────────────
create or replace function public.offer_library_optin(p_result_token uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_n int; v_people int; v_state text;
begin
  select * into v_room from public.rooms where setup_result_token = p_result_token;
  if not found then return jsonb_build_object('status','gone'); end if;
  if v_room.status <> 'complete' then return jsonb_build_object('status','not_finished'); end if;
  if v_room.library_optin_state in ('accepted','declined','ineligible') then
    return jsonb_build_object('status', v_room.library_optin_state);
  end if;
  if v_room.pool_source <> 'manual' then
    return jsonb_build_object('status','ineligible');
  end if;

  select count(*) into v_n from public.room_pool where room_id = v_room.id;
  select count(*) into v_people from public.room_pool
   where room_id = v_room.id and public.df20_looks_like_person(name);

  if public.df20_person_oriented_category(v_room.category_name)
     or (v_n > 0 and v_people::numeric / v_n > 0.30) then
    update public.rooms set library_optin_state = 'ineligible' where id = v_room.id;
    return jsonb_build_object('status','ineligible');
  end if;

  update public.rooms set library_optin_state = 'eligible' where id = v_room.id;
  return jsonb_build_object('status','eligible',
                            'category_name', v_room.category_name,
                            'item_count', v_n);
end $$;

create or replace function public.submit_library_optin(
  p_result_token uuid, p_accept boolean
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_id uuid; v_check jsonb;
begin
  select * into v_room from public.rooms where setup_result_token = p_result_token;
  if not found then raise exception 'DF20_NO_ROOM'; end if;

  if not coalesce(p_accept, false) then
    update public.rooms set library_optin_state = 'declined' where id = v_room.id;
    return jsonb_build_object('status','declined');
  end if;

  -- re-run eligibility at submit time; never trust the earlier answer
  v_check := public.offer_library_optin(p_result_token);
  if v_check->>'status' <> 'eligible' then
    return jsonb_build_object('status', v_check->>'status');
  end if;

  insert into public.category_library (name, name_norm)
  values (v_room.category_name, public.df20_norm_category(v_room.category_name))
  on conflict (name_norm) do nothing
  returning id into v_id;
  if v_id is null then
    return jsonb_build_object('status','already_exists');
  end if;

  -- name and items only. no room, no player, no timing.
  insert into public.category_library_items (library_id, name)
  select v_id, name from public.room_pool where room_id = v_room.id
  on conflict do nothing;

  update public.rooms set library_optin_state = 'accepted' where id = v_room.id;
  return jsonb_build_object('status','accepted');
end $$;

-- ── grants. Internal helpers stay ungranted. ──────────────────────────────
grant execute on function public.create_room(text,int,int,int,int,text,boolean,int,text,text,text,uuid) to anon, authenticated;
grant execute on function public.create_pending_room()                    to anon, authenticated;
grant execute on function public.get_setup_state(uuid)                    to anon, authenticated;
grant execute on function public.setup_lock_items(uuid,text,text[],int,int,int,int,int) to anon, authenticated;
grant execute on function public.join_room(text, text)                    to anon, authenticated;
grant execute on function public.start_draft(text, uuid)                  to anon, authenticated;
grant execute on function public.offer_library_optin(uuid)                to anon, authenticated;
grant execute on function public.submit_library_optin(uuid, boolean)      to anon, authenticated;

-- matching returns provenance and a count, never an item, so it is safe to
-- expose; caching gates on the secret above rather than on the grant
grant  execute on function public.df20_match_category(text, int)          to anon, authenticated;
grant  execute on function public.df20_cache_wikipedia(text,text,text,text[]) to anon, authenticated;
revoke all on function public.df20_fill_pool(uuid, text, uuid)            from anon, authenticated;
revoke all on function public.df20_add_to_roster(uuid, uuid, text, int, boolean) from anon, authenticated;
