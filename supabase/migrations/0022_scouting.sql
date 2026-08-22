-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0022 · the Scouting Report
--
-- Four numbers describing HOW somebody drafts, aggregated from what the game
-- already writes down. Nothing new is tracked and nothing new is recorded:
--
--   roster_entries  what you won, what you paid, whether it was a gift
--   bid_events      every raise, with who made it
--   lots            who ended up winning each one
--   players         the bankroll you finished with
--   rooms           the minimum bid and starting bankroll that give the
--                   other four numbers a scale
--
-- FREE accounts see the last 5 completed drafts. PREMIUM sees everything.
-- That window is applied HERE, not in the UI, because the anon key is public.
--
-- Gifted cards are excluded from Sniper and Whale. A card handed to you for
-- nothing is not a purchase and says nothing about how you bid; leaving them
-- in would make a player who was dumped on look like a bargain hunter.
-- They stay in the roster counts, which is where they belong.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.my_scouting_report()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_uid uuid; v_premium boolean; v_limit int; v_total int;
  v_drafts int; v_bought int; v_gifts int; v_snipes int; v_lost_raises int;
  v_avg_price numeric; v_avg_leftover numeric; v_avg_leftover_pct numeric;
  v_even_price numeric; v_sniper_pct numeric; v_raises_per_draft numeric;
  v_s_sniper int; v_s_whale int; v_s_instigator int; v_s_hoarder int;
  v_title text; v_top int; v_second int;
