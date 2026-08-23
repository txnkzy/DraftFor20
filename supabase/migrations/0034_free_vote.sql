-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0034 · the audience vote goes back to free
--
-- 0033 put it behind the paywall. That was the wrong lever: the vote link is
-- how somebody who has never heard of this app meets it. A stranger opens it,
-- argues about two rosters, and is asked whether they could draft better —
-- which is the only path here that reaches people with no prior contact.
-- Charging the host for it converts a few and costs all the reach.
--
-- The split that survives is the honest one:
--
--   FREE     the public vote link, the blind tally, the call to action
--   PREMIUM  the HOST's live dashboard — watching the tally move in the
--            Content tab while it happens. That is a production tool, not
--            distribution, and it stays behind the line.
--
-- Everything else 0033 did stands: host-supplied categories are still premium.
-- ═══════════════════════════════════════════════════════════════════════════

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

grant execute on function public.get_audience_state(text, text) to anon, authenticated;
grant execute on function public.cast_audience_vote(text, text, uuid) to anon, authenticated;

-- nothing gates on this any more, and a dead gate is worse than none: the
-- next person to read it would assume the vote is still paid for
drop function if exists public.df20_room_vote_enabled(uuid);
