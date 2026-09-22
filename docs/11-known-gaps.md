# 11 · Known gaps

What is unproven, unfinished, or deliberately deferred. Kept honest so
nobody rediscovers a known hole as a surprise.

---

## Unproven end to end

- **The Stripe SUBSCRIPTION path.** A real £1 pass has been bought, failed,
  been debugged and been granted — so the pass works. The subscriptions need
  `checkout.session.completed`, the `customer.subscription.*` and the
  `invoice.*` events enabled on the webhook endpoint. If only
  `payment_intent.succeeded` is enabled, the monthly and weekly plans fail
  exactly as the pass once did. **No live purchase of the $7, $5 or $2 plan
  has been made since the price change.**
- **`periodEnd()`** reads the period end from both the subscription and its
  first item, because Stripe moved it in 2025 and nobody has confirmed which
  this account returns.
- **The realtime leg of the audience tally.** The broadcast is verified to be
  emitted and the subscription code is the same shape the board uses in
  production, but the local harness has no realtime server, so nobody has
  watched a tally move in one browser because of a vote cast in another.
- **The OBS overlay has never been loaded by OBS itself**, only by a browser
  at 9:16. Transparency *is* verified — html, body and the stage root all
  compute to `rgba(0,0,0,0)` and the page renders over a striped backdrop
  with the stripes showing through everywhere except the plates. Note the
  page sets `frame-ancestors 'none'`; OBS Browser Source is not an iframe and
  is unaffected.
- **Two things never verified by a human:** whether the raise cue is audible
  on desktop, and whether the landing scroll sequence feels right. The
  automation browser runs with autoplay disabled and rAF paused.

---

## Operational

- **`support@draftfor20.com` does not exist yet.** No MX record has been
  created for `draftfor20.com`, so mail to it bounces. The privacy policy,
  terms and footer all reference it. Operator name and jurisdiction are still
  placeholders. Steps are in `DEPLOY.md`.
- **Billing reconciliation has never been done.** Stripe's payments list has
  never been checked against `billing_events`, which has held very few rows.
- **1,368 hotlinked images are unmonitored.** Nothing alerts when one 404s;
  `CardImage` falls back to a generated card, so link rot is silent by
  design.
- **Turnstile and GA are unset in Production**
  (`NEXT_PUBLIC_TURNSTILE_SITE_KEY`, `TURNSTILE_SECRET_KEY`,
  `NEXT_PUBLIC_GA_ID`), so bot-checking and analytics are effectively off.
  Analytics is built with Consent Mode v2, default denied, and loads nothing
  until a visitor accepts — setting the id turns it on.
- **A stray `draft420` Vercel project** exists in the team with no
  deployments. It is not the live project and should be removed.
- **AdSense is not approved** and its hosts are deliberately absent from the
  CSP. An ad snippet pasted in today would be blocked until
  `next.config.ts` is updated. There is no `ads.txt`.

---

## Known-imperfect by choice

- **The solo cap is cookie-based** (`df20_sk`, httpOnly). Clearing cookies
  gets you three more games. That is a known limit, not an oversight: ~97% of
  traffic is anonymous and Quick Play exists to rescue the ~1 room in 4 that
  never finds a second player, so a harder gate would cost more than it
  earns. Signing in keys the cap on the account instead.
- **Custom categories gate on sign-in, not premium.**
  `PREMIUM_GATES.customCategories` in `lib/premium.ts` is the switch. They
  have been free-with-an-account since `0015` and taking that away before
  payments existed would have been a downgrade.
- **The leaderboard shows `display_name` when set, `@handle` otherwise.**
  Display names are free text and unvalidated, so there is an impersonation
  surface. Showing the handle always would close it.
- **Lineup mode is library-categories only.** Saved decks and typed
  categories are not wired in; the premium boundary there is drawn by which
  table is reachable rather than by a flag, so adding them means adding that
  gate with them.
- **Lineup has no share-card PNG.** The draft's 1080×1920 export is
  room-shaped; a lineup variant is its own route. Sharing is currently the
  link, which is what carries the rating loop anyway.
- **CI lint is reported, not enforced**, because two `setState`-in-effect
  errors predate the workflow. Fix `CardImage.tsx` and `app/dev/cards`, then
  make it a gate.

---

## Known-broken for a fresh install

- **`supabase/APPLY_V7.sql` does not apply to a FRESH database** —
  `DF20_ANIME_TOO_SMALL`, because Jujutsu Kaisen Characters has 28 items
  against a 30 guard in `0046_anime_categories.sql`. The live database was
  built incrementally and is unaffected; only a rebuild hits this.
- **`/results/[code]`** (the standalone page, not the in-room one) never
  passes a session token, so the audience tally never renders there.

---

## Worth doing next

Roughly in order of value per hour:

1. **Buy one of each plan with a real card and refund** — the subscription
   path is the largest untested surface with money attached.
2. **Reconcile Stripe payments against `billing_events`.**
3. **Fix the two lint errors and make CI lint a gate.**
4. **Add a post-deploy `df20_selfcheck()` check.** `rpc-parity` closes the
   code-ahead-of-SQL direction; nothing yet catches SQL-applied-but-not-
   committed, which is how three callers shipped without their functions.
5. **Invite flow.** ~1 room in 4 died with one player — Quick Play rescues
   the solo case but does not fix invitation.
6. **Create the support mailbox** and replace the operator placeholders.
7. **Image link-rot monitoring.**
