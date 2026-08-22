import { createClient } from "@supabase/supabase-js";
import { NextResponse } from "next/server";
import { billingStatus, getStripe, siteOrigin } from "@/lib/billing/stripe";
import { lookupCustomer } from "@/lib/billing/db";
import { stripeEnv } from "@/lib/billing/stripe";
import { allow, clientIp } from "@/lib/rateLimit";

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

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) {
    return NextResponse.json({ configured: false, message: "Not configured." }, { status: 200 });
  }

  const token = req.headers.get("authorization")?.replace(/^Bearer /i, "") ?? "";
  if (!token) {
    return NextResponse.json({ message: "DF20_SIGNIN_REQUIRED" }, { status: 401 });
  }
  const sb = createClient(url, key, { auth: { persistSession: false } });
  const { data: who } = await sb.auth.getUser(token);
  if (!who?.user) {
    return NextResponse.json({ message: "DF20_SIGNIN_REQUIRED" }, { status: 401 });
  }

  if (!(await allow("checkout", `${who.user.id}:${clientIp(req)}`, 12, 3600))) {
    return NextResponse.json({ message: "DF20_RATE_LIMITED" }, { status: 429 });
  }

  const stripe = getStripe();
  if (!stripe) {
    return NextResponse.json({ configured: false }, { status: 200 });
  }

  const env = stripeEnv();
  const origin = siteOrigin(req);
  const known = await lookupCustomer(who.user.id);

  try {
    const session = await stripe.checkout.sessions.create({
      mode: plan === "pass" ? "payment" : "subscription",
      line_items: [{ price: plan === "pass" ? env.passPriceId : env.priceId, quantity: 1 }],
      // both of these carry the account id, because the webhook has to know
      // whose profile to write and an email is not an identity
      client_reference_id: who.user.id,
      metadata: { user_id: who.user.id, plan },
      ...(plan === "pass"
        ? { payment_intent_data: { metadata: { user_id: who.user.id, plan } } }
        : { subscription_data: { metadata: { user_id: who.user.id, plan } } }),
      ...(known.customerId
        ? { customer: known.customerId }
        : { customer_email: who.user.email ?? undefined }),
      allow_promotion_codes: true,
      success_url: `${origin}${returnTo}?upgraded=1`,
      cancel_url: `${origin}${returnTo}`,
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
