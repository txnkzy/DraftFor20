-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · per-draft scouting, and a head-to-head record
--
-- The four axes — Sniper, Whale, Instigator, Hoarder — have existed since
-- 0022 and nobody sees them. They live on /profile, behind a nav click,
-- describing a WINDOW of drafts. The thirty seconds after a draft ends is
-- when two people are still arguing about it, and that is the one moment the
-- numbers would land. So this is the same four axes computed for ONE room,
-- for BOTH players, to be read side by side while the argument is live.
--
-- Same formulas as 0022, same landmarks, deliberately: Whale 100 = paying
-- twice the even split, Instigator 100 = five losing raises. A second set of
-- scales would make the profile page and the results screen disagree about
-- what a Whale is. Gifted cards stay excluded from Sniper and Whale — a card
-- handed to you for nothing is not a purchase.
--
-- NO NEW EXPOSURE. Every input is already public for a finished room:
-- df20_public_state hands out the roster with prices, the events and both
-- bankrolls. This aggregates what a spectator could already add up, which is
-- why it is readable by anyone holding the code rather than gated.
--
-- HEAD TO HEAD needs identity that survives a room, so it is profiles only —
-- two signed-in accounts get a record, anonymous players correctly get
-- nothing. The winner of a past draft comes from the AUDIENCE vote, because
-- the players' own vote was removed: two people asked which of them won both
-- said themselves, which is a tie, which is nobody.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.room_scouting(p_code text)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_out jsonb := '[]'::jsonb; r record;
        v_h2h jsonb := null; v_a uuid; v_b uuid;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code));
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  if v_room.status <> 'complete' then
    return jsonb_build_object('ready', false);
  end if;

  for r in
    select p.id, p.seat, p.display_name, p.profile_id, p.bankroll_cents,
           (select count(*) from public.roster_entries e
             where e.player_id = p.id and not e.gifted)                  as bought,
           (select count(*) from public.roster_entries e
             where e.player_id = p.id and e.gifted)                      as gifts,
           (select count(*) from public.roster_entries e
             where e.player_id = p.id and not e.gifted
               and e.price_cents = v_room.min_bid_cents)                 as snipes,
           (select coalesce(sum(e.price_cents), 0) from public.roster_entries e
             where e.player_id = p.id and not e.gifted)                  as spend,
           -- raises that did not end in a win: the cost of being argued with
           (select count(*) from public.bid_events b
              join public.lots l on l.id = b.lot_id
             where b.room_id = v_room.id and b.player_id = p.id
               and b.action = 'raise'
               and l.winner_player_id is distinct from p.id)             as losing_raises
      from public.players p
     where p.room_id = v_room.id
     order by p.seat
  loop
    declare
      v_even   numeric := case when v_room.roster_size > 0
                          then v_room.starting_bankroll_cents::numeric / v_room.roster_size end;
      v_avg    numeric := case when r.bought > 0 then r.spend::numeric / r.bought end;
      v_left   numeric := case when v_room.starting_bankroll_cents > 0
                          then 100.0 * r.bankroll_cents / v_room.starting_bankroll_cents end;
      v_snipe  numeric := case when r.bought > 0 then 100.0 * r.snipes / r.bought else 0 end;
      s_sniper int; s_whale int; s_inst int; s_hoard int; v_top int; v_title text;
    begin
      s_sniper := least(100, greatest(0, round(v_snipe)))::int;
      s_whale  := least(100, greatest(0, round(
                    case when coalesce(v_even,0) > 0
                         then 50.0 * coalesce(v_avg,0) / v_even else 0 end)))::int;
      s_inst   := least(100, greatest(0, round(r.losing_raises * 20)))::int;
      s_hoard  := least(100, greatest(0, round(coalesce(v_left,0))))::int;

      v_top := greatest(s_sniper, s_whale, s_inst, s_hoard);
      v_title := case
        when v_top = 0 then 'quiet'
        when v_top = s_whale then 'whale'
        when v_top = s_sniper then 'sniper'
        when v_top = s_inst then 'instigator'
        else 'hoarder' end;

      v_out := v_out || jsonb_build_object(
        'seat', r.seat, 'name', r.display_name, 'title', v_title,
        /* Scores and the raw figures behind them. Money is NOT formatted
           here — the client owns formatCents, and a currency string built in
           SQL is one that cannot follow the UI when it changes. */
        'axes', jsonb_build_array(
          jsonb_build_object('key','sniper','label','Sniper','score',s_sniper,
            'snipes', r.snipes, 'bought', r.bought),
          jsonb_build_object('key','whale','label','Whale','score',s_whale,
            'avg_price_cents', round(coalesce(v_avg,0))::int),
          jsonb_build_object('key','instigator','label','Instigator','score',s_inst,
            'losing_raises', r.losing_raises),
          jsonb_build_object('key','hoarder','label','Hoarder','score',s_hoard,
            'leftover_cents', r.bankroll_cents)));
    end;
  end loop;

  -- ── the rivalry, if both sides have an account ────────────────────────
  /* No max() for uuid in Postgres, and no aggregate is wanted anyway —
     there is exactly one player per seat. */
  select profile_id into v_a from public.players
   where room_id = v_room.id and seat = 1;
  select profile_id into v_b from public.players
   where room_id = v_room.id and seat = 2;

  if v_a is not null and v_b is not null then
    select jsonb_build_object(
             'played', count(*),
             'seat1_wins', count(*) filter (where win = 1),
             'seat2_wins', count(*) filter (where win = 2),
             'draws',      count(*) filter (where win is null))
      into v_h2h
      from (
        select case
                 when va > vb then pa.seat
                 when vb > va then pb.seat
               end as win
          from public.rooms r2
          join public.players pa on pa.room_id = r2.id and pa.profile_id = v_a
          join public.players pb on pb.room_id = r2.id and pb.profile_id = v_b
          cross join lateral (
            select count(*) filter (where av.winner_player_id = pa.id) as va,
                   count(*) filter (where av.winner_player_id = pb.id) as vb
              from public.audience_votes av where av.room_id = r2.id) v
         where r2.status = 'complete') h;
  end if;

  return jsonb_build_object('ready', true, 'players', v_out, 'head_to_head', v_h2h);
end $$;

revoke all on function public.room_scouting(text) from public;
grant execute on function public.room_scouting(text) to anon, authenticated;

notify pgrst, 'reload schema';
