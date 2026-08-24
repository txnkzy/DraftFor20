-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · v10 · a profile exists from signup, and a payment always lands
--
-- Both faces of the same bug: an account with no profiles row was invisible
-- to the admin console AND unfindable by the billing webhook, so a real
-- purchase took the money and granted nothing.
-- ═══════════════════════════════════════════════════════════════════════════

do $t$
declare
  NEW_ID uuid := 'd0000000-0000-4000-8000-00000000000a';
  ORPH   uuid := 'd0000000-0000-4000-8000-00000000000b';
  v jsonb; v_secret text; v_n int;
begin
  delete from public.profiles where id in (NEW_ID, ORPH);
  delete from auth.users where id in (NEW_ID, ORPH);
  delete from public.billing_events where event_id like 'v10_%';

  -- ── 1. signing up is enough to have a profile ──────────────────────────
  insert into auth.users (id, email, email_confirmed_at)
  values (NEW_ID, 'v10new@example.com', now());

  assert exists (select 1 from public.profiles where id = NEW_ID),
    'THE BUG: a new account still has no profile row';
  assert (select handle from public.profiles where id = NEW_ID) is not null,
    'a profile created by the trigger must carry a user id';
  raise notice 'PASS  a new account gets a profile, and a handle, at signup';

  -- ── 2. the admin console can therefore see them ────────────────────────
  -- (admin_list_profiles reads profiles; this is the query behind it)
  assert (select count(*) from public.profiles p join auth.users u on u.id = p.id
           where u.id = NEW_ID) = 1,
    'the account must be visible to the admin listing';
  raise notice 'PASS  the account is visible to the admin console';

  -- ── 3. a payment for a profile-less account still lands ────────────────
  -- Simulates the exact hole: an auth user with the profile row removed, the
  -- state every pre-fix signup was in when they reached checkout.
  insert into auth.users (id, email, email_confirmed_at)
  values (ORPH, 'v10orphan@example.com', now());
  delete from public.profiles where id = ORPH;
  assert not exists (select 1 from public.profiles where id = ORPH),
    'fixture: the orphan must genuinely have no profile';

  select value into v_secret from public.df20_config where key = 'billing_write_secret';
  v := public.df20_apply_billing_event(v_secret, 'v10_sub', ORPH, 'cus_v10', 'sub_v10',
                                       'active', now() + interval '31 days',
                                       'stripe_subscription', null);

  assert (v->>'matched')::boolean,
    'THE BUG: a paying account with no profile row was not matched, so the '
    'money was taken and nothing was granted';
  assert public.df20_premium_active(ORPH),
    'premium must actually be active afterwards';
  raise notice 'PASS  a purchase by a profile-less account creates the profile and grants premium';

  -- ── 4. a buyer who genuinely cannot be identified is RECORDED ──────────
  v := public.df20_apply_billing_event(v_secret, 'v10_ghost', null, 'cus_nobody', null,
                                       'active', now() + interval '31 days',
                                       'stripe_subscription', null);
  assert (v->>'matched')::boolean = false, 'an unknown customer cannot be matched';
  assert exists (select 1 from public.billing_events
                  where event_id = 'v10_ghost' and status = 'failed'),
    'an unmatched payment must be recorded as failed, not swallowed by a 200';
  raise notice 'PASS  an unidentifiable payment is recorded as a failure, not lost';

  -- ── cleanup ────────────────────────────────────────────────────────────
  delete from public.billing_events where event_id like 'v10_%';
  delete from public.profiles where id in (NEW_ID, ORPH);
  delete from auth.users where id in (NEW_ID, ORPH);

  raise notice '───────────────────────────────────────────────';
  raise notice 'v10 SUITE PASSED';
end $t$;
