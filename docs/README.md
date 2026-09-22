# DraftFor20 — engineering documentation

Start here. This folder is the long-form reference; `CLAUDE.md` in the repo
root is the short agent-facing ruleset, and the two are kept in step.

**Live:** https://www.draftfor20.com · **Supabase ref:** `jwnlmvjzeodfmngnhadq`
· **Repo:** github.com/txnkzy/DraftFor20

---

## The ten-minute orientation

DraftFor20 is a **real-time auction game built to be filmed**. Two people
split a fixed bankroll across a flat roster of N picks, bidding against each
other under a server-authoritative countdown. When the money runs out it
produces a vertical 1080×1920 results card designed for TikTok.

It has since grown three more modes, all sharing the same category library
and card rendering:

| Mode | Route | Players | What it is |
|---|---|---|---|
| **The draft** | `/room/[code]` | 2 | The original auction. Real-time, money, a clock. |
| **Quick Play** | `/quick-play` | 1 + bot | The same draft against a heuristic bot. |
| **Build the Lineup** | `/rank` | 1 | Five cards dealt one at a time into five ranked slots. |
| **Leaderboard** | `/leaderboard` | — | Wins and drafts played, ranked. |

### Two rules govern everything

**1. Money validation is the product.** Every bid is re-validated inside
Postgres against freshly-read state. No client check is trusted, and nothing
is a float — all money is integer cents.

**2. Neither player may ever see an undealt item.** The deck is a shuffled,
server-side list. Items reach a client one card at a time, after being dealt,
never before. The Lineup mode inherits this rule exactly.

Both are enforced **in the database, not the UI**, because the anon key is
public and every RPC is reachable with `curl`.

---

## Where to go next

| Document | Read it when |
|---|---|
| [01 · Product](01-product.md) | You need the game rules and what each mode does |
| [02 · Architecture](02-architecture.md) | You need the stack and how a request flows |
| [03 · Database](03-database.md) | You are touching schema, RPCs or migrations |
| [04 · Security](04-security.md) | You are touching auth, grants or RLS — **read before any RPC work** |
| [05 · Categories & images](05-categories-and-images.md) | You are seeding or fixing card art |
| [06 · Billing & premium](06-billing-and-premium.md) | You are touching Stripe or a paywall |
| [07 · Frontend](07-frontend.md) | You are writing components or styles |
| [08 · Testing & CI](08-testing-and-ci.md) | You are adding tests or a check failed |
| [09 · Operations](09-operations.md) | You are deploying, or something is broken in production |
| [10 · Gotchas](10-gotchas.md) | **Before changing anything non-trivial** |
| [11 · Known gaps](11-known-gaps.md) | You are planning work |

---

## Scale, as of the last audit

| | |
|---|---|
| Rooms created | ~13,000 (~9,200 completed) |
| Accounts | ~181 |
| Library categories | 32, holding 1,398 items (1,368 pictured) |
| Postgres functions | ~173 |
| Tables | 29 |
| Migrations | 74 |

**~97% of play is anonymous.** Only a few hundred seats out of ~22,000 are
attached to an account. That single fact explains more product decisions
than any other — why the leaderboard looks sparse, why sign-in is not
required to play, and why the audience vote is deliberately free.

---

## First day checklist

```bash
git clone https://github.com/txnkzy/DraftFor20.git
cd DraftFor20
npm install
# create .env.local — see 09-operations.md for the variable list
npm run dev
```

Then read [10 · Gotchas](10-gotchas.md). It is the highest value-per-minute
document here: every entry is a bug that actually shipped.
