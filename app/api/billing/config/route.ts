import { NextResponse } from "next/server";
import { billingStatus, livePlanPrices } from "@/lib/billing/stripe";
import { PLANS, PLAN_ORDER, type PlanId } from "@/lib/plans";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * What the Upgrade UI asks BEFORE it renders a button.
 *
 * With no Stripe keys set this answers configured:false and the client shows
 * "payments coming soon" — no checkout call is attempted, so there is nothing
 * to fail. The list of missing variable names is deliberately not returned;
 * it is for the server log, not for a visitor.
 *
 * THE PRICES COME FROM STRIPE when Stripe is configured, and from PLANS when
 * it is not. Every plan surface on the site reads this one endpoint, so there
 * is exactly one answer to "what does it cost" and it is the same answer the
 * checkout page will give. Raising a price is an edit in the Stripe
 * dashboard; this follows within five minutes with no deploy.
 */
// AUTH: public — returns prices and a boolean per plan. No account state,
// nothing user-specific, nothing that is not already on the pricing page.
export async function GET() {
  const s = billingStatus();
  const live = await livePlanPrices();

  const available: Record<PlanId, boolean> = {
    premium: s.subscription,
    week: s.week,
    pass: s.pass,
  };

  const plans = Object.fromEntries(
    PLAN_ORDER.map((id) => [
      id,
      {
        label: PLANS[id].label,
        // Stripe first, the literal second. Never blank: a price tag with no
        // number on it is worse than a slightly stale one.
        price: live[id]?.price ?? PLANS[id].price,
        period: live[id]?.period ?? PLANS[id].period,
        available: available[id],
      },
    ]),
  );

  return NextResponse.json(
    {
      configured: s.configured,
      subscription: s.subscription,
      week: s.week,
      pass: s.pass,
      plans,
    },
    { headers: { "Cache-Control": "no-store" } },
  );
}
