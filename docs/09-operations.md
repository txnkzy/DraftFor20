# 09 · Operations

---

## Environments

| | |
|---|---|
| Production | https://www.draftfor20.com |
| Also serving | `draftfor20.vercel.app` |
| Vercel team | `draftfor20` (Pro) — **not** the personal team |
| Supabase ref | `jwnlmvjzeodfmngnhadq` |
| Repo | github.com/txnkzy/DraftFor20 |

**The canonical origin is `https://www.draftfor20.com`.** The apex
308-redirects to www at Cloudflare, so anything that must match **exactly** —
Supabase's redirect allowlist, Stripe's webhook endpoint and return URLs —
has to use the **www** form or it is handed a redirect it will not follow.

Cloudflare proxies to Vercel; `x-vercel-id` is present on responses.

---

## Environment variables

### Required
| Variable | What |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | Supabase project URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Publishable key — **public by design** |
| `NEXT_PUBLIC_SITE_URL` | Canonical origin, **inlined at build time** |

### Billing (only needed if working on payments)
`STRIPE_SECRET_KEY` · `STRIPE_PRICE_ID` · `STRIPE_WEEK_PRICE_ID` ·
`STRIPE_PASS_PRICE_ID` · `STRIPE_WEBHOOK_SECRET` · `DF20_BILLING_SECRET`

With none of these set the site still works — every entry point asks
`billingStatus()` first and the UI shows "payments coming soon" rather than
attempting a call that cannot succeed.

### Optional
`NEXT_PUBLIC_TURNSTILE_SITE_KEY` + `TURNSTILE_SECRET_KEY` (bot check) ·
`NEXT_PUBLIC_GA_ID` (analytics, dormant until set) · `DF20_DEV_SECRET`
(`/dev/cards`) · `WIKI_WRITE_SECRET` · `GITHUB_TOKEN` (admin changelog) ·
`SUPABASE_DB_URL` (operator-only, for `db:push`)

`.env.local` is gitignored and deliberately not in the repo. Copy values from
Vercel → Project → Settings → Environment Variables → Production.

> Vercel **redacts Secret-type values** on `vercel env pull`. You will get
> `[SENSITIVE]` rather than the key — that is correct behaviour, not a bug.

---

## Deploying

Pushing to `main` deploys to production through the GitHub↔Vercel
integration. There is no separate step.

Manual, when needed:

```bash
npx vercel deploy --prod --yes          # requires vercel link to the draftfor20 team
```

### If the CLI cannot see the project

```bash
npx vercel login
npx vercel link --scope draftfor20 --project draftfor20
```

**Do not run `vercel link --yes` without `--project`** — it silently
**creates a new empty project** when it cannot find one, which then sits in
the dashboard looking like the real thing with no deployments and no env
vars.

`.vercel/project.json` is gitignored, so the link goes missing on any fresh
clone. Re-running `vercel link` is the normal recovery, not a sign anything
broke.

---

## Runbook

### "Function not found in the schema cache"

A caller shipped without its migration. Check both halves:

```bash
npx vitest run lib/rpc-parity.test.ts     # is it defined in a migration at all?
```
```sql
select to_regprocedure('public.the_function(text,uuid)');  -- is it applied?
```

Then apply the migration. See [03 · Database](03-database.md).

### A card has no picture / the wrong picture

Open `/dev/cards`. See [05 · Categories and images](05-categories-and-images.md).

### Payments stopped working

1. `curl -s https://www.draftfor20.com/api/billing/config` — are the plans
   `available`, and do the prices match Stripe?
2. Check the Stripe dashboard's webhook deliveries. A 500 from our endpoint
   carries the reason in the response body.
3. Confirm the event list still includes `customer.subscription.deleted`.

### Premium needs granting by hand

Set `profiles.premium_until` to a future timestamp in the table editor. Every
gate reads that one column.

### A room is stuck

`expire_turn(code)` is idempotent and safe to call. `df20_abandon_stale()`
sweeps rooms whose players walked away.

---

## Health check

```sql
select public.df20_selfcheck(), public.df20_grant_check();
```

Expect roughly: *"ok — 89 functions, 24 tables and 13 columns present"* and
*"ok — 11 locked columns, anon shut out of profiles/templates, deck sealed"*.

Anything else means the database and the repo disagree.

---

## Support surface

- Contact is **email only**: `support@draftfor20.com`.
- **There is no phone number in this codebase, and one must not be added.**
  The support phone Stripe prints on receipts is a field in their dashboard,
  not a constant here. A number rendered by the site is a number someone
  expects an answer on.

See `DEPLOY.md` for the outstanding DNS and operator-identity items.
