import { describe, expect, it } from "vitest";
import { PLANS, PLAN_ORDER, RECURRING, type PlanId } from "./plans";

/** "$2.99" -> 299. The fallback prices are strings because they are display
 *  copy; this is only here so the ladder can be checked. */
function cents(s: string): number {
  return Math.round(Number(s.replace(/[^0-9.]/g, "")) * 100);
}

describe("the price ladder", () => {
  it("bills the day pass once and the rest on a schedule", () => {
    // Getting this backwards is the expensive mistake: `subscription` mode on
    // the day pass charges somebody every 24 hours until they notice.
    expect(RECURRING.has("pass")).toBe(false);
    expect(RECURRING.has("week")).toBe(true);
    expect(RECURRING.has("premium")).toBe(true);
  });

  it("lists every plan exactly once, dearest first", () => {
    expect([...PLAN_ORDER].sort()).toEqual(Object.keys(PLANS).sort());
    const prices = PLAN_ORDER.map((id) => cents(PLANS[id].price));
    expect(prices).toEqual([...prices].sort((a, b) => b - a));
  });

  it("gets cheaper per day the longer you buy", () => {
    // The reason anybody moves up a rung. If a longer plan ever costs more
    // per day than a shorter one, the ladder is upside down and the middle
    // option becomes a trap rather than an upsell.
    const days: Record<PlanId, number> = { premium: 30, week: 7, pass: 1 };
    const perDay = PLAN_ORDER.map((id) => cents(PLANS[id].price) / days[id]);
    for (let i = 1; i < perDay.length; i++) {
      expect(perDay[i]).toBeGreaterThan(perDay[i - 1]);
    }
  });

  it("charges more than Stripe's fee floor for the cheapest rung", () => {
    // 30c + 2.9%. At the old $1 the pass netted 67c, so a third of every
    // sale went to moving the dollar.
    const lowest = Math.min(...PLAN_ORDER.map((id) => cents(PLANS[id].price)));
    const fee = 30 + lowest * 0.029;
    expect(fee / lowest).toBeLessThan(0.2);
  });
});
