-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0054 · give the server's own functions back their EXECUTE
--
-- 0048 was right. Postgres grants EXECUTE to PUBLIC by default, every
-- `revoke ... from anon, authenticated` in this repo had been a no-op, and
-- 100 of 103 functions were callable by anyone holding the publishable key.
-- Revoking from PUBLIC and re-granting the 69 client-API functions closed a
-- real hole and nothing here reopens it.
--
-- What it missed is that this app has a SECOND caller which also presents the
-- publishable key: its own server routes. The webhook, the signup recorder,
-- the Wikipedia cache writer and the rate limiter all run server-side with
-- the anon key, because the README's rule is that the service-role key is
-- never used. Those functions were classed as internal, so they were not
-- re-granted — and they had been riding the default PUBLIC grant since they
-- were written. They stopped working the moment 0048 was applied.
--
-- Observed, not theorised:
--
--   permission denied for function df20_apply_billing_event
--
-- returned to Stripe for a live £1 payment. The same revoke explains three
-- other things that looked unrelated: no failure row was ever written
-- (df20_log_billing_failure), signup signals recorded nothing for any account
-- (df20_record_signup), and rate limiting has been failing OPEN on every
-- surface, because lib/rateLimit.ts treats an error as "allow".
--
-- WHAT GUARDS THESE INSTEAD. The first six take a shared secret as their
-- first argument and compare it against df20_config before doing anything;
-- that comparison, not the grant, is the control, and it is the design these
-- were written to. The last two carry no secret and are restored to exactly
-- the reach they had before 0048: a caller can spend rate-limit budget, which
-- is a nuisance, where the alternative is no rate limiting at all.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── grant by NAME, not by signature ───────────────────────────────────────
-- Naming argument types here hard-codes a signature that a later migration
-- changes: 0056 replaces df20_apply_billing_event with an arity carrying the
-- amount, and a grant against the old one then fails on every re-run, taking
-- the whole bundle with it. Looking up whatever exists keeps this replayable
-- in any order, and covers the several arities of df20_cache_wikipedia too.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in (
         -- billing: the webhook writes premium and records its own failures
         'df20_apply_billing_event',
         'df20_revoke_premium',
         'df20_log_billing_failure',
         'df20_billing_profile',
         -- signup evidence, written by /api/auth/signup
         'df20_record_signup',
         -- the Wikipedia cache writer, every arity of it
         'df20_cache_wikipedia')
  loop
    execute 'grant execute on function ' || r.sig || ' to anon';
  end loop;
end $$;

-- ── the limiter itself. Denied, lib/rateLimit.ts allows everything. ───────
grant execute on function public.df20_rate_limit(text, text, int, int) to anon;
grant execute on function public.df20_external_budget(text) to anon;

notify pgrst, 'reload schema';
