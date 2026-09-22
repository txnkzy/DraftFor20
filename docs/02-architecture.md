# 02 · Architecture

---

## Stack

| Layer | Choice |
|---|---|
| Framework | Next.js 16, App Router, Turbopack |
| UI | React 19, TypeScript, Tailwind v4 |
| Data | Supabase — Postgres, Realtime, Auth |
| Hosting | Vercel (deploys on push to `main`) |
| Payments | Stripe (hosted Checkout + Billing Portal) |

Framer Motion is imported **only** by the landing scroll sequence, via
`next/dynamic` with `ssr: false`. Keep it out of the room bundle.

---

## The shape of the system

```
browser ──► Next.js route handler ──► Supabase RPC ──► Postgres
   │              (lib/api/auth.ts)        │            (the rules live here)
   │                                       │
   └──────────── Supabase client ──────────┘
                 (anon key, public)
```

Two paths reach Postgres and they are **not** equivalent:

1. **Direct from the browser** via the Supabase JS client, calling RPCs with
   the publishable anon key. This is how the game loop runs.
2. **Through a Next.js route handler**, for anything needing a secret — the
   Stripe webhook, the share-card renderer, the signup flow.

Because path 1 exists and the anon key is public, **every rule must be
enforced inside Postgres**. A route handler is a convenience, never a
security boundary.

---

## The mutating-RPC contract

Every mutating RPC does the same four things, in this order:

1. `SELECT … FOR UPDATE` on the room row, so actions in a room strictly
   serialize
2. Authenticate from the session token — **never** a client-supplied player id
3. Re-read bankroll, deck and lot state, and re-validate
4. Commit, bump `rooms.version`, broadcast

A `turn_seq` optimistic check is the second guard: a bid built against a
board that has since moved is rejected as `DF20_STALE`.

---

## Identity

There are three distinct identities, and confusing them is a security bug:

| Identity | What it is | Where it lives |
|---|---|---|
| **Session token** | A uuid proving you hold a seat in one room | `players.session_token`, localStorage on the client |
| **Account** | A Supabase Auth user, optional | `auth.uid()` → `profiles.id` |
| **Device key** | An anonymous per-browser id for the solo cap | httpOnly cookie `df20_sk` |

A session token grants nothing outside its room. A device key is not an
identity — it only rate-limits. Only an account can own anything.

**Pass-and-play is supported**: one device may hold more than one seat in the
same room, and `lib/game/session.ts` decides which token the page is acting
as. The server is not involved and does not need to be.

---

## Route handler auth

**Every route handler authenticates through `lib/api/auth.ts` and nothing
else.**

- `requireUser(req)` returns either the verified caller or the `NextResponse`
  to send back
- `optionalUser(req)` is for routes that serve anonymous players but
  attribute a room when someone is signed in

The genuinely public routes (magic-link, billing config, share card) and the
audience vote say so in a `// AUTH:` comment at the top, so *"why is this
open?"* is greppable rather than assumed.

None of this replaces the checks in Postgres — it decides **who reaches an
RPC**; the RPC decides **what they may do**.

---

## Reads

Clients cannot read any game table directly. RLS is deny-all with no anon
policies on every game table, and the only read path is
`df20_public_state()`, a `SECURITY DEFINER` function that:

- strips `players.session_token`
- strips `setup_token`, `setup_result_token` and `obs_token` from the room
- touches `room_deck` only to `count(*)` unrevealed rows

> **`df20_public_state` returns `to_jsonb(rooms)`, so every column you add to
> that table lands in both players' browsers.** Adding another token column
> without adding it to the strip list hands it out automatically.

---

## Realtime

The board subscribes to `room:<uuid>`. Mutating RPCs call `df20_broadcast`
inside the same transaction that made the change.

The audience tally is **pushed, not polled**: `cast_audience_vote` calls
`realtime.send()` in the same transaction that records the vote, with the
tally itself as the payload — so subscribers receive the numbers rather than
a hint to go and ask. A voter subscribes only *after* voting, because the
payload is the answer the blind rule makes them earn.

---

## Build-time vs runtime

**`NEXT_PUBLIC_*` is inlined at BUILD time.** Changing `NEXT_PUBLIC_SITE_URL`
in the Vercel dashboard does nothing to a deployment that already exists —
the old value is compiled into the bundle. It needs a redeploy, and the
served JS is where to check which value actually shipped.

---

## Client-module boundary

`lib/premium.ts` carries `"use client"`. **A route handler that imports a
value from a client module gets a client-reference proxy, not the value.**

This shipped as a 500 on every upgrade surface: the config endpoint called
`.map()` on what it thought was an array. Plan data therefore lives in
`lib/plans.ts`, which carries no directive, and both sides import from there.

If you need a constant on both sides, put it in a file with **no** `"use
client"` and no `"server-only"`.
