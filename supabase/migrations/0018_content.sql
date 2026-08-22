-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0018 · the OBS source link and the audience vote
--
-- Two new public read paths, both read-only by construction:
--
--   get_obs_state(obs_token)     the live board for an OBS Browser Source
--   get_audience_state(code,key) the finished board a viewer votes on
--
-- Neither takes a session token, and every mutating RPC in this app
-- authenticates from a session token. There is therefore no argument either
-- of these views could pass to act on a game — the read path is the only
-- path they have.
--
-- The audience vote is a SEPARATE table from votes. votes is the two
-- players' one-tap call on who won and feeds the win/loss record; this is
-- the internet's opinion and feeds nothing but itself.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.rooms add column if not exists obs_token uuid;
create unique index if not exists rooms_obs_token_idx
  on public.rooms(obs_token) where obs_token is not null;

-- ── the snapshot must stop carrying tokens ────────────────────────────────
-- to_jsonb(rooms) means every column added to the table lands in the payload
-- every client already reads. That was survivable while the only secret in
-- the row was a setup link; adding obs_token to the table would have handed
-- it to both players' browsers automatically. Stripped by name, so a new
-- token column is a deliberate decision rather than an accident.
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
revoke all on function public.df20_public_state(uuid) from anon, authenticated;

-- ── mint the OBS link. Host seat + active premium. ────────────────────────
-- The premium check is here rather than only on the Content tab, because the
-- tab is a React component and this RPC is reachable with curl.
create or replace function public.mint_obs_token(p_code text, p_token uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_me public.players; v_tok uuid;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;

  select * into v_me from public.players
   where room_id = v_room.id and session_token = p_token;
  if not found then raise exception 'DF20_BAD_TOKEN'; end if;
  if not v_me.is_host then raise exception 'DF20_HOST_ONLY'; end if;

  if v_room.host_profile_id is null
     or not public.df20_premium_active(v_room.host_profile_id) then
    raise exception 'DF20_PREMIUM_REQUIRED';
  end if;

  v_tok := v_room.obs_token;
  if v_tok is null then
    v_tok := gen_random_uuid();
    update public.rooms set obs_token = v_tok where id = v_room.id;
  end if;
  return jsonb_build_object('obs_token', v_tok);
end $$;
grant execute on function public.mint_obs_token(text, uuid) to anon, authenticated;

-- rotate: the old browser source goes dark, which is the point
create or replace function public.rotate_obs_token(p_code text, p_token uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_me public.players;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  select * into v_me from public.players
   where room_id = v_room.id and session_token = p_token;
  if not found then raise exception 'DF20_BAD_TOKEN'; end if;
  if not v_me.is_host then raise exception 'DF20_HOST_ONLY'; end if;
  if v_room.host_profile_id is null
     or not public.df20_premium_active(v_room.host_profile_id) then
    raise exception 'DF20_PREMIUM_REQUIRED';
  end if;

  update public.rooms set obs_token = null where id = v_room.id;
  return public.mint_obs_token(p_code, p_token);
end $$;
grant execute on function public.rotate_obs_token(text, uuid) to anon, authenticated;

-- ── the OBS read path. No login, no code, no way back to an action. ───────
create or replace function public.get_obs_state(p_obs_token uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_id uuid; v_state jsonb;
begin
  if p_obs_token is null then return null; end if;
  select id into v_id from public.rooms where obs_token = p_obs_token;
  if not found then return null; end if;

  v_state := public.df20_public_state(v_id);
  -- the room code is the capability that lets someone take an empty seat.
  -- A browser source URL ends up pasted into OBS, screenshared and posted;
  -- it has no reason to carry the code and every reason not to.
  return jsonb_set(v_state, '{room}', (v_state->'room') - 'code');
end $$;
grant execute on function public.get_obs_state(uuid) to anon, authenticated;

-- ── the audience vote ─────────────────────────────────────────────────────
-- voter_key is a random id in an httpOnly cookie set by our own route
-- handler, so refreshing, opening a second tab or editing localStorage all
-- land on the same row. The unique constraint is the enforcement; the cookie
-- is only how the browser is recognised.
create table if not exists public.audience_votes (
  room_id          uuid not null references public.rooms(id) on delete cascade,
  voter_key        text not null,
  winner_player_id uuid not null references public.players(id) on delete cascade,
  created_at       timestamptz not null default now(),
  primary key (room_id, voter_key)
);
create index if not exists audience_votes_room_idx on public.audience_votes(room_id);

alter table public.audience_votes enable row level security;
revoke all on public.audience_votes from anon, authenticated;

create or replace function public.df20_audience_tally(p_room uuid)
returns jsonb language sql stable security definer
set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'total', (select count(*) from public.audience_votes where room_id = p_room),
    'by_player', coalesce((
      select jsonb_object_agg(pl.id::text, coalesce(c.n, 0))
        from public.players pl
        left join (select winner_player_id, count(*) as n
                     from public.audience_votes where room_id = p_room
                    group by winner_player_id) c on c.winner_player_id = pl.id
       where pl.room_id = p_room), '{}'::jsonb));
$$;
revoke all on function public.df20_audience_tally(uuid) from anon, authenticated;

-- the finished board a stranger votes on. tally is null until they have.
create or replace function public.get_audience_state(p_code text, p_voter_key text)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_mine uuid;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code));
  if not found then return jsonb_build_object('status','gone'); end if;
  if v_room.status <> 'complete' then
    return jsonb_build_object('status','not_finished', 'title', v_room.title);
  end if;

  select winner_player_id into v_mine from public.audience_votes
   where room_id = v_room.id and voter_key = coalesce(p_voter_key, '');

  return jsonb_build_object(
    'status', 'open',
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
    -- THE BLIND RULE, enforced in the database. A viewer who has not voted
    -- is not told the numbers, so hiding them in the UI is not what is
    -- keeping the vote blind.
    'tally', case when v_mine is null then null
                  else public.df20_audience_tally(v_room.id) end);
