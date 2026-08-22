# DraftFor20

A real-time, two-player auction draft built to be filmed. Two people split a
fixed bankroll across the same list of category slots, bidding against each
other under a server-authoritative countdown. When every slot is filled, the
app produces a vertical 1080×1920 results card ready to post.

Next.js (App Router) · TypeScript · Tailwind v4 · Supabase (Postgres, Realtime,
Auth) · deploys to Vercel.

---

## Setup

### 1. Environment

```bash
cp .env.example .env.local
```

Fill in from **Supabase → Project Settings → API**:

| Variable | Where |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | Project URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | `anon` / publishable key |

The service role key is **not** used by this app and must not be added. Row
level security is on for every table with no anon policies, so the anon key
grants no direct table access at all.

### 2. Schema

On a **fresh database**, paste these into the Supabase **SQL Editor** in order:

```
supabase/migrations/0001_schema.sql      tables, constraints, indexes
supabase/migrations/0002_rls.sql         deny-all RLS + host-account policies
supabase/migrations/0003_pool.sql        the starting item pool
supabase/migrations/0004_functions.sql   the money rules and the state machine
supabase/migrations/0005_rpc.sql         the client API
supabase/migrations/0006_realtime.sql    notice only, verifies realtime.send()
supabase/migrations/0007_cron.sql        OPTIONAL: expiry backstop + retention
```

Then paste **`supabase/APPLY_V7.sql`**, which carries everything from `0008`
to `0025` — categories, the sign-in gate, profiles and premium, the OBS and
audience-vote surface, the billing writes, the scouting report, the
no-limit clock, room content modes and the console. It is additive, safe to re-run
from any partial state, and ends by calling `df20_selfcheck()`, which asserts
that every function, table and column the app calls at runtime actually
exists. **If that raises, stop and read what it lists** — plpgsql does not
validate function bodies at creation, so a half-applied bundle otherwise
reports success and fails later on a real click.

On an **existing v5 or v6 database**, `APPLY_V7.sql` is still the thing to paste;
the earlier files in it are no-ops.

Rebuild the bundle after editing any migration:

```bash
./supabase/build-bundle.sh
```

`0007` needs `pg_cron`. If it is unavailable the file degrades to a notice and
the app is still correct — expiry is client-driven and idempotent. The
retention job it schedules is what makes the 90-day deletion promise in the
privacy policy true, so if you skip it, run
`select public.df20_purge_old_rooms();` on your own schedule.

### 3. Host sign-in (optional)

Only needed for saved templates and card branding. In **Auth → URL
Configuration** set Site URL to your origin and add `<origin>/auth/callback` as
a redirect URL. Playing never requires an account.

### 4. Before launch

Set the three constants in `lib/site.ts` — operator name, contact email and
governing-law jurisdiction. The privacy policy and terms reference them.

```bash
npm install
npm run dev
```

---

## How the game works

`N` categories means `2N` roster spots, so `2N` lots.

1. **Contest.** The player whose turn it is nominates an item for the current
   category and sets an opening bid. The opponent raises or passes under the
   clock. Ping-pong until someone passes, times out, or is blocked by the
   reserve wall. The winner pays their bid.
2. **Consolation.** The loser then fills the *same* category with an item of
   their own choosing at exactly the minimum bid, uncontested.
3. The slot pointer advances only once both rosters have that category filled,
   and the contest turn alternates.

Both players always finish full, so **leftover cash is the entire scoreboard**.
There is no algorithmic winner; the results screen has a one-tap human vote.

### The money rules

```
open(P)          = categories P has not filled, INCLUDING the one being bid on
reserve(P)       = min_bid × (open(P) − 1)
max_legal_bid(P) = bankroll(P) − reserve(P)
```

**Hard cap:** a bid can never exceed the bankroll. **Reserve rule:** a player
must always keep the minimum bid for every other slot they still owe.

