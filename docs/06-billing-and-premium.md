# 06 · Billing and premium

---

## Premium, in one sentence

An account has premium while `profiles.premium_until` is in the future.

`df20_premium_active(uid)` is that comparison and nothing else. A Stripe
subscription, a day pass and an admin grant all write that same column, so
**no gate anywhere can tell them apart** — which is the point. Set the column
by hand in the table editor and every premium feature unlocks with no other
code path involved.

`premium_source` is for display only; nothing gates on it.

---

## The price ladder

| Plan | Price | Stripe mode | Env var |
|---|---|---|---|
| Premium | **$7** / month | `subscription` | `STRIPE_PRICE_ID` |
| Week Pass | **$5** / week | `subscription` | `STRIPE_WEEK_PRICE_ID` |
| Game Night Pass | **$2** / 24 hours | `payment` | `STRIPE_PASS_PRICE_ID` |

Each rung is cheaper per day than the one below: $2/day, 71¢/day, 23¢/day.

**Prices come from Stripe, not from this repo.** `/api/billing/config` reads
`unit_amount` off each Price object, memoised five minutes, so raising a
price is an edit in the Stripe dashboard and nothing else. `PLANS` in
`lib/plans.ts` is the **fallback** for an install with no keys.

> Why: the prices were a hand-kept copy repeated in five components and had
> already drifted — `UpgradeCard` offered the pass at $2 while every other
> surface said $1. Whichever page a customer opened decided what they thought
> they were paying. Advertising one number and charging another is
> indistinguishable from a bait and switch.

### Guards on the price objects

The lookup logs loudly when:

- a price is **archived** — an archived price still *retrieves*, so the page
  renders its old amount convincingly and Checkout then refuses the session
- the recurring/one-off **mode** disagrees with the plan — `payment` on a
  weekly plan grants forever for one charge; `subscription` on the day pass
  bills somebody every 24 hours until they notice
- the **interval** disagrees — both subscriptions are recurring, so only an
  interval check catches the monthly and weekly ids being swapped

`RECURRING` in `lib/plans.ts` decides the Checkout mode, so there is one
source of truth rather than a second `plan === …` chain that can drift.

---

## What is gated

| Surface | Gate |
|---|---|
| Content Creator rooms | premium, chosen at creation, never changed |
| Record mode, OBS link, host's live tally | premium |
| OBS token minting | premium, **checked in the RPC**, not the UI |
| Scouting report beyond the last 5 drafts | premium, windowed in the RPC |
| Export card branding | premium, **opt-out only** (below) |
| Any host-supplied category | premium since `0033` |
| Unlimited single-player games | premium — free is 3 a day, shared across Quick Play and Lineup |
| Public audience vote link | **free, deliberately: it is the acquisition loop.** `0033` gated it, `0034` put it back |

### The watermark is opt-out, and that is a product decision

`df20_export_style(code)` resolves it server-side from the room's host
profile. Watermark off requires **all three** of:

1. an active premium account,
2. that account owning the room, and
3. that account having explicitly set the toggle.

Anything else — free, lapsed, premium-but-untouched, or someone editing the
URL — gets the standard watermarked card. There is no parameter that turns it
off; the PNG route takes a room code and nothing else. `v6_premium.sql`
asserts this both ways round.

---

## The webhook is the only thing that grants premium

Nothing the browser says about a payment is believed: the success page can be
opened by anyone with the URL, and the checkout call happens **before** any
money moves. Access is written by `/api/billing/webhook` from a
signature-verified event, or by an admin by hand. There is no third path.

### Events it handles

```
checkout.session.completed      payment_intent.succeeded
customer.subscription.created   customer.subscription.updated
customer.subscription.deleted   invoice.paid
invoice.payment_succeeded       invoice.payment_failed
```

**All of these must be enabled on the Stripe endpoint.** If only
`payment_intent.succeeded` is enabled, the subscription plans fail exactly as
the pass once did.

### A write that failed must not be answered with 200

`applyBilling` and `revokeBilling` do not throw — they **return**
`{ok:false}`. Every call used to discard that, so a refused write fell
through to `{received:true}`: Stripe recorded the delivery as succeeded and
never retried, nothing was written, and the customer got nothing. **A payment
could be lost permanently with no trace on either side.**

`must()` now throws, which writes a failure row and answers 500 so Stripe
retries and shows the failure in its own dashboard. The reason also goes in
the response body, because that is where somebody who just pressed Resend is
already looking.

### The pass grants from EITHER announcement

A day pass can be announced twice — `checkout.session.completed` and
`payment_intent.succeeded` describe the same purchase. Both paths key
idempotency on the **payment intent**, not the event id, so two events for
one purchase cannot grant 48 hours. **Do not "simplify" that back to the
event id.**

### `periodEnd()` reads two places

Stripe moved the period end onto the subscription item in 2025, so the code
reads both the subscription and its first item. Removing either half risks
silently granting nothing.

---

## Cancellation

`/api/billing/portal` opens Stripe's own hosted portal — cancel, change card,
download invoices. A custom cancel button would be a worse copy of one of
those four.

`customer.subscription.deleted` → `df20_revoke_premium`, which sets
`premium_until = now()` — **except** when `premium_source = 'admin_grant'`,
because an admin grant is not Stripe's to cancel.

### Two Stripe dashboard settings this depends on

1. **Customer Portal activated in live mode, with "Cancel subscriptions"
   enabled** and set to *cancel at end of billing period* — the UI copy
   promises access continues to the end of the paid period.
2. **`customer.subscription.deleted` subscribed on the webhook endpoint.**
   Without it, a cancellation never reaches us and the customer keeps premium
   indefinitely despite having stopped paying.

Neither is visible from the codebase. Check them in the dashboard.
