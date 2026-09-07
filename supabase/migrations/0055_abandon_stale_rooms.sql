-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0055 · a room whose players walked away ends by itself
--
-- leave_room() handles somebody LEAVING: a button, a confirmation, a decision.
-- It cannot handle the ordinary case, which is two people finishing a draft,
-- closing the tab, and never touching it again. Nothing moves those rooms out
-- of 'live', so they sit there until the 90-day purge — which is why the
-- console's "live now" read 32 at half past ten on a Thursday.
--
-- WHY CRON AND NOT A TRIGGER. A trigger fires on an event. Staleness is the
-- ABSENCE of events: when everyone has gone, nothing happens, so nothing
-- would ever fire. Only something that wakes on a clock can notice silence.
-- pg_cron is already installed here and already running two jobs, so this is
-- a third one on proven ground rather than new infrastructure.
--
-- WHAT COUNTS AS ACTIVITY. Rooms carry no activity timestamp — df20_touch
-- bumps an integer version, not a time — so this reads bid_events, which gets
-- a row for every reveal, bid, pass and win. Same signal 0053 uses for "live
-- now", so the console and the sweeper cannot disagree about what live means.
--
-- THE THRESHOLDS, and why they differ:
--
--   timed rooms      30 min   A turn is 15s by default and 300s at the very
--                             longest. Half an hour of complete silence is
--                             not a long think; it is an empty room.
--
--   no-limit rooms   60 min   timer_seconds = 0 means the bid deliberately
--                             has no clock. "Nobody is rushing this bid" and
--                             "nobody is here at all" are different states and
--                             this is the line between them. Doubling the
--                             window keeps a genuinely slow game alive.
--
--   unfilled lobby   12 hrs   A room nobody ever joined. Deliberately long:
--                             a code made in the morning for a draft that
--                             evening must still be there at kick-off. Twelve
--                             hours clears the clutter without eating a room
--                             somebody is actually about to use.
--
-- Nothing here touches bidding or bankrolls, and no room that finished is
-- altered — only 'lobby' and 'live' are eligible.
-- ═══════════════════════════════════════════════════════════════════════════

-- the sweeper reads these two statuses constantly and nothing else does
create index if not exists rooms_open_status_idx
  on public.rooms (status) where status in ('lobby', 'live');

create or replace function public.df20_abandon_stale()
returns int language plpgsql security definer
set search_path = public, pg_temp as $$
declare r record; n int := 0;
begin
  for r in
    select ro.id, ro.code
      from public.rooms ro
     where ro.status in ('lobby', 'live')
       and case
             -- never filled, and old enough that nobody is coming
             when ro.status = 'lobby' then
               ro.created_at < now() - interval '12 hours'

             -- started, then silence. The clock the room was set up with
             -- decides how much silence is too much.
             else
               coalesce(
                 (select max(e.created_at) from public.bid_events e
                   where e.room_id = ro.id),
                 ro.started_at,
                 ro.created_at
               ) < now() - (case when coalesce(ro.timer_seconds, 15) = 0
                                 then interval '60 minutes'
                                 else interval '30 minutes' end)
           end
  loop
    begin
      /* The same ending leave_room writes, so a draft that was walked away
         from and one that was left on purpose come out identical. The only
         difference is abandoned_by, which stays NULL here — nobody chose
         this — and the room screen already reads that as "This draft was
         abandoned" rather than naming a person. */
      update public.lots
         set status = 'void', on_the_clock_player_id = null,
             turn_expires_at = null, resolved_at = now()
       where room_id = r.id and status in ('offered','bidding');

      update public.rooms
         set status = 'abandoned',
             phase = 'complete',
             abandoned_at = now(),
             completed_at = coalesce(completed_at, now())
       where id = r.id;

      perform public.df20_touch(r.id);
      perform public.df20_broadcast(r.id);   -- anyone still watching sees it
      n := n + 1;
    exception when others then null;   -- one stuck room must not stall the sweep
    end;
  end loop;
  return n;
end $$;

revoke all on function public.df20_abandon_stale() from public;
revoke all on function public.df20_abandon_stale() from anon, authenticated;

-- Every five minutes. The thresholds are half-hours; polling faster would buy
-- nothing and cost a query.
do $$
begin
  perform cron.unschedule('df20_abandon_stale');
exception when others then null;
end $$;

do $$
begin
  perform cron.schedule('df20_abandon_stale', '*/5 * * * *',
                        'select public.df20_abandon_stale();');
  raise notice 'stale-room sweeper scheduled every 5 minutes.';
exception when others then
  raise notice 'pg_cron unavailable. Stale rooms will not be swept.';
end $$;