In an underfunded room (`bankroll < min_bid × slots`) the raw formula goes
negative, which would lock the player out of every legal action. It degrades
instead: while they can still afford one minimum bid they are capped at exactly
that, and below it they are **broke** and Force-or-Take governs their fills.

**Force-or-Take** prompts the other player explicitly, with only the moves the
server will actually accept:

| Their situation | Options |
|---|---|
| Still needs this category, can afford it | Give it · Take it |
| Already filled this category | Give it · Leave them empty |
| Still needs it but is broke too | Give it (the only legal move) |

**Bust** is a safety net checked at the end: spend over the starting bankroll, a
negative balance, or an unfilled slot. Only the third is reachable, and only
through Force-or-Take.

### Why the client cannot cheat

Every mutating RPC is `SECURITY DEFINER` and does four things in order:

1. `SELECT … FOR UPDATE` on the room row, so all actions in a room serialize.
2. Authenticates from the session token. A client-supplied player id is never
   trusted.
3. Re-reads bankroll, slot and lot state from the tables and re-validates the
   hard cap and reserve rule against what it just read.
4. Commits, bumps `rooms.version`, and broadcasts.

A `turn_seq` optimistic check is the second guard: a bid built against a board
that has since moved is rejected as `DF20_STALE`. Bankroll is debited only
inside `df20_resolve_lot`, in the same transaction that inserts the roster row.

The countdown is `lots.turn_expires_at`. `get_room_state` returns `server_now`
so the client can correct for clock skew; a client that stalls its own JS
cannot buy time, because late bids are refused server-side regardless of what
the browser rendered.

---

## Tests

```bash
npx vitest run                                  # money rules
psql "$DB" -f supabase/tests/full_draft.sql     # full drafts through the real RPCs
psql "$DB" -f supabase/tests/v3_categories.sql  # categories, setup links, leak test
psql "$DB" -f supabase/tests/v6_premium.sql     # premium gates, votes, watermark, billing
psql "$DB" -f supabase/tests/v7_scouting_timer.sql # no-limit clock, scouting maths, console
./supabase/tests/race.sh "$DB"                  # two clients bidding at once
```

`full_draft.sql` plays a funded draft and an underfunded one end to end and
attacks every rejection path (over-reserve, over-bankroll, stale sequence,
off-turn, expired, too-low, third player). `race.sh` proves that of two
simultaneous bids exactly one commits, and that spend + leftover still equals
the starting bankroll afterwards. Both clean up after themselves.

`v6_premium.sql` is the one to read if you change anything about access. It
asserts that the OBS link is refused without premium, that an admin grant
unlocks exactly what a subscription unlocks, that a viewer is not told the
tally until they have voted, that one browser gets one vote, that a replayed
Stripe event cannot extend a pass twice, and — the one that matters most —
that **a premium account which has not touched its settings still exports a
watermarked card**.

To run all of it with no Supabase project, see
[`supabase/tests/local-harness.md`](supabase/tests/local-harness.md).

---

## Premium, and how access is decided

There is exactly **one** rule, in one place: an account has premium while
`profiles.premium_until` is in the future. `df20_premium_active(uid)` is that
comparison and nothing else. A Stripe subscription, a 24-hour Game Night Pass
and a hand-typed grant all write that same column, so every gate in the app —
the Content tab, the OBS link, export branding — treats them identically and
none of them needs to know which one it is looking at.

`premium_source` records which it was (`stripe_subscription`, `game_night_pass`,
`admin_grant`, or null) for display only. Nothing gates on it.

None of this is a client-side flag. Every premium action is refused again by
the RPC behind it, because the anon key is public and every RPC is reachable
with `curl`.

### Granting somebody premium by hand

Supabase → **Table Editor** → `profiles` → find the row by `email`, then set:

| Column | Value |
|---|---|
| `premium_until` | any future timestamp, e.g. `2027-01-01 00:00:00+00` |
| `premium_source` | `admin_grant` |
| `subscription_status` | `admin` (cosmetic; shown on the profile page) |

