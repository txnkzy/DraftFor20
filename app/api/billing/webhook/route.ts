import type Stripe from "stripe";
import { NextResponse } from "next/server";
import { billingStatus, getStripe, stripeEnv } from "@/lib/billing/stripe";
import { applyBilling, logBillingFailure, revokeBilling } from "@/lib/billing/db";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Stripe's webhook. THE ONLY THING THAT GRANTS PREMIUM.
 *
 * Nothing the browser says about a payment is believed: the success page can
 * be opened by anyone with the URL, and the checkout call happens before any
 * money moves. Access is written here, from a signed event, or by an admin by
 * hand. There is no third path.
 *
 * Unconfigured, this answers 503 with a sentence. It never throws, and no
 * other part of the site depends on it existing.
 */

/** Stripe moved the period end onto the subscription item in 2025. Read both
 *  so this keeps working across a version bump rather than silently granting
 *  nothing. */
function periodEnd(sub: Stripe.Subscription): Date | null {
  const legacy = (sub as unknown as { current_period_end?: number }).current_period_end;
  const item = sub.items?.data?.[0] as unknown as { current_period_end?: number } | undefined;
  const secs = legacy ?? item?.current_period_end;
  return typeof secs === "number" ? new Date(secs * 1000) : null;
}

const DEAD = new Set(["canceled", "incomplete_expired", "unpaid"]);

/**
 * A write that failed must not be answered with 200.
 *
 * applyBilling and revokeBilling do not throw — they RETURN {ok:false}. Every
 * call here discarded that, so a refused write fell through to
 * `{received:true}`: Stripe recorded the delivery as succeeded and never
 * retried, nothing was written to billing_events, and the customer got
 * nothing. A payment could be lost permanently with no trace on either side.
 *
 * Throwing hands it to the catch below, which writes the failure row and
 * answers 500 so Stripe retries and shows the failure in its own dashboard.
 */
/**
 * One idempotency key per PURCHASE, not per event.
 *
 * A day pass can be announced twice — checkout.session.completed and
 * payment_intent.succeeded describe the same £1 — and those carry different
 * event ids, so keying on the event id would grant 24 hours twice. Both paths
 * key on the payment intent instead, and df20_apply_billing_event's
 * `on conflict (event_id) do nothing` turns whichever arrives second into a
 * no-op. Whichever arrives FIRST grants, so the pass works if Stripe is
 * sending either one.
 */
function passKey(paymentIntent: unknown): string | null {
  const id =
    typeof paymentIntent === "string"
      ? paymentIntent
      : ((paymentIntent as { id?: string } | null)?.id ?? null);
  return id ? `pass:${id}` : null;
}

async function must(
  op: Promise<{ ok: boolean; detail?: string }>,
  what: string,
): Promise<void> {
  const r = await op;
  if (!r.ok) throw new Error(`${what} failed: ${r.detail ?? "write refused"}`);
}

