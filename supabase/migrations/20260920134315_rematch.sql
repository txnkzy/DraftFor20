-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · rematch — "Run it back" that actually runs it back
--
-- That button was <Link href="/new">. It carried nothing: not the category,
-- not the bankroll, not the roster size, and not the person you had just
-- played. You re-picked every setting and generated a new code to send to
-- somebody who was already there.
--
-- A rematch copies the settings, seats BOTH players under the names they
-- just used, and needs no code passed between them.
--
-- WHY TWO FUNCTIONS AND NOT ONE. The obvious shape — one call that returns
-- both players' session tokens — hands the caller the ability to act as
-- their opponent, which is the one thing this app's whole auth model exists
-- to prevent. So the room is created with both seats filled, and each player
-- collects their OWN token by proving they held a seat in the room it came
-- from. Nobody is ever handed anybody else's.
--
-- The deck is dealt fresh from the same source, so a rematch on a saved or
-- typed category is the same category reshuffled, never the same order.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.rooms
  add column if not exists rematch_of uuid references public.rooms(id) on delete set null;

create index if not exists rooms_rematch_of_idx
  on public.rooms (rematch_of) where rematch_of is not null;

-- ── start one ─────────────────────────────────────────────────────────────
create or replace function public.create_rematch(p_code text, p_token uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_old public.rooms; v_me public.players; v_new public.rooms;
        v_n int; v_mine uuid;
begin
  select * into v_old from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;

  select * into v_me from public.players
   where room_id = v_old.id and session_token = p_token;
  if not found then raise exception 'DF20_NOT_IN_ROOM'; end if;

  if v_old.status not in ('complete', 'abandoned') then
    raise exception 'DF20_NOT_FINISHED';
  end if;

  -- somebody already pressed it: hand back the same room rather than making
  -- a second one, so two people tapping at once cannot fork the rematch
  select * into v_new from public.rooms where rematch_of = v_old.id limit 1;
  if found then
    return (select jsonb_build_object(
              'code', v_new.code, 'room_id', v_new.id, 'player_id', np.id,
              'token', np.session_token, 'seat', np.seat, 'created', false)
              from public.players np
             where np.room_id = v_new.id and np.seat = v_me.seat);
  end if;

  insert into public.rooms (
      code, title, roster_size, starting_bankroll_cents, min_bid_cents,
      timer_seconds, gives_per_player, is_private, brand_accent, brand_logo_url,
      host_profile_id, content_mode, allow_broke, category_name, pool_source,
      rematch_of)
  select public.df20_gen_code(), v_old.title, v_old.roster_size,
         v_old.starting_bankroll_cents, v_old.min_bid_cents, v_old.timer_seconds,
         v_old.gives_per_player, v_old.is_private, v_old.brand_accent,
         v_old.brand_logo_url, v_old.host_profile_id, v_old.content_mode,
         v_old.allow_broke, v_old.category_name, v_old.pool_source,
         v_old.id
  returning * into v_new;

  -- both seats, same names, fresh tokens
  insert into public.players (room_id, seat, display_name, bankroll_cents,
                              is_host, profile_id)
  select v_new.id, p.seat, p.display_name, v_new.starting_bankroll_cents,
         p.is_host, p.profile_id
    from public.players p where p.room_id = v_old.id;

  v_n := public.df20_fill_pool(v_new.id, coalesce(v_old.pool_source, 'builtin'), null);
  if v_n < v_new.roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;

  perform public.df20_touch(v_old.id);
  perform public.df20_broadcast(v_old.id);   -- the other screen learns of it

  /* room_id and player_id come back too: the client's session store keys on
     them, and a seat saved without a player id is silently discarded. */
  return (select jsonb_build_object(
            'code', v_new.code, 'room_id', v_new.id, 'player_id', np.id,
            'token', np.session_token, 'seat', np.seat, 'created', true)
            from public.players np
           where np.room_id = v_new.id and np.seat = v_me.seat);
end $$;

-- ── join the one your opponent started ────────────────────────────────────
create or replace function public.claim_rematch(p_code text, p_token uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_old public.rooms; v_me public.players; v_new public.rooms; v_mine uuid;
begin
  select * into v_old from public.rooms where code = upper(btrim(p_code));
  if not found then raise exception 'DF20_NO_ROOM'; end if;

  /* The proof is the OLD token. Holding a seat in the room this came from is
     what entitles you to the matching seat in the rematch — and it only ever
     returns the token for YOUR seat. */
  select * into v_me from public.players
   where room_id = v_old.id and session_token = p_token;
  if not found then raise exception 'DF20_NOT_IN_ROOM'; end if;

  select * into v_new from public.rooms where rematch_of = v_old.id limit 1;
  if not found then raise exception 'DF20_NO_REMATCH'; end if;

  select session_token into v_mine from public.players
   where room_id = v_new.id and seat = v_me.seat;
  if v_mine is null then raise exception 'DF20_NO_SEAT'; end if;

  return (select jsonb_build_object(
            'code', v_new.code, 'room_id', v_new.id, 'player_id', np.id,
            'token', np.session_token, 'seat', np.seat)
            from public.players np
           where np.room_id = v_new.id and np.seat = v_me.seat);
end $$;

revoke all on function public.create_rematch(text, uuid) from public;
revoke all on function public.claim_rematch(text, uuid) from public;
grant execute on function public.create_rematch(text, uuid) to anon, authenticated;
grant execute on function public.claim_rematch(text, uuid) to anon, authenticated;

-- ── let the old room say a rematch exists ─────────────────────────────────
create or replace function public.df20_public_state(p_room uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $PS$

declare v_room public.rooms;
begin
  select * into v_room from public.rooms where id = p_room;
  if not found then return null; end if;

  return jsonb_build_object(
    'server_now', to_jsonb(now()),
    /* The pointer lives on the NEW room, so a finished room cannot tell its
       own players that a rematch is waiting. This adds that one derived
       field — a code, which is not a secret; anyone in the old room is
       entitled to the seat it leads to, and claim_rematch still demands
       their old token before handing over anything. */
    'room', (to_jsonb(v_room) - 'setup_token' - 'setup_result_token' - 'obs_token')
            || jsonb_build_object('rematch_code',
                 (select n.code from public.rooms n where n.rematch_of = v_room.id limit 1)),
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
end 
$PS$;
revoke all on function public.df20_public_state(uuid) from public, anon, authenticated;

notify pgrst, 'reload schema';
