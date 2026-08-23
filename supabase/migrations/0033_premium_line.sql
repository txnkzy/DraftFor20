-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0033 · free is the shelf, everything else is premium
--
-- The line moves. Previously custom categories cost an account and the
-- audience vote was free on purpose (it is the acquisition loop). Both are
-- now premium, by decision.
--
--   FREE      the premade shelf: builtin and library pools, signed in or not.
--             Playing, the results card, the watermarked PNG, joining a room.
--   PREMIUM   any pool the host supplies — typed (wikipedia), handed off
--             (manual), or reused (saved) — Content Creator rooms, the OBS
--             source, record mode, card branding, the full scouting report,
--             and now the audience vote.
--
-- Gated HERE, not in the UI. A padlock in React is decoration; the anon key
-- is public and every one of these RPCs is reachable with curl.
--
-- The audience vote checks the HOST's premium, not the voter's. Voters are
-- strangers with no account and never need one — the feature belongs to the
-- person who ran the draft.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.create_room(
  p_title text, p_roster_size int, p_bankroll_cents int, p_min_bid_cents int,
  p_timer_seconds int, p_host_name text, p_is_private boolean default true,
  p_gives_per_player int default 2, p_brand_accent text default null,
  p_brand_logo_url text default null,
  p_pool_source text default 'builtin', p_pool_ref uuid default null,
  p_content_mode text default 'standard'
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
                            content_mode)
  values (public.df20_gen_code(), p_title, p_roster_size, p_bankroll_cents,
          p_min_bid_cents, p_timer_seconds, p_gives_per_player,
          coalesce(p_is_private, true), v_accent,
          public.df20_clean_logo_url(p_brand_logo_url), v_uid,
          p_content_mode)
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

create or replace function public.create_pending_room(p_content_mode text default 'standard')
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_uid uuid;
begin
  v_uid := public.df20_require_verified();

  if not public.df20_rate_limit('pending_room', v_uid::text, 20, 3600) then
    raise exception 'DF20_RATE_LIMITED';
  end if;

  p_content_mode := coalesce(nullif(btrim(lower(p_content_mode)), ''), 'standard');
  if p_content_mode not in ('standard', 'creator') then
    raise exception 'DF20_BAD_CONTENT_MODE';
  end if;
  if p_content_mode = 'creator' and not public.df20_premium_active(v_uid) then
    raise exception 'DF20_PREMIUM_REQUIRED';
  end if;

  -- a setup link exists to build a category by hand, which is the premium
  -- path whatever mode the room is in
  if not public.df20_premium_active(v_uid) then
    raise exception 'DF20_PREMIUM_REQUIRED';
  end if;

  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, host_profile_id,
                            setup_token, setup_expires_at, pool_source, content_mode)
  values (null, 'Untitled draft', 5, 2000, 100, 15, v_uid,
          gen_random_uuid(), now() + interval '24 hours', 'manual', p_content_mode)
  returning * into v_room;

  return jsonb_build_object('setup_token', v_room.setup_token,
                            'expires_at', v_room.setup_expires_at,
                            'room_id', v_room.id,
                            'content_mode', v_room.content_mode);
end $$;
grant execute on function public.create_room(text,int,int,int,int,text,boolean,int,text,text,text,uuid,text) to anon, authenticated;
grant execute on function public.create_pending_room(text) to anon, authenticated;

-- ── does this room's host still pay for the audience vote? ────────────────
create or replace function public.df20_room_vote_enabled(p_room uuid)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select coalesce((select public.df20_premium_active(r.host_profile_id)
                     from public.rooms r where r.id = p_room), false)
$$;
revoke all on function public.df20_room_vote_enabled(uuid) from public;
revoke all on function public.df20_room_vote_enabled(uuid) from anon, authenticated;

