import { createClient } from "@supabase/supabase-js";
import { NextResponse } from "next/server";
import { billingStatus, getStripe, siteOrigin } from "@/lib/billing/stripe";
import { lookupCustomer } from "@/lib/billing/db";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Stripe's own billing portal: cancel, change card, read invoices.
 *
 * Managing a subscription is Stripe's page, not one built here — the same
 * reason checkout is hosted. Degrades exactly like checkout when there are
 * no keys.
 */
export async function POST(req: Request) {
  if (!billingStatus().configured) {
    return NextResponse.json({ configured: false }, { status: 200 });
  }

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  const token = req.headers.get("authorization")?.replace(/^Bearer /i, "") ?? "";
  if (!url || !key || !token) {
    return NextResponse.json({ message: "DF20_SIGNIN_REQUIRED" }, { status: 401 });
  }

  const sb = createClient(url, key, { auth: { persistSession: false } });
  const { data: who } = await sb.auth.getUser(token);
  if (!who?.user) {
    return NextResponse.json({ message: "DF20_SIGNIN_REQUIRED" }, { status: 401 });
  }

  const known = await lookupCustomer(who.user.id);
  if (!known.customerId) {
    return NextResponse.json(
      { message: "There's no Stripe customer on this account yet." },
      { status: 400 },
    );
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
