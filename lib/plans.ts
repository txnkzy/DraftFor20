/**
 * Plan data. NO "use client" AND NO "server-only" — that is the whole point
 * of the file.
 *
 * These constants used to live in lib/premium.ts, which is a client module.
 * A route handler that imports a value from a "use client" file does not get
 * the value, it gets a client-reference proxy, and the first thing the config
 * endpoint did with it was call .map() — "PLAN_ORDER.map is not a function",
 * a 500 on every upgrade surface, and the pages quietly falling back to their
 * offline copy so it looked like it was working. That is also why the old
 * config route wrote the prices out by hand instead of importing them.
 *
 * Both sides import from here instead.
 */

/**
 * THE PRICE LADDER, and the only place these numbers are written down.
 *
 * They used to be repeated as a fallback literal in five components, and they
 * had already drifted — UpgradeCard offered the pass at $2 while the pricing
 * page, the dialog and the config endpoint all said $1. Whichever surface a
 * customer happened to open decided what they thought they were paying.
 *
 * These are the FALLBACK now. When Stripe is configured the config endpoint
 * returns the real unit_amount off the Price objects themselves, so the
 * dashboard is authoritative and a price rise is one edit there rather than a
 * deploy that has to be kept in step with one. See livePlanPrices().
 *
 * Each rung is cheaper per day than the one below it: $2 a day, 71c a day
 * for the week, 23c a day for the month. The day pass was $1, which after
 * Stripe's 30c-plus-2.9% netted 67c — a third of it gone to move a dollar,
 * which is not a price so much as a rounding error. At $2 the fee is 18% of
 * the sale, which is still the dearest money on this page and the reason the
 * ladder test keeps a floor under the cheapest rung.
 */
export const PLANS = {
  premium: { label: "Premium", price: "$7", period: "/month" },
  week: { label: "Week Pass", price: "$5", period: "/week" },
  pass: { label: "Game Night Pass", price: "$2", period: "for 24 hours" },
} as const;

export type PlanId = keyof typeof PLANS;

/** Dearest first. The order every plan surface renders in. */
export const PLAN_ORDER = ["premium", "week", "pass"] as const;

/** The two recurring plans, which Stripe must open in `subscription` mode.
 *  The pass is a one-off `payment`, and getting that wrong bills somebody
 *  every 24 hours. */
export const RECURRING: ReadonlySet<PlanId> = new Set<PlanId>(["premium", "week"]);

/**
 * What Stripe's Price object must say for each plan, checked at lookup time.
 *
 * The recurring/one-off check alone cannot catch the likeliest setup mistake,
 * which is the monthly and weekly price ids swapped between their two
 * variables — both are recurring, so both pass. This catches it by interval.
 *
 * Nobody is ever mischarged by a swap, because the amount AND the period both
 * come off the same Price object, so the card always quotes what Checkout
 * will take. What a swap produces is a Premium card reading "/week" — wrong
 * labels rather than a wrong bill. Still worth saying out loud in the log.
 */
export const EXPECTED_INTERVAL: Record<PlanId, "month" | "week" | null> = {
  premium: "month",
  week: "week",
  pass: null, // one-off; no recurrence at all
};
