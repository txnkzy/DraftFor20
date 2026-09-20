-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0058 · finished drafts on the same chart as created rooms
--
-- The bar chart plotted rooms created and nothing else, which is the number
-- that already misleads: most rooms never find a second player, so a tall bar
-- says nothing about whether anybody played. Putting finished drafts on the
-- same axes makes the gap between the two the thing you actually see.
--
-- The two series are deliberately different cohorts. `rooms` is created that
-- day; `finished` is completed that day. A room opened on Monday and played
-- out on Tuesday is in Monday's bar and Tuesday's line. For trends that is
-- the right pairing. For "of the rooms we made, how many got played", the
-- weekly funnel from 0052 is the cohort answer and this is not.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.admin_activity()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $BODY$

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

    /* Two series over the same fourteen days. `rooms` counts what was
       CREATED that day; `finished` counts what was COMPLETED that day, which
       is a different cohort on purpose — a room opened on Monday and played
       out on Tuesday belongs to Monday's creation and Tuesday's finish. Read
       as trend lines that is the honest pairing; for "of what we made, how
       much got played", the weekly funnel above is the cohort answer. */
    'daily', coalesce((
      select jsonb_agg(jsonb_build_object('day', d::date, 'rooms', n,
                                          'finished', f) order by d)
        from (select g.d,
                     (select count(*) from public.rooms r
                       where r.code is not null
                         and r.created_at >= g.d
                         and r.created_at < g.d + interval '1 day') as n,
                     (select count(*) from public.rooms r
                       where r.status = 'complete'
                         and r.completed_at >= g.d
                         and r.completed_at < g.d + interval '1 day') as f
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
end 
$BODY$;
grant execute on function public.admin_activity() to authenticated;

notify pgrst, 'reload schema';