That is the whole procedure. **No other field, and no other code path, is
involved** — the next page load unlocks the Content tab, the OBS browser
source and the export-card branding for that account. To take it away, set
`premium_until` to null.

The same thing in SQL:

```sql
update public.profiles
   set premium_until = now() + interval '30 days',
       premium_source = 'admin_grant',
       subscription_status = 'admin'
 where email = 'them@example.com';
```

### The console at `/admin`

Four tabs, covering only what this app knows:

| Tab | What |
|---|---|
| **Users** | every account, searchable and sortable: email, joined, premium status and source, drafts hosted, drafts played, last seat. Grant or revoke premium inline. |
| **Library** | submissions from hosts waiting for review, with the items to read and approve/reject; plus everything already on the public shelf, with remove. |
| **Activity** | rooms created (today / week / all time, and a fourteen-day chart), where the picks came from, Standard against Content Creator, how long a draft actually takes, library and audience counts. |
| **Events** | every Stripe webhook processed, and every one that failed. |

Revenue, MRR and churn are **not** here — that is Stripe's dashboard, linked
from the header. Query performance and table contents are not here either —
that is Supabase's, also linked. A second copy of a number is a second number
to be wrong.

**It is closed to everyone until you open it**: `df20_is_admin()` reads a
comma-separated list of uuids from `df20_config.admin_user_ids`, and no
migration creates that row. With the row absent, the page renders a shrug for
every visitor, including you.

To open it, find your uuid (`select id from auth.users where email = '…'`) and:

```sql
insert into public.df20_config (key, value)
values ('admin_user_ids', 'your-uuid-here')
on conflict (key) do update set value = excluded.value;
```

Several admins is the same row, comma separated. This is deliberately not a
role system — there is one privilege, it is held by a list of uuids you type
yourself, and the table-editor route above keeps working whether or not you
ever use the page.

### Opting a category into the public library

A host who built their own list is offered, after the draft, the chance to put
it on the public shelf. That used to publish immediately. It now creates a
**submission**, which sits in the console's Library tab until a human approves
it. The real-name heuristics still run first and still refuse anything that
looks like somebody's friends — the review is the second gate, not the first.

---

## The clock

A room's `timer_seconds` is the counter-bid window. Presets are 10/15/20/30,
any value from 3 to 300 can be typed, and **0 means no limit**: the card stays
open until somebody raises or passes.

No-limit is not a special case bolted onto the state machine. `turn_expires_at`
is simply null, and everything downstream already treats null correctly — a bid
is never late, the idempotent `expire_turn` no-ops, the `pg_cron` sweeper skips
the room, and the browser schedules nothing. `supabase/tests/v7_scouting_timer.sql`
asserts each of those four.

---

## The Scouting Report

Four numbers on the profile describing *how* somebody drafts, aggregated from
data the game already records — no new tracking:

| Metric | From | Means |
|---|---|---|
| **Sniper** | `roster_entries.price_cents = rooms.min_bid_cents` | share of cards bought at the minimum |
| **Whale** | spend ÷ cards bought, averaged per draft | what you pay when you actually pay |
| **Instigator** | `bid_events.action = 'raise'` on lots you did not win | raises that only pushed the price up for somebody else |
| **Hoarder** | `players.bankroll_cents` at completion | what you tend to have left |

Gifted cards are excluded from Sniper and Whale: a card handed to you for
nothing is not a purchase and says nothing about how you bid.

The four are normalised to 0–100 so they can share one shape — Whale pins 100
at twice the even split (bankroll ÷ roster), Instigator at five losing raises
per draft — and the real figures are printed underneath in their own units.
The title above the chart needs two finished drafts, a leading axis over 40,
and eight points of daylight to the next one.

**Free accounts read the last five drafts; premium reads all of them.** That
window is applied inside `my_scouting_report()`, not in the UI.

---

## Payments

**The site is fully functional with no Stripe account at all.** Every billing
entry point asks first and degrades to a "payments coming soon" panel rather
than attempting a call that cannot succeed. Nothing free is gated behind
billing being configured.

