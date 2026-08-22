-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0007 · OPTIONAL background jobs
--
-- Normal expiry is client-driven: whichever client's countdown hits zero calls
-- expire_turn(), which is idempotent and no-ops unless the deadline genuinely
-- passed. This sweeper only matters for a room where BOTH clients closed
-- mid-lot. Skip this file if pg_cron is unavailable; the app is correct.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.df20_sweep_expired()
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare r record; n int := 0;
begin
  for r in
    select ro.code from public.rooms ro
      join public.lots l on l.room_id = ro.id and l.status in ('offered','bidding')
     where l.turn_expires_at < now() - interval '2 seconds'
  loop
    begin
      perform public.expire_turn(r.code);
      n := n + 1;
    exception when others then null;   -- one stuck room must not stall the sweep
    end;
  end loop;
  return n;
end $$;
revoke all on function public.df20_sweep_expired() from anon, authenticated;

-- Retention. The privacy policy promises rooms are purged after 90 days, so
-- this is what makes that true.
create or replace function public.df20_purge_old_rooms()
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  with gone as (
    delete from public.rooms where created_at < now() - interval '90 days' returning 1
  ) select count(*) into n from gone;
  delete from public.rate_limits where window_start < now() - interval '1 day';
  return n;
end $$;
revoke all on function public.df20_purge_old_rooms() from anon, authenticated;

do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule('df20_sweep_expired');
exception when others then null;
end $$;

do $$
begin
  perform cron.schedule('df20_sweep_expired', '5 seconds', 'select public.df20_sweep_expired();');
  raise notice 'pg_cron sweeper scheduled every 5s.';
exception when others then
  raise notice 'pg_cron unavailable. Skipping sweeper; client-driven expiry still works.';
end $$;

do $$
begin
  perform cron.unschedule('df20_purge_old_rooms');
exception when others then null;
end $$;

do $$
begin
  perform cron.schedule('df20_purge_old_rooms', '17 4 * * *', 'select public.df20_purge_old_rooms();');
  raise notice 'pg_cron retention job scheduled daily at 04:17 UTC.';
exception when others then
  raise notice 'pg_cron unavailable. Run select public.df20_purge_old_rooms(); on your own schedule.';
end $$;
