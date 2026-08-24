import { NextResponse } from "next/server";
import { billingStatus, getStripe, siteOrigin } from "@/lib/billing/stripe";
import { lookupCustomer } from "@/lib/billing/db";
import { stripeEnv } from "@/lib/billing/stripe";
import { allow, clientIp } from "@/lib/rateLimit";
import { requireUser } from "@/lib/api/auth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Start a Stripe Checkout session.
 *
 * WITH NO KEYS SET THIS IS NOT AN ERROR. It answers 200 with
 * { configured: false } and the UI shows "payments coming soon". Nothing
 * throws, nothing 500s, and a free user who clicks Upgrade today sees a
 * sentence rather than a stack trace.
 *
 * Checkout is Stripe-hosted on purpose: no card field on this origin means
 * this codebase never touches a card number.
 */
export async function POST(req: Request) {
  const status = billingStatus();

  let plan = "premium";
  let returnTo = "/profile";
  try {
    const body = (await req.json()) as { plan?: string; returnTo?: string };
    if (body.plan === "pass" || body.plan === "premium") plan = body.plan;
    // Stripe redirects the browser to this, so it has to be a path on this
    // site and cannot be talked into being somebody else's origin
    if (typeof body.returnTo === "string" && /^\/[^/\\]/.test(body.returnTo)) {
      returnTo = body.returnTo;
    }
  } catch {
    /* defaults are fine */
  }

  const wanted = plan === "pass" ? status.pass : status.subscription;
  if (!status.configured || !wanted) {
    return NextResponse.json(
      { configured: false, message: "Payments aren't switched on yet." },
      { status: 200 },
    );
  }

  const auth = await requireUser(req);
  if (auth instanceof NextResponse) return auth;
  const sb = auth.sb;

  // An unverified account cannot buy. Asked of the database rather than read
  // off the JWT so "verified" has one definition in this system, and it is
  // the same one the custom-category and admin gates use.
  const { data: v } = await sb.rpc("my_verification");
  if ((v as { verified?: boolean } | null)?.verified === false) {
    return NextResponse.json({ message: "DF20_EMAIL_UNVERIFIED" }, { status: 403 });
  }

  if (!(await allow("checkout", `${auth.user.id}:${clientIp(req)}`, 12, 3600))) {
    return NextResponse.json({ message: "DF20_RATE_LIMITED" }, { status: 429 });
  }

  const stripe = getStripe();
  if (!stripe) {
    return NextResponse.json({ configured: false }, { status: 200 });
  }

  const env = stripeEnv();
  const origin = siteOrigin(req);
  const known = await lookupCustomer(auth.user.id);

  try {
    const session = await stripe.checkout.sessions.create({
      mode: plan === "pass" ? "payment" : "subscription",
      line_items: [{ price: plan === "pass" ? env.passPriceId : env.priceId, quantity: 1 }],
      // both of these carry the account id, because the webhook has to know
      // whose profile to write and an email is not an identity
      client_reference_id: auth.user.id,
      metadata: { user_id: auth.user.id, plan },
      ...(plan === "pass"
        ? { payment_intent_data: { metadata: { user_id: auth.user.id, plan } } }
        : { subscription_data: { metadata: { user_id: auth.user.id, plan } } }),
      ...(known.customerId
        ? { customer: known.customerId }
        : { customer_email: auth.user.email ?? undefined }),
      allow_promotion_codes: true,
      // The webhook is what actually grants access, and it can land after the
      // customer is already back. The success page waits for it rather than
      // claiming an upgrade the database has not been told about yet.
      success_url:
        `${origin}/billing/success?session_id={CHECKOUT_SESSION_ID}` +
        `&plan=${plan}&next=${encodeURIComponent(returnTo)}`,
      cancel_url: `${origin}/pricing?cancelled=1`,
    });

    if (!session.url) {
      return NextResponse.json({ message: "Checkout could not start." }, { status: 502 });
    }
    return NextResponse.json({ configured: true, url: session.url });
  } catch (err) {
    console.error("stripe checkout failed", err);
    return NextResponse.json(
      { message: "Checkout could not start. Nothing was charged." },
      { status: 502 },
    );
  }
}