end $$;
grant execute on function public.get_audience_state(text, text) to anon, authenticated;

create or replace function public.cast_audience_vote(
  p_code text, p_voter_key text, p_winner_player_id uuid
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_key text;
begin
  v_key := public.df20_clean_text(p_voter_key, 64);
  if length(v_key) < 16 then raise exception 'DF20_BAD_VOTE'; end if;

  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  if v_room.status <> 'complete' then raise exception 'DF20_NOT_COMPLETE'; end if;
  if not exists (select 1 from public.players
                  where id = p_winner_player_id and room_id = v_room.id)
    then raise exception 'DF20_BAD_VOTE'; end if;

  -- second guard behind the unique key: one browser churning cookies still
  -- cannot pour votes into the same room
  if not public.df20_rate_limit('aud_vote', v_key, 20, 3600) then
    raise exception 'DF20_RATE_LIMITED';
  end if;

  -- FIRST vote stands. A second attempt is not an error and does not change
  -- anything: the viewer simply sees the tally they already earned.
  insert into public.audience_votes (room_id, voter_key, winner_player_id)
  values (v_room.id, v_key, p_winner_player_id)
  on conflict (room_id, voter_key) do nothing;

  begin
    perform realtime.send(
      public.df20_audience_tally(v_room.id), 'audience',
      'room:' || v_room.id::text, false);
  exception when others then null;   -- the hub polls as well
  end;

  return public.get_audience_state(p_code, v_key);
end $$;
grant execute on function public.cast_audience_vote(text, text, uuid) to anon, authenticated;

-- the host's own hub: always shows the numbers, never needs to have voted
create or replace function public.get_audience_hub(p_code text, p_token uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_me public.players;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code));
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  select * into v_me from public.players
   where room_id = v_room.id and session_token = p_token;
  if not found then raise exception 'DF20_BAD_TOKEN'; end if;

  return jsonb_build_object(
    'complete', v_room.status = 'complete',
    'tally', public.df20_audience_tally(v_room.id),
    'players', coalesce((select jsonb_agg(jsonb_build_object(
                                  'id', pl.id, 'seat', pl.seat, 'name', pl.display_name)
                                order by pl.seat)
                           from public.players pl where pl.room_id = v_room.id), '[]'::jsonb));
end $$;
grant execute on function public.get_audience_hub(text, uuid) to anon, authenticated;