begin
  v_uid := auth.uid();
  if v_uid is null then return jsonb_build_object('signed_in', false); end if;

  v_premium := public.df20_premium_active(v_uid);
  -- null means "no limit" to Postgres, which is exactly what premium buys
  v_limit := case when v_premium then null else 5 end;

  select count(*) into v_total
    from public.players p join public.rooms r on r.id = p.room_id
   where p.profile_id = v_uid and r.status = 'complete';

  -- One statement, no temp table: PostgREST runs a `stable` function inside a
  -- READ ONLY transaction, where creating one would fail.
  with picked as (
    select p.id as player_id, p.room_id,
           p.bankroll_cents as leftover, r.min_bid_cents as min_bid,
           r.starting_bankroll_cents as starting, r.roster_size as roster
      from public.players p
      join public.rooms r on r.id = p.room_id
     where p.profile_id = v_uid and r.status = 'complete'
     order by r.completed_at desc nulls last
     limit v_limit
  ),
  per_draft as (
    select k.leftover, k.starting, k.roster,
           (select count(*) from public.roster_entries e
             where e.room_id = k.room_id and e.player_id = k.player_id
               and not e.gifted) as bought,
           (select count(*) from public.roster_entries e
             where e.room_id = k.room_id and e.player_id = k.player_id
               and e.gifted) as gifts,
           (select coalesce(sum(e.price_cents), 0) from public.roster_entries e
             where e.room_id = k.room_id and e.player_id = k.player_id) as spend,
           -- THE SNIPER: bought at exactly the room's minimum
           (select count(*) from public.roster_entries e
             where e.room_id = k.room_id and e.player_id = k.player_id
               and not e.gifted and e.price_cents = k.min_bid) as snipes,
           -- THE INSTIGATOR: a raise you made on a lot somebody else won.
           -- Every raise counts, not every lot: pushing the same card three
           -- times and walking away is three acts of instigation.
           (select count(*) from public.bid_events b
              join public.lots l on l.id = b.lot_id
             where b.room_id = k.room_id and b.player_id = k.player_id
               and b.action = 'raise'
               and l.winner_player_id is distinct from k.player_id) as lost_raises
      from picked k
  )
  select count(*), coalesce(sum(bought), 0), coalesce(sum(gifts), 0),
         coalesce(sum(snipes), 0), coalesce(sum(lost_raises), 0),
         -- THE WHALE: average price per card BOUGHT, averaged per draft so
         -- one twelve-slot marathon does not drown out ten short games
         avg(case when bought > 0 then spend::numeric / bought end),
         avg(leftover),
         avg(case when starting > 0 then 100.0 * leftover / starting end),
         avg(case when roster > 0 then starting::numeric / roster end)
    into v_drafts, v_bought, v_gifts, v_snipes, v_lost_raises,
         v_avg_price, v_avg_leftover, v_avg_leftover_pct, v_even_price
    from per_draft;

  if v_drafts = 0 then
    return jsonb_build_object('signed_in', true, 'drafts', 0,
      'window', jsonb_build_object('premium', v_premium, 'counted', 0,
                                   'total', v_total, 'cap', v_limit));
  end if;

  v_sniper_pct := case when v_bought > 0 then 100.0 * v_snipes / v_bought else 0 end;
  v_raises_per_draft := v_lost_raises::numeric / v_drafts;

  -- ── the four axes, all 0-100 so they can share one chart ───────────────
  -- Sniper and Hoarder are already percentages of something real. Whale and
  -- Instigator need a scale, so each is pinned to a defensible landmark:
  --   Whale       100 = paying twice the even split (bankroll / roster)
  --   Instigator  100 = five losing raises per draft
  v_s_sniper     := least(100, greatest(0, round(v_sniper_pct)))::int;
  v_s_whale      := least(100, greatest(0, round(
                      case when coalesce(v_even_price, 0) > 0
                           then 50.0 * coalesce(v_avg_price, 0) / v_even_price
                           else 0 end)))::int;
  v_s_instigator := least(100, greatest(0, round(v_raises_per_draft * 20)))::int;
  v_s_hoarder    := least(100, greatest(0, round(coalesce(v_avg_leftover_pct, 0))))::int;

  -- ── the title ──────────────────────────────────────────────────────────
  -- Deliberately hard to earn: two drafts of tape minimum, the leading axis
  -- has to clear 40, and it has to be 8 clear of the next one. A title that
  -- everybody has is not a title.
  select max(v), (array_agg(v order by v desc))[2]
    into v_top, v_second
    from unnest(array[v_s_sniper, v_s_whale, v_s_instigator, v_s_hoarder]) v;

  if v_drafts < 2 then
    v_title := 'unread';
  elsif v_top < 40 or (v_top - coalesce(v_second, 0)) < 8 then
    v_title := 'allrounder';
  elsif v_top = v_s_sniper     then v_title := 'sniper';
  elsif v_top = v_s_whale      then v_title := 'whale';
  elsif v_top = v_s_instigator then v_title := 'instigator';
  else                              v_title := 'hoarder';
  end if;

  return jsonb_build_object(
    'signed_in', true,
    'drafts', v_drafts,
    'title', v_title,
    'window', jsonb_build_object('premium', v_premium, 'counted', v_drafts,
                                 'total', v_total, 'cap', v_limit),
    'axes', jsonb_build_array(
      jsonb_build_object('key','sniper','label','Sniper','score',v_s_sniper,
        'raw', round(v_sniper_pct)::int, 'unit','%',
        'note','bought at the minimum'),
      jsonb_build_object('key','whale','label','Whale','score',v_s_whale,
        'raw', round(coalesce(v_avg_price, 0))::int, 'unit','cents',
        'note','average price per card bought'),
      jsonb_build_object('key','instigator','label','Instigator','score',v_s_instigator,
        'raw', v_lost_raises, 'unit','raises',
        'note','raises on cards somebody else won'),
      jsonb_build_object('key','hoarder','label','Hoarder','score',v_s_hoarder,
        'raw', round(coalesce(v_avg_leftover, 0))::int, 'unit','cents',
        'note','average bankroll left at the end')),
    'totals', jsonb_build_object(
      'cards_bought', v_bought, 'cards_gifted', v_gifts,
      'min_bid_buys', v_snipes, 'losing_raises', v_lost_raises,
      'avg_price_cents', round(coalesce(v_avg_price, 0))::int,
      'avg_leftover_cents', round(coalesce(v_avg_leftover, 0))::int));
end $$;
grant execute on function public.my_scouting_report() to authenticated;
