# 08 · Testing and CI

---

## Commands

```bash
npm run dev             # dev server
npm run build           # production build — the same one Vercel runs
npx vitest run          # the unit suite
npx eslint .
npm run check:migrations
```

---

## The unit suite

Fast, no network, no database. Run it before every commit.

| File | Guards |
|---|---|
| `lib/game/rules.test.ts` | The money maths — reserve, max legal bid, min raise, broke |
| `lib/plans.test.ts` | The price ladder: modes, ordering, per-day monotonicity, the Stripe fee floor |
| `lib/username.test.ts` | Username shape rules and the reserved list |
| `lib/rpc-parity.test.ts` | **Every `.rpc()` the app calls is defined by a migration, and every migration is registered in the bundle** |
| `lib/billing/countdown.test.ts` | Pass expiry maths |
| `lib/category/chain.test.ts` | Category resolution order |
| `lib/images/card.test.ts`, `sources.test.ts` | Generated cards, image source behaviour |
| `lib/demo/replay.test.ts` | The landing page's scripted draft |
| `lib/changelog/categorize.test.ts` | Admin changelog grouping |

### `rpc-parity` earns its place

plpgsql does not validate function bodies at creation and PostgREST only
fails at call time, so **a caller shipped without its function is invisible
until a user clicks the button**.

On 20 Sep three were live in the app and absent from the database at once.
The worst was `df20_name_squash` — `join_room` called it, so **nobody could
join a room**, and the only symptom was an error in one person's browser.

The test also caught an unregistered migration within a minute of being
written, and found `df20_solo_quota`, which existed *only* in the database:
`0067` added the column, indexed it, and asserted the function existed — but
never created it. A rebuild from the bundle would have had the column, the
index, and nothing to answer the question Quick Play asks on mount.

**What it cannot do** is know whether a migration was *applied*. Only
`df20_selfcheck()` can, and it runs in the bundle footer.

---

## Seed tools, not tests

These are `it.runIf(...)` generators that regenerate migrations. They hit the
network and take minutes. They do not run in CI.

```bash
SEED=1 npx vitest run lib/espn.seed.test.ts     # NFL/NBA rosters
BRANDS=1 npx vitest run lib/brands.seed.test.ts # fast food, candy
LIB=1   npx vitest run lib/library.seed.test.ts # general library repair
```

`*.live.test.ts` files also hit the network and are opt-in.

> Historical trap: a module-scope `createClient` in a seed tool broke the
> ordinary vitest suite **even while skipped**. Build clients lazily.

---

## SQL tests

Paste into the Supabase SQL editor, or run through the local harness
(`supabase/tests/local-harness.md`).

| File | Asserts |
|---|---|
| `full_draft.sql` | The game loop and money rules, 8 assertions |
| `v3_categories.sql` | Categories, the **leak test**, the auth gate — 13 assertions |
| `v6_premium.sql` | Premium gates, OBS token, blind vote, watermark both ways, billing |
| `v7_scouting_timer.sql` | No-limit clock, scouting maths, content mode, console |
| `v8_images.sql` | Portraits are present **and distinct** |
| `v12_allow_broke.sql` | The broke path and the reserve toggle |
| `race.sh` | Two clients bidding simultaneously |

**The leak test is the important one.** It plants a sentinel item and asserts
it appears in no create response, no `get_setup_state`, and no public
snapshot until dealt.

---

## The in-database self-checks

Run these against any database you are unsure about — they are faster than
reading anything:

```sql
select public.df20_selfcheck();          -- what must EXIST
select public.df20_grant_check();        -- what must NOT be reachable
select public.df20_selfcheck_usernames();
select public.df20_selfcheck_lineups();
```

---

## CI

`.github/workflows/checks.yml` runs on every push to `main` and every PR:
**migration numbering, lint, and the same `npm run build` Vercel runs.**

Two people work on this repo and neither can be expected to remember a
pre-push ritual — and the collisions that prompted this were invisible to
git, because two files claiming `0057` merge perfectly cleanly.

Numbering and build are **hard gates**. **Lint is reported but does not fail
the run**, because two `setState`-in-effect errors in `CardImage.tsx` and
`app/dev/cards` predate the workflow, and a check that is red the day it
lands is one everybody learns to scroll past.

> Fix those two and make lint a gate. It is the cheapest outstanding
> improvement in the repo.

---

## What is verified by a human, and what is not

Manual browser verification through the Chrome DevTools MCP is the standing
expectation before committing UI work — several bugs in this codebase passed
every automated check and were caught only by looking.

Still unverified by a human: whether the raise cue is audible on desktop, and
whether the landing scroll sequence feels right. The automation browser runs
with autoplay disabled and rAF paused.
