-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0040 · absence of evidence is not evidence
--
-- 0039 flagged essentially every account, including the creator's. Two bugs,
-- both the same mistake in different clothes: treating MISSING DATA as a
-- SIGNAL.
--
--   1. NEGATIVE DURATIONS. seconds_to_verify is measured from
--      profiles.created_at, but 0032 backfilled profile rows for accounts
--      that already existed — so the profile row is NEWER than the
--      confirmation it is being compared against, and the difference comes
--      out negative. Negative then trivially satisfies "< 15 seconds", so the
--      oldest and most legitimate accounts in the system — the creator's
--      first of all — got flagged as "verified instantly". A negative
--      duration does not mean somebody verified before signing up. It means
--      the two timestamps are not comparable, which is not a signal at all.
--
--   2. NO SIGNUP RECORD AT ALL. Every account created before 0038 has no
--      signup_signals row. That is not suspicious, it is chronology. These
--      now report has_signup_record = false so the UI can say so plainly
--      instead of rendering blanks as findings.
--
-- The rule this restores: a signal has to be something we OBSERVED, not
-- something we failed to observe.
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
        p.id, p.email, p.handle, p.created_at,
        coalesce(p.premium_until > now(), false) as premium,
        s.ip, s.user_agent, s.referrer, s.disposable, s.turnstile,

        -- chronology, not suspicion
        (s.profile_id is not null) as has_signup_record,

        case when s.ip is null then null else (
          select count(*) - 1 from public.signup_signals o where o.ip = s.ip
        ) end as ip_shared_with,

        -- a negative gap means the profile row was backfilled after the
        -- confirmation it is measured against; report unknown, not "instant"
        (select case when v >= 0 then v end from (
           select extract(epoch from (u.email_confirmed_at - p.created_at))::int as v
             from auth.users u where u.id = p.id) q) as seconds_to_verify,

        (select case when v >= 0 then v end from (
           select extract(epoch from (least(
                    (select min(pl.created_at) from public.players pl
                      where pl.profile_id = p.id),
                    (select min(r.created_at) from public.rooms r
                      where r.host_profile_id = p.id)
                  ) - p.created_at))::int as v) q) as seconds_to_first_action,

        -- did they ever actually do anything, independent of WHEN. This is
        -- the honest version of "never played": a fact about activity, not a
        -- byproduct of two timestamps that may not line up.
        (exists (select 1 from public.players pl where pl.profile_id = p.id)
         or exists (select 1 from public.rooms r where r.host_profile_id = p.id))
          as has_played,

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
      when 'disposable'  then (x.disposable is true)
      when 'shared_ip'   then coalesce(x.ip_shared_with, 0) > 0
      when 'no_action'   then x.has_played = false
      when 'unverified'  then x.seconds_to_verify is null and x.has_signup_record
      when 'fast_verify' then coalesce(x.seconds_to_verify, 99999) < 15
      else true
    end), '[]'::jsonb);
end $$;
grant execute on function public.admin_user_signals(text, text) to authenticated;
