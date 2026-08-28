-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0053 · finished drafts, and a "live now" that means now
--
-- TWO NUMBERS WERE LYING BY ACCUMULATION.
--
-- 1. The headline counted rooms CREATED. A code nobody used counted the same
--    as a finished draft. The headline is now finished drafts; creation stays
--    as the funnel's denominator, where it belongs.
--
-- 2. "live now" counted `status = 'live'`, and nothing ever moves a room out
--    of that state on its own. `abandoned` is set only by leave_room, an
--    explicit button. Two people who close the tab mid-draft leave the row
--    'live' until the 90-day purge deletes it — so the figure was every
--    unfinished draft of the last ninety days, not the games running right
--    now. At 10:30pm on a Thursday that reads as a busy site.
--
-- Rooms carry no activity timestamp — df20_touch bumps an integer version,
-- not a time — so recency comes from bid_events, which gets a row for every
-- reveal, bid, pass and win, and is already indexed by (room_id, id). A room
-- with one in the last fifteen minutes has somebody at the keyboard. The rest
-- are reported separately as idle rather than folded into the same tile.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.admin_activity()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_since timestamptz := now() - interval '7 days';
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;

  return jsonb_build_object(
    'rooms', jsonb_build_object(
      'total',  (select count(*) from public.rooms where code is not null),
      'today',  (select count(*) from public.rooms
                  where code is not null and created_at >= date_trunc('day', now())),
      'week',   (select count(*) from public.rooms
                  where code is not null and created_at >= v_since),
      'complete',(select count(*) from public.rooms where status = 'complete'),

      -- ── the headline: drafts that actually FINISHED ───────────────────
      'finished_today', (select count(*) from public.rooms
                          where status = 'complete'
                            and completed_at >= date_trunc('day', now())),
      'finished_week',  (select count(*) from public.rooms
                          where status = 'complete' and completed_at >= v_since),

      -- ── live means live ───────────────────────────────────────────────
      -- Somebody has touched this draft in the last fifteen minutes. A turn
      -- is fifteen seconds by default and five minutes at the longest, so a
      -- game in progress cannot be quiet for that long; a game whose players
      -- shut the laptop goes quiet immediately.
      'live', (select count(*) from public.rooms r
                where r.status = 'live'
                  and exists (select 1 from public.bid_events e
                               where e.room_id = r.id
                                 and e.created_at > now() - interval '15 minutes')),

      -- started, never finished, nobody home. Not concurrency — backlog.
      'live_idle', (select count(*) from public.rooms r
                     where r.status = 'live'
                       and not exists (select 1 from public.bid_events e
                                        where e.room_id = r.id
                                          and e.created_at > now() - interval '15 minutes')),

      -- ── the same seven days, narrowed at each step ────────────────────
      -- A room that never found a second player was never a game. Counting
      -- the drop-off is the only way to read the top number honestly.
      'week_joined', (select count(*) from public.rooms r
                       where r.code is not null and r.created_at >= v_since
                         and (select count(*) from public.players p
                               where p.room_id = r.id) >= 2),
      'week_started', (select count(*) from public.rooms
                        where code is not null and created_at >= v_since
                          and started_at is not null),
      'week_complete', (select count(*) from public.rooms
                         where code is not null and created_at >= v_since
                           and status = 'complete'),
      -- created, never joined by anyone but the host, and now stale
      'week_empty', (select count(*) from public.rooms r
                      where r.code is not null and r.created_at >= v_since
                        and (select count(*) from public.players p
                              where p.room_id = r.id) < 2)),

    'daily', coalesce((
      select jsonb_agg(jsonb_build_object('day', d::date, 'rooms', n) order by d)
        from (select g.d, (select count(*) from public.rooms r
                            where r.code is not null
                              and r.created_at >= g.d and r.created_at < g.d + interval '1 day') as n
                from generate_series(date_trunc('day', now()) - interval '13 days',
                                     date_trunc('day', now()), interval '1 day') g(d)) s),
      '[]'::jsonb),

    'categories', jsonb_build_object(
      'football', (select count(*) from public.rooms
                    where code is not null and category_name = 'Football Draft'),
      'other_library', (select count(*) from public.rooms
                         where code is not null and pool_source in ('builtin','library')
                           and coalesce(category_name,'') <> 'Football Draft'),
      'wikipedia', (select count(*) from public.rooms
                     where code is not null and pool_source = 'wikipedia'),
      'manual', (select count(*) from public.rooms
                  where code is not null and pool_source = 'manual'),
      'saved', (select count(*) from public.rooms
                 where code is not null and pool_source = 'saved')),

    'modes', jsonb_build_object(
      'standard', (select count(*) from public.rooms
                    where code is not null and content_mode = 'standard'),
      'creator', (select count(*) from public.rooms
                   where code is not null and content_mode = 'creator')),

    'duration', (
      select jsonb_build_object(
               'sample', count(*),
               'avg_seconds', round(avg(secs)),
               'median_seconds', round(percentile_cont(0.5) within group (order by secs)))
        from (select extract(epoch from (completed_at - started_at)) as secs
                from public.rooms
               where status = 'complete'
                 and started_at is not null and completed_at is not null
                 and completed_at > started_at
                 and completed_at - started_at < interval '12 hours') d),

    'library', jsonb_build_object(
      'public', (select count(*) from public.category_library),
      'pending', (select count(*) from public.rooms where library_optin_state = 'pending'),
      'saved_decks', (select count(*) from public.user_categories)),

    'audience', jsonb_build_object(
      'votes', (select count(*) from public.audience_votes),
      'rooms_voted_on', (select count(distinct room_id) from public.audience_votes)),

    'premium', jsonb_build_object(
      'active', (select count(*) from public.profiles where premium_until > now()),
      'by_source', coalesce((select jsonb_object_agg(coalesce(premium_source,'none'), n)
                               from (select premium_source, count(*) as n
                                       from public.profiles
                                      where premium_until > now()
                                      group by premium_source) s), '{}'::jsonb)));
end $$;
grant execute on function public.admin_activity() to authenticated;
