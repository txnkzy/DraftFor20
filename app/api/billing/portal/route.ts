import { NextResponse } from "next/server";
import { billingStatus, getStripe, siteOrigin } from "@/lib/billing/stripe";
import { lookupCustomer } from "@/lib/billing/db";
import { allow, clientIp } from "@/lib/rateLimit";
import { requireUser } from "@/lib/api/auth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Stripe's own billing portal: cancel, change card, read invoices.
 *
 * Managing a subscription is Stripe's page, not one built here — the same
 * reason checkout is hosted. Degrades exactly like checkout when there are
 * no keys.
 *
 * THIS ROUTE OPENS A SESSION FOR A STRIPE CUSTOMER, which means whatever it
 * treats as "the caller's customer id" is an authorisation decision. It used
 * to read that id from profiles.stripe_customer_id while `authenticated` held
 * a blanket UPDATE grant on that table — so a user could PATCH someone else's
 * cus_... onto their own row and get handed the victim's portal: their
 * invoices, their billing address, their card's last four, and a cancel
 * button. 0041/0042 closed the write; the column is now settable only by
 * df20_apply_billing_event, from a signature-verified webhook.
 *
 * The shape check below is the second lock rather than the first. It cannot
 * tell whose customer id it is, so it is not the control that matters — it
 * only means a malformed or injected value fails here instead of at Stripe.
 */
export async function POST(req: Request) {
  if (!billingStatus().configured) {
    return NextResponse.json({ configured: false }, { status: 200 });
  }

  const auth = await requireUser(req);
  if (auth instanceof NextResponse) return auth;

  // opening a portal session is a Stripe API call made in the user's name
  if (!(await allow("portal", `${auth.user.id}:${clientIp(req)}`, 12, 3600))) {
    return NextResponse.json({ message: "DF20_RATE_LIMITED" }, { status: 429 });
  }

  const known = await lookupCustomer(auth.user.id);
  if (!known.customerId) {
    return NextResponse.json(
      { message: "There's no Stripe customer on this account yet." },
      { status: 400 },
    );
  }
  if (!/^cus_[A-Za-z0-9]{6,64}$/.test(known.customerId)) {
    console.error("portal: refusing malformed customer id for", auth.user.id);
    return NextResponse.json({ message: "Could not open the billing portal." }, { status: 502 });
  }

  const stripe = getStripe();
  if (!stripe) return NextResponse.json({ configured: false }, { status: 200 });

  try {
    const session = await stripe.billingPortal.sessions.create({
      customer: known.customerId,
      return_url: `${siteOrigin(req)}/profile`,
    });
    return NextResponse.json({ configured: true, url: session.url });
  } catch (err) {
    console.error("stripe portal failed", err);
    return NextResponse.json({ message: "Could not open the billing portal." }, { status: 502 });
  }
}