export async function POST(req: Request) {
  const status = billingStatus();
  const stripe = getStripe();
  if (!stripe || !status.webhookReady) {
    return new Response("Stripe webhook is not configured.", { status: 503 });
  }

  const signature = req.headers.get("stripe-signature");
  if (!signature) return new Response("No signature.", { status: 400 });

  const raw = await req.text();
  let event: Stripe.Event;
  try {
    event = stripe.webhooks.constructEvent(raw, signature, stripeEnv().webhookSecret);
  } catch (err) {
    // an unverifiable event is not an event
    console.error("stripe signature check failed", (err as Error)?.message);
    return new Response("Bad signature.", { status: 400 });
  }

  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const s = event.data.object as Stripe.Checkout.Session;
        const userId = s.metadata?.user_id ?? s.client_reference_id ?? null;
        const customerId = typeof s.customer === "string" ? s.customer : null;

        if (s.mode === "payment") {
          // the Game Night Pass: 24 hours, added to whatever is already there
          await must(
            applyBilling({
              eventId: passKey(s.payment_intent) ?? event.id,
              userId,
              customerId,
              status: "pass",
              source: "game_night_pass",
              extendHours: 24,
            }),
            "day pass",
          );
          break;
        }

        const subId = typeof s.subscription === "string" ? s.subscription : null;
        const sub = subId ? await stripe.subscriptions.retrieve(subId) : null;
        await must(
          applyBilling({
            eventId: event.id,
            userId,
            customerId,
            subscriptionId: subId,
            status: sub?.status ?? "active",
            premiumUntil: sub ? periodEnd(sub) : null,
            source: "stripe_subscription",
          }),
          "checkout subscription",
        );
        break;
      }

      /* THE PASS, ANNOUNCED THE OTHER WAY. An endpoint subscribed to
         payment_intent.succeeded but not checkout.session.completed sent this
         instead, and it fell to `default: break` — answered 200, granted
         nothing, wrote nothing. The checkout deliberately puts user_id and
         plan on the payment intent, so everything needed is already here.
         Guarded on plan so a subscription's own payment intent, which settles
         through the invoice events below, cannot grant a pass. */
      case "payment_intent.succeeded": {
        const pi = event.data.object as Stripe.PaymentIntent;
        if (pi.metadata?.plan !== "pass") break;
        await must(
          applyBilling({
            eventId: passKey(pi.id) ?? event.id,
            userId: pi.metadata?.user_id ?? null,
            customerId: typeof pi.customer === "string" ? pi.customer : null,
            status: "pass",
            source: "game_night_pass",
            extendHours: 24,
          }),
          "day pass (payment_intent)",
        );
        break;
      }

      case "customer.subscription.created":
      case "customer.subscription.updated": {
        const sub = event.data.object as Stripe.Subscription;
        const customerId = typeof sub.customer === "string" ? sub.customer : null;

        if (DEAD.has(sub.status) && customerId) {
          await must(revokeBilling(event.id, customerId, sub.status), "revoke");
          break;
        }
        // past_due keeps the access it has already paid for while Stripe
        // retries; the date on the profile is what decides, not the status
        await must(
          applyBilling({
            eventId: event.id,
            userId: sub.metadata?.user_id ?? null,
            customerId,
            subscriptionId: sub.id,
            status: sub.status,
            premiumUntil: periodEnd(sub),
            source: "stripe_subscription",
          }),
          "subscription update",
        );
        break;
      }

      case "customer.subscription.deleted": {
        const sub = event.data.object as Stripe.Subscription;
        const customerId = typeof sub.customer === "string" ? sub.customer : null;
        if (customerId) await must(revokeBilling(event.id, customerId, "canceled"), "cancel");
        break;
      }

      case "invoice.paid":
      case "invoice.payment_succeeded": {
        const inv = event.data.object as Stripe.Invoice;
        const subId =
          (inv as unknown as { subscription?: string | { id: string } }).subscription ?? null;
        const id = typeof subId === "string" ? subId : subId?.id ?? null;
        if (!id) break;
        const sub = await stripe.subscriptions.retrieve(id);
        await must(
          applyBilling({
            eventId: event.id,
            userId: sub.metadata?.user_id ?? null,
            customerId: typeof sub.customer === "string" ? sub.customer : null,
            subscriptionId: sub.id,
            status: sub.status,
            premiumUntil: periodEnd(sub),
            source: "stripe_subscription",
          }),
          "invoice paid",
        );
        break;
      }

      case "invoice.payment_failed": {
        const inv = event.data.object as Stripe.Invoice;
        const customerId = typeof inv.customer === "string" ? inv.customer : null;
        if (customerId) {
          // status only. They keep what they have paid for until it lapses.
          await must(
            applyBilling({ eventId: event.id, customerId, status: "past_due" }),
            "payment failed",
          );
        }
        break;
      }

      default:
        break;
    }
  } catch (err) {
    // 500 makes Stripe retry, which is what we want for a transient failure.
    // It is also written down, so the console can show it without anyone
    // having to go digging through log drains.
    const why = (err as Error)?.message ?? String(err);
    console.error("stripe webhook handling failed", event.type, err);
    await logBillingFailure(event.id, event.type, why);
    /* The reason goes in the RESPONSE BODY too. Stripe shows it against the
       delivery attempt, which is where somebody who just pressed Resend is
       already looking — and it is the one place that still says something
       when the failure is the billing secret itself, since logBillingFailure
       needs that same secret to write its row. Only Stripe can reach this
       endpoint with a valid signature, so this is not a public surface. */
    return new Response(`Handler failed: ${why}`, { status: 500 });
  }

  return NextResponse.json({ received: true });
}