-- ── the vote page ─────────────────────────────────────────────────────────
-- 'locked' is a distinct answer from 'gone': the voter should be told the
-- draft is real and the host has not unlocked voting, not that the link is
-- broken. It is also the one place a stranger meets the paywall, so it is
-- worth being honest rather than blank.
create or replace function public.get_audience_state(p_code text, p_voter_key text)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_mine uuid; v_key text;
begin
  v_key := btrim(coalesce(p_code, ''));
  if v_key ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into v_room from public.rooms where id = v_key::uuid;
  else
    select * into v_room from public.rooms where code = upper(v_key);
  end if;
  if not found then return jsonb_build_object('status','gone'); end if;

  if v_room.status <> 'complete' then
    return jsonb_build_object('status','not_finished', 'title', v_room.title,
                              'room_id', v_room.id, 'code', v_room.code);
  end if;

  if not public.df20_room_vote_enabled(v_room.id) then
    return jsonb_build_object('status','locked', 'title', v_room.title,
                              'code', v_room.code);
  end if;

  select winner_player_id into v_mine from public.audience_votes
   where room_id = v_room.id and voter_key = coalesce(p_voter_key, '');

  return jsonb_build_object(
    'status', 'open',
    'room_id', v_room.id,
    'code', v_room.code,
    'title', v_room.title,
    'category', v_room.category_name,
    'roster_size', v_room.roster_size,
    'starting_cents', v_room.starting_bankroll_cents,
    'players', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pl.id, 'seat', pl.seat, 'name', pl.display_name,
               'leftover_cents', pl.bankroll_cents,
               'spent_cents', coalesce((select sum(r.price_cents) from public.roster_entries r
                                         where r.room_id = v_room.id and r.player_id = pl.id), 0),
               'rows', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'pick', r.pick_number, 'item', r.item_name,
                          'price_cents', r.price_cents, 'gifted', r.gifted)
                        order by r.pick_number)
                   from public.roster_entries r
                  where r.room_id = v_room.id and r.player_id = pl.id), '[]'::jsonb))
             order by pl.seat)
        from public.players pl where pl.room_id = v_room.id), '[]'::jsonb),
    'your_vote', v_mine,
    'tally', case when v_mine is null then null
                  else public.df20_audience_tally(v_room.id) end);
end $$;
grant execute on function public.get_audience_state(text, text) to anon, authenticated;

-- ── and the vote itself ───────────────────────────────────────────────────
create or replace function public.cast_audience_vote(
  p_code text, p_voter_key text, p_winner_player_id uuid
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_key text; v_ref text;
begin
  v_key := public.df20_clean_text(p_voter_key, 64);
  if length(v_key) < 16 then raise exception 'DF20_BAD_VOTE'; end if;

  v_ref := btrim(coalesce(p_code, ''));
  if v_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into v_room from public.rooms where id = v_ref::uuid for update;
  else
    select * into v_room from public.rooms where code = upper(v_ref) for update;
  end if;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  if v_room.status <> 'complete' then raise exception 'DF20_NOT_COMPLETE'; end if;
  if not public.df20_room_vote_enabled(v_room.id) then
    raise exception 'DF20_PREMIUM_REQUIRED';
  end if;
  if not exists (select 1 from public.players
                  where id = p_winner_player_id and room_id = v_room.id)
    then raise exception 'DF20_BAD_VOTE'; end if;

  if not public.df20_rate_limit('aud_vote', v_key, 20, 3600) then
    raise exception 'DF20_RATE_LIMITED';
  end if;

  insert into public.audience_votes (room_id, voter_key, winner_player_id)
  values (v_room.id, v_key, p_winner_player_id)
  on conflict (room_id, voter_key) do nothing;

  begin
    perform realtime.send(
      public.df20_audience_tally(v_room.id), 'audience',
      'room:' || v_room.id::text, false);
  exception when others then null;
  end;

  return public.get_audience_state(v_room.id::text, v_key);
end $$;
grant execute on function public.cast_audience_vote(text, text, uuid) to anon, authenticated;
