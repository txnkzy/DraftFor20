-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0039 · the trust-signals view, for an admin to read
--
-- Everything behavioural is DERIVED at read time rather than stored: time to
-- verify, time to first action, how many accounts share an IP. Storing them
-- would mean a number that silently goes stale and, worse, a number that
-- looks like a fact. Computing on read means what an admin sees is what is
-- true when they look at it.
--
-- There is no score. Deliberately. A single number invites acting on the
-- number instead of reading the evidence, and the whole point of this table
-- is that no single signal is proof. `worth_review` exists as the mildest
-- possible nudge — it counts how many signals are present, and an admin who
-- disagrees with it can ignore it with no consequence.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.admin_user_signals(
  p_query text default null,
  p_filter text default 'all'
) returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_q text; v_f text;
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  v_q := lower(btrim(coalesce(p_query, '')));
  v_f := coalesce(nullif(btrim(lower(p_filter)), ''), 'all');

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select
        p.id,
        p.email,
        p.handle,
        p.created_at,
        coalesce(p.premium_until > now(), false) as premium,
        s.ip,
        s.user_agent,
        s.referrer,
        s.disposable,
        s.turnstile,

        -- how many OTHER accounts signed up from this address. Shared IPs are
        -- households and schools far more often than anything else, so this
        -- is a count to read, not a threshold to trip.
        case when s.ip is null then null else (
          select count(*) - 1 from public.signup_signals o where o.ip = s.ip
        ) end as ip_shared_with,

        -- confirmed in a couple of seconds is a password manager as often as
        -- it is a script; never confirmed is usually somebody who lost interest
        -- measured from profiles.created_at, not auth.users.created_at: the
        -- trigger creates them in the same transaction, and this keeps the
        -- function independent of the auth schema's shape
        (select extract(epoch from (u.email_confirmed_at - p.created_at))::int
           from auth.users u where u.id = p.id) as seconds_to_verify,

        -- the strongest single signal here, and still not proof: an account
        -- that confirmed an address and then never played anything
        -- least() ignores NULLs in Postgres, so an account with no players
        -- row and no hosted room yields NULL rather than a sentinel — and
        -- NULL is exactly what "never did anything" should read as. An
        -- earlier version used 'infinity' here and threw "cannot convert
        -- infinity to integer" on precisely the accounts this feature exists
        -- to surface.
        (select extract(epoch from (least(
                  (select min(pl.created_at) from public.players pl
                    where pl.profile_id = p.id),
                  (select min(r.created_at) from public.rooms r
                    where r.host_profile_id = p.id)
                ) - p.created_at))::int) as seconds_to_first_action,

        -- rate limiting the app already does elsewhere, surfaced here rather
        -- than left in a table nobody reads
        (select coalesce(sum(rl.count), 0) from public.rate_limits rl
          where rl.subject = p.id::text) as rate_limit_hits

      from public.profiles p
      left join public.signup_signals s on s.profile_id = p.id
      where (v_q = ''
             or lower(coalesce(p.email, '')) like '%' || v_q || '%'
             or lower(coalesce(p.handle, '')) like '%' || v_q || '%'
             or coalesce(s.ip, '') like '%' || v_q || '%')
      order by p.created_at desc
      limit 300
    ) x
    where case v_f
      when 'disposable' then (x.disposable is true)
      when 'shared_ip'  then coalesce(x.ip_shared_with, 0) > 0
      when 'no_action'  then x.seconds_to_first_action is null
      when 'unverified' then x.seconds_to_verify is null
      when 'fast_verify' then coalesce(x.seconds_to_verify, 99999) < 15
      else true
    end), '[]'::jsonb);
end $$;
grant execute on function public.admin_user_signals(text, text) to authenticated;
