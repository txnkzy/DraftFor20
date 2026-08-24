-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0038 · signals for a human to read, not a verdict to act on
--
-- Every column here is EVIDENCE, not a judgement. A shared IP is a household,
-- a school, or a coffee shop far more often than it is a bot farm. A
-- disposable address is somebody who does not trust us yet. Verifying in four
-- seconds is a password manager. None of it proves anything on its own, and
-- nothing in this schema flags, suspends, or revokes: there is no status
-- column to set, deliberately, so no future code can quietly start acting on
-- a guess.
--
-- The rule this encodes: a false positive against a real player costs more
-- than a slow manual review.
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.signup_signals (
  profile_id  uuid primary key references public.profiles(id) on delete cascade,
  ip          text,
  user_agent  text,
  referrer    text,
  email_domain text,
  disposable  boolean not null default false,
  -- 'passed' | 'skipped' (no keys configured) | 'failed'
  turnstile   text not null default 'skipped',
  created_at  timestamptz not null default now()
);

create index if not exists signup_signals_ip_idx on public.signup_signals(ip) where ip is not null;
create index if not exists signup_signals_created_idx on public.signup_signals(created_at);

alter table public.signup_signals enable row level security;
revoke all on public.signup_signals from anon, authenticated;

comment on table public.signup_signals is
  'Signup-time evidence for manual admin review. Deliberately has no verdict '
  'or status column: nothing automated may act on these.';

-- ── the disposable-domain list ────────────────────────────────────────────
-- A signal, never a block. Somebody using a burner address is usually just
-- cautious, and the list is always out of date in both directions.
create table if not exists public.disposable_domains (
  domain text primary key
);
alter table public.disposable_domains enable row level security;
revoke all on public.disposable_domains from anon, authenticated;

insert into public.disposable_domains (domain) values
  ('mailinator.com'),('guerrillamail.com'),('guerrillamail.net'),('10minutemail.com'),
  ('tempmail.com'),('temp-mail.org'),('throwawaymail.com'),('yopmail.com'),
  ('sharklasers.com'),('grr.la'),('trashmail.com'),('getnada.com'),('dispostable.com'),
  ('maildrop.cc'),('fakeinbox.com'),('mailnesia.com'),('mytemp.email'),('moakt.com'),
  ('emailondeck.com'),('tempr.email'),('spamgourmet.com'),('mohmal.com'),
  ('burnermail.io'),('anonaddy.me'),('mailsac.com'),('inboxkitten.com'),
  ('tempmailo.com'),('minuteinbox.com'),('luxusmail.org'),('vomoto.com')
on conflict (domain) do nothing;

-- ── the write path ────────────────────────────────────────────────────────
-- Called by the signup route with the shared secret, same posture as the
-- billing and wiki writers: no service-role key anywhere in this project.
create or replace function public.df20_record_signup(
  p_secret text, p_profile_id uuid, p_ip text, p_user_agent text,
  p_referrer text, p_email text, p_turnstile text
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_expected text; v_domain text; v_disposable boolean;
begin
  select value into v_expected from public.df20_config where key = 'wiki_write_secret';
  if v_expected is null or p_secret is null or p_secret <> v_expected then
    raise exception 'DF20_NOT_AUTHORISED';
  end if;
  if p_profile_id is null then return jsonb_build_object('recorded', false); end if;

  v_domain := lower(split_part(coalesce(p_email, ''), '@', 2));
  v_disposable := v_domain <> ''
    and exists (select 1 from public.disposable_domains d where d.domain = v_domain);

  insert into public.signup_signals
    (profile_id, ip, user_agent, referrer, email_domain, disposable, turnstile)
  values (p_profile_id,
          nullif(left(coalesce(p_ip, ''), 45), ''),
          nullif(left(coalesce(p_user_agent, ''), 400), ''),
          nullif(left(coalesce(p_referrer, ''), 300), ''),
          nullif(v_domain, ''),
          v_disposable,
          case when p_turnstile in ('passed','failed','skipped') then p_turnstile else 'skipped' end)
  on conflict (profile_id) do nothing;

  return jsonb_build_object('recorded', true, 'disposable', v_disposable);
end $$;
revoke all on function public.df20_record_signup(text,uuid,text,text,text,text,text) from public;
revoke all on function public.df20_record_signup(text,uuid,text,text,text,text,text) from anon, authenticated;
