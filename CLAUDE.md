# DraftFor20 — project handoff

A real-time, two-player auction draft built to be filmed. Two people split a
fixed bankroll across a flat roster of N picks, bidding against each other
under a server-authoritative countdown. When the money runs out the app
produces a vertical 1080×1920 results card.

**Live:** https://draftfor20.vercel.app
**Supabase project ref:** `jwnlmvjzeodfmngnhadq`
**Stack:** Next.js 16 (App Router) · React 19 · TypeScript · Tailwind v4 ·
Supabase (Postgres + Realtime + Auth) · Vercel

---

## The two rules that govern everything

**1. Money validation is the product.** Every bid is re-validated inside
Postgres against freshly-read state. No client check is trusted, nothing is a
float — all money is integer cents.

**2. Neither player may ever see an undealt item.** The deck is a shuffled,
server-side list. Items reach a client one card at a time, after being dealt,
and never before.

Both are enforced in the database, not the UI, because the anon key is public
and every RPC is reachable with `curl`.

---

## How the game works

`N` roster slots per player means `2N` picks, so `2N` lots.

1. The server deals a card from the room's hidden deck and opens it at the
   minimum bid, with the **opener** (alternating each card) holding it.
2. The opener chooses **Take at $1** or **Give it away** (lands free on the
   opponent's roster; costs one of their limited gives).
3. On Take, the opponent raises or passes and the existing ping-pong runs.
4. Draft ends when both rosters are full. No algorithmic winner — leftover
   cash is the scoreboard, plus a one-tap human vote.

### The money rules

```
open(P)          = picks P still owes, INCLUDING the one being bid on
reserve(P)       = min_bid × (open(P) − 1)
max_legal_bid(P) = bankroll(P) − reserve(P)
```

**Hard cap:** never more than the bankroll. **Reserve rule:** always keep the
minimum bid for every other slot you still owe.

In an underfunded room the raw formula goes negative and would deadlock the
player out of every action, so it degrades: capped at exactly one minimum bid
while solvent, then **broke**, at which point Give/Take governs their fills.

**`gives_per_player` defaults to 2.** Without a cap, both players dumping every
card is a stable equilibrium that ends the draft $20 vs $20 with zero bids
placed. Do not remove this cap without replacing it with something.

---

## Architecture

Every mutating RPC does the same four things:

1. `SELECT … FOR UPDATE` on the room row, so actions in a room strictly serialize
2. Authenticate from the session token — never a client-supplied player id
3. Re-read bankroll/deck/lot state and re-validate
4. Commit, bump `rooms.version`, broadcast

A `turn_seq` optimistic check is the second guard: a bid built against a board
that has since moved is rejected as `DF20_STALE`.

**RLS is deny-all with no anon policies on every game table.** Clients cannot
read any table directly; the only read path is `df20_public_state()`, a
`SECURITY DEFINER` function that strips `players.session_token` and touches
`room_deck` only to `count(*)` unrevealed rows.

**The countdown is `lots.turn_expires_at`.** `get_room_state` returns
`server_now` so clients correct for clock skew. A client that stalls its own JS
cannot buy time. It is **null when `timer_seconds` is 0**, which is how a
no-limit room works — see the clock section in the README.

**The audience tally is pushed, not polled.** `cast_audience_vote` calls
`realtime.send()` inside the same transaction that records the vote, on
`room:<uuid>` with event `audience` and the tally itself as the payload — so
subscribers receive the numbers rather than a hint to go and ask. A voter is
subscribed only *after* voting, because the payload is the answer the blind
rule makes them earn.

### Category sources

| Source | Free? | How |
|---|---|---|
| `library` | yes | 22 premade categories, 1,227 items |
| `wikipedia` | **account** | trigram match, then parse a "List of …" article |
| `manual` | **account** | third party builds the list via a setup link |
| `saved` | **account** | a deck the host kept from an earlier draft, reshuffled |

A saved deck returns names and counts only, never items — the host of a
handoff room has never seen that list and reusing it must not be the thing
that shows it to them.

Fuzzy matching is `pg_trgm` at **0.5**, plus a token-overlap guard: two names
must share a *meaningful* word. Without that guard "nhl teams" matched NFL
Teams at 0.538, because the shared word "teams" is most of a short string.

---

## Premium, in one sentence

An account has premium while `profiles.premium_until` is in the future.
`df20_premium_active(uid)` is that comparison and nothing else. A Stripe
subscription, a 24-hour Game Night Pass and an admin grant all write that same
column, so no gate anywhere can tell them apart — which is the point. Set the
column by hand in the table editor and every premium feature unlocks with no
other code path involved. `premium_source` is for display only; nothing gates
on it.

| Surface | Gate |
|---|---|
| Content Creator rooms | premium, chosen at creation and never changed |
| Record mode, OBS link, live tally | premium |
| OBS token minting | premium, **checked in the RPC**, not the UI |
| Scouting report beyond the last 5 drafts | premium, windowed in the RPC |
| Export card branding | premium, and opt-out only (see below) |
| Custom categories | still sign-in, not premium — `PREMIUM_GATES` in `lib/premium.ts` |
| Audience vote link | free, deliberately: it is the acquisition loop |

**The watermark is opt-out, and that is a product decision, not an oversight.**
`df20_export_style(code)` resolves it server-side from the room's host profile.
Watermark off requires all three of: an active premium account, that account
owning the room, and that account having explicitly set the toggle. Anything
else — free, lapsed, premium-but-untouched, or someone editing the URL — is the
standard watermarked card. There is no parameter that turns it off; the PNG
route takes a room code and nothing else. `v6_premium.sql` asserts this both
ways round.

---

## The two room layouts

`rooms.content_mode` is `standard` or `creator`, set by `create_room` and
never changed. It is not a skin:

| | Standard | Content Creator |
|---|---|---|
| shape | three-column desktop grid | one 9:16 column |
| rosters | left and right of the card | stacked, top third and bottom third |
| card, bid, clock | upper middle, in a panel | dead centre, big |
| the Rail | under both names | not shown |
| bid history | under the board | not shown |
| reserved space | none | right 200px and bottom 150px, for TikTok's own buttons |
| ground | `--color-board` | pure black |
| controls | under the board | in the rail beside the frame, outside the 9:16 crop |

`VerticalStage` is the frame, and the same component draws Record Mode (same
stage, fullscreen, black) and the OBS browser source (same stage, transparent
ground). One layout, three grounds.

**Why the old in-lobby Content tab was undiscoverable:** it rendered only
after `state.room.status !== 'lobby'`, because it sat below the lobby early
return — so it appeared only once a draft had started, and starting one needs
a second player. A solo host could not reach it at all, and the moment you
actually want an OBS link is while you are waiting for the other player. It
also had no entry point anywhere else in the app. The mode being chosen at
creation removes both problems: there is nothing to find.

---

## Hard-won gotchas — read before changing anything

**plpgsql does not validate function bodies at creation.** A function can be
created referencing one that doesn't exist; it only fails when called. This bit
twice. `df20_selfcheck()` now asserts 73 functions, 21 tables and 8 columns exist and
runs at the end of the SQL bundle. **Keep it updated when you add an RPC.**

**Never split a caller from its dependency across migration files.** The
`df20_clean_logo_url` outage was exactly this: `create_room` in 0010 calling a
function defined in 0008, which was never applied.

**Supabase's SQL editor runs statements individually.** A failure partway
through does not roll back what came before, so migrations must be re-runnable
from any partial state.

**`DROP TABLE … CASCADE` drops the foreign key but leaves the child table.** A
later `create table if not exists` then skips it, leaving orphaned rows that
are invisible to any query joining through the parent.

**PKCE verifiers live in the browser.** `createBrowserClient` stores the code
verifier client-side, so `exchangeCodeForSession` must run in the browser.
`app/auth/callback/` is a client page for this reason — a route handler could
never succeed.

**Satori only accepts `display: flex | contents | none`.** `display: block` in
the share-card route fails the entire render. Every node needs an explicit
display, and one text child.

**`df20_public_state` returns `to_jsonb(rooms)`, so every column you add to
that table lands in both players' browsers.** It now strips `setup_token`,
`setup_result_token` and `obs_token` by name. Adding another token column
without adding it to that list hands it out automatically.

**`join_room` assigns the first FREE seat, not seat 2.** A setup-link room has
no players at all until someone joins, so hardcoding seat 2 makes the first
two joiners collide on `players_room_id_seat_key`. 0017 rewrites this function;
it was rewritten from the 0005 version by mistake first, and `v3_categories.sql`
caught it.

**`get diagnostics x = row_count` needs an int, not a boolean.** plpgsql will
create the function anyway and fail at call time. The billing idempotency
check had this; `v6_premium.sql` caught it.

**A stage rendered at true size and scaled cannot size its own parent.**
`VerticalStage` lays out at 1080×1920 and scales to fit, measured with a
ResizeObserver — so the measured box has to be `position: relative;
overflow: hidden` with the stage absolutely positioned inside it. Without
that the 1920px child grows the parent, the measurement is circular and the
frame overflows the viewport.

**A percentage height needs a definite parent.** `VerticalStage` measures its
box to work out its scale, so a wrapper sized by `min-height` plus `flex`
gives it `clientHeight === 0` and it draws nothing at all — a black rectangle
that looks like a broken board. Give the wrapper a real height
(`h-[62dvh] lg:h-dvh`), never `min-h-*`.

**PostgREST runs `stable` and `immutable` functions in a READ ONLY
transaction.** `my_scouting_report()` was written with a temp table first;
creating one would have failed the moment it was called over HTTP even though
it worked fine in psql. Aggregate in a CTE instead, or mark the function
volatile and mean it.

**`get diagnostics x = row_count` needs an int, not a boolean.** Never put email on a hot
path. Sign-in is password-based for exactly this reason; the magic link is a
fallback with `shouldCreateUser: false`.

---

## Commands

```bash
npm run dev            # dev server
npm run build          # production build
npx vitest run         # 23 unit tests, the money maths
npx eslint .
npx vercel deploy --prod --yes
```

### Database

`supabase/APPLY_V7.sql` is the current bundle — `0008`–`0025`, additive,
re-runnable, ends with `df20_selfcheck()`. Paste into the Supabase SQL Editor.

Rebuild it after editing any migration:

```bash
./supabase/build-bundle.sh
```

`0017`–`0020` are the v6 additions: profiles and premium, saved decks, the OBS
and audience-vote surface, billing writes and the admin grant. `0021`–`0025`
are v7: the no-limit clock, the scouting report, room content modes, the
console and the moderation queue, then the selfcheck. **Keep `df20_selfcheck()` updated when you add an RPC** — it now
asserts columns as well as functions and tables, including that
`profiles.export_watermark` still defaults to true.

### Tests

```
supabase/tests/full_draft.sql      8 assertions, the game loop and money rules
supabase/tests/v3_categories.sql  13 assertions, categories, leak test, auth gate
supabase/tests/v6_premium.sql      premium gates, OBS token, blind vote, watermark, billing
supabase/tests/v7_scouting_timer.sql  no-limit clock, scouting maths, content mode, console
supabase/tests/race.sh             two clients bidding simultaneously
supabase/tests/local-harness.md    run all of it with no Supabase project
```

The **leak test** is the important one: it plants a sentinel item and asserts it
appears in no create response, no `get_setup_state`, and no public snapshot
until dealt.

---

## Design

Palette (`app/globals.css`), semantic not decorative:

| Token | Hex | Means |
|---|---|---|
| `board` | `#14161C` | page ground |
| `surface` | `#1D2029` | cards, rails, rows |
| `coral` | `#FF5A36` | **tension only** — live bid, running timer, your turn |
| `gold` | `#F5B942` | **money only** |
| `teal` | `#2DD4BF` | resolved, passed, free |
| `ink` | `#E8E6E1` | text |
| `muted` | `#9C978E` | secondary text |

Players are told apart by gold vs off-white markers, never by coral or teal —
if identity used those, the palette would stop meaning anything.

Type: **Bricolage Grotesque** display, **Instrument Sans** body.

The signature element is **the Rail**: spent / available / hatched-reserved.
Hitting the reserve wall flashes the hatch rather than throwing a toast.

Framer Motion is imported **only** by the landing scroll sequence, via
`next/dynamic` with `ssr: false`. Keep it out of the room bundle.

---

## Known gaps

- **Two things were never verified by a human**: whether the raise cue is
  audible on desktop, and whether the scroll sequence feels right. The
  automation browser runs with autoplay disabled and rAF paused.
- **The signed-in gated path is unproven end to end.** Rejection cases are
  verified; a real authenticated success is not, because email confirmation
  blocked creating a test account.
- **`lib/site.ts`** contact email is `support@draftfor20.com`, but **that
  mailbox does not exist yet** — no MX record has been created for
  `draftfor20.com`, and mail to it bounces. Operator name and jurisdiction are
  still placeholders. The privacy policy, terms and footer reference all of
  these. Setup steps are in `DEPLOY.md`.
- **Support is email-only and there is no phone number in this codebase.** The
  support phone Stripe prints on receipts is a field in their dashboard, not a
  constant here. Do not add one back — a number rendered by the site is a
  number someone expects an answer on. See `DEPLOY.md`.
- **The site's canonical domain is unsettled.** `SITE_URL` falls back to
  `draftfor20.app`, the deploy is `draftfor20.vercel.app`, and the support
  address is on `draftfor20.com`. Pick one and make the other two follow.
- **Stripe has never run.** The framework is complete and the no-keys path is
  verified end to end, but no real checkout, webhook or subscription lifecycle
  has been exercised against Stripe. `periodEnd()` in the webhook reads the
  period end from both the subscription and its first item, because Stripe
  moved it in 2025 and we cannot test which one this account returns.
- **Custom categories still gate on sign-in, not premium.** Deliberate: they
  have been free-with-an-account since 0015 and taking that away before
  payments exist would be a downgrade. `PREMIUM_GATES.customCategories` in
  `lib/premium.ts` is the switch.
- **The realtime leg of the audience tally is unproven end to end.** The
  broadcast is verified to be emitted (the local harness records every
  `realtime.send`), and the subscription code is the same shape the board
  already uses in production, but the harness has no realtime server so
  nobody has watched a tally move in one browser because of a vote cast in
  another.
- **The OBS overlay has never been loaded by OBS itself**, only by a browser
  at 9:16. Transparency there depends on CEF honouring a transparent body,
  which it does, but nobody has watched it composite over a real scene.
- **Nothing is committed to git** beyond the initial scaffold.
