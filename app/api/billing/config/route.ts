import { NextResponse } from "next/server";
import { billingStatus } from "@/lib/billing/stripe";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * What the Upgrade UI asks BEFORE it renders a button.
 *
 * With no Stripe keys set this answers configured:false and the client shows
 * "payments coming soon" — no checkout call is attempted, so there is nothing
 * to fail. The list of missing variable names is deliberately not returned;
 * it is for the server log, not for a visitor.
 */
export async function GET() {
  const s = billingStatus();
  return NextResponse.json(
    {
      configured: s.configured,
      subscription: s.subscription,
      pass: s.pass,
      plans: {
        premium: { price: "$5", period: "/month", available: s.subscription },
        pass: { price: "$2", period: "for 24 hours", available: s.pass },
      },
    },
    { headers: { "Cache-Control": "no-store" } },
  );
}