When you have keys, set these on the server (Vercel → Settings → Environment
Variables). They are read server-side only and must never be committed:

| Variable | What |
|---|---|
| `STRIPE_SECRET_KEY` | `sk_live_…` / `sk_test_…` |
| `STRIPE_PRICE_ID` | price id for the $5/month subscription |
| `STRIPE_PASS_PRICE_ID` | price id for the one-off Game Night Pass |
| `STRIPE_WEBHOOK_SECRET` | `whsec_…` from the webhook endpoint |
| `DF20_BILLING_SECRET` | see below |
| `NEXT_PUBLIC_SITE_URL` | your origin, so Checkout can redirect back |

`DF20_BILLING_SECRET` is how the webhook writes to Postgres without a
service-role key (which this app still does not use). `0019_billing.sql`
generates one; copy it out:

```sql
select value from public.df20_config where key = 'billing_write_secret';
```

It authenticates to one function that can only move a subscription date on a
profile. Leaking it costs a wrongly-granted month, not a database.

Point the Stripe webhook at `https://<your-origin>/api/billing/webhook` and
subscribe to `checkout.session.completed`,
`customer.subscription.created/updated/deleted`, `invoice.paid` and
`invoice.payment_failed`.

**The webhook is the only thing that grants premium.** The browser is never
believed about a payment: the success page is just a URL, and checkout happens
before any money moves.

### What happens today, with no keys set

1. A free user opens the Content tab. It is there, padlocked, with the upgrade
   panel inside it — not hidden.
2. The panel asks `GET /api/billing/config` first. With no keys that answers
   `{ configured: false }`.
3. It renders **"payments coming soon"** and does not draw a checkout button,
   so there is nothing to click and no Stripe call is attempted.
4. If something calls `POST /api/billing/checkout` anyway, it answers `200`
   with `{ configured: false }` — not a 500 and not an exception.
5. `POST /api/billing/webhook` answers `503` with one sentence.
6. Everything free is untouched: the shelf, drafts, results, the export card
   and the audience vote all work exactly as before.

Until then, `admin_grant` above is how anyone gets premium.

---

## Routes

| Route | |
|---|---|
| `/` | landing; the hero is the real board replaying a real bid war |
| `/new` | room creation: categories, bankroll, minimum bid, clock, branding |
| `/join` | code entry |
| `/room/[code]` | lobby → live draft → results, one page |
| `/results/[code]` | standalone final board, export card and the vote link |
| `/vote/[id]` | audience vote: blind pick, then the live tally, then the CTA |
| `/judge/[code]` | permanent redirect to `/vote/[code]`; old links keep working |
| `/obs/[token]` | read-only transparent board for an OBS Browser Source |
| `/api/share-card/[code]` | 1080×1920 PNG, also the OG image (`?dl=1` to save) |
| `/api/vote/[id]` | one vote per browser, enforced by an httpOnly cookie |
| `/api/billing/*` | config, checkout, webhook, portal — all inert with no keys |
| `/profile` | drafts, record, badges, saved decks, plan |
| `/admin` | console: users, library queue, activity, webhook events |
| `/host`, `/login` | optional host account: templates and branding |
| `/privacy`, `/terms` | real policies for this app specifically |

## Design

Palette is a dark spruce ground with two player identities and one alarm
colour: `#0D1917` board, `#152521` panel, `#5F7B73` sage, `#E8E3D3` bone
(player 2), `#E7A83A` bulb (player 1), `#C8382C` klaxon. Type is Archivo
Expanded for display, Karla for body, Azeret Mono for every number.

The signature element is **the Rail** — one bar per player showing spent, the
money you may legally commit right now, and a hatched reserved zone you cannot
cross. Hitting the wall flashes the hatch instead of throwing an error, so the
reserve rule is something you watch happen. The only orchestrated animation is
**the lock**, when a won item drops into a roster slot.
