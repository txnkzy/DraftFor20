import "server-only";
import { createClient } from "@supabase/supabase-js";
import { stripeEnv } from "./stripe";

/**
 * How billing writes to Postgres without a service-role key.
 *
 * The README's rule stands: the service role key is not used by this app. The
 * webhook has no user session, so it authenticates to a single SECURITY
 * DEFINER function with a shared secret that can do exactly one thing — move
 * a subscription date on a profile. Same pattern as the Wikipedia cache
 * writer, same reasoning: the blast radius of the secret is the feature.
 */
function client() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) return null;
  return createClient(url, key, { auth: { persistSession: false } });
}

export interface BillingWrite {
  eventId: string | null;
  userId?: string | null;
  customerId?: string | null;
  subscriptionId?: string | null;
  status?: string | null;
  premiumUntil?: Date | null;
  source?: "stripe_subscription" | "game_night_pass" | null;
  /** the pass adds hours rather than setting a date */
  extendHours?: number | null;
}

export async function applyBilling(w: BillingWrite): Promise<{ ok: boolean; detail?: string }> {
  const sb = client();
  const secret = stripeEnv().billingSecret;
  if (!sb || !secret) return { ok: false, detail: "billing writes are not configured" };

  const { data, error } = await sb.rpc("df20_apply_billing_event", {
    p_secret: secret,
    p_event_id: w.eventId,
    p_user_id: w.userId ?? null,
    p_customer_id: w.customerId ?? null,
    p_subscription_id: w.subscriptionId ?? null,
    p_status: w.status ?? null,
    p_premium_until: w.premiumUntil ? w.premiumUntil.toISOString() : null,
    p_source: w.source ?? null,
    p_extend_hours: w.extendHours ?? null,
  });
  if (error) return { ok: false, detail: error.message };

  /* A REFUSAL IS NOT A SUCCESS. df20_apply_billing_event answers
     {"matched": false} when it cannot tie the event to a profile, and it
     returns that BEFORE writing the billing_events row — so a correctly
     signed event for an account it cannot find granted nothing and left no
     trace anywhere. Reported as a failure so the caller logs it and Stripe
     is told to try again. A duplicate is genuinely fine: that is the
     idempotency key doing its job on a retry. */
  const r = (data ?? {}) as { matched?: boolean; duplicate?: boolean };
  if (r.matched === false) {
    return {
      ok: false,
      detail:
        "no profile matched this event — checked the checkout's user_id and the stored stripe_customer_id",
    };
  }
  return { ok: true, detail: JSON.stringify(data) };
}

export async function revokeBilling(
  eventId: string | null,
  customerId: string,
  status: string,
): Promise<{ ok: boolean; detail?: string }> {
  const sb = client();
  const secret = stripeEnv().billingSecret;
  if (!sb || !secret) return { ok: false, detail: "billing writes are not configured" };

  const { data, error } = await sb.rpc("df20_revoke_premium", {
    p_secret: secret,
    p_event_id: eventId,
    p_customer_id: customerId,
    p_status: status,
  });
  if (error) return { ok: false, detail: error.message };
  return { ok: true, detail: JSON.stringify(data) };
}

/**
 * Record a webhook we could not act on.
 *
 * The only persisted error surface this app has, and it exists because
 * billing_events was already there for idempotency — two columns on a table
 * that had to exist anyway, rather than standing up error tracking nobody
 * asked for. Everything else is in Vercel's runtime logs.
 */
export async function logBillingFailure(
  eventId: string | null,
  kind: string,
  detail: string,
): Promise<void> {
  const sb = client();
  const secret = stripeEnv().billingSecret;
  if (!sb || !secret) return;
  try {
    await sb.rpc("df20_log_billing_failure", {
      p_secret: secret,
      p_event_id: eventId,
      p_kind: kind,
      p_detail: detail,
    });
  } catch {
    // a failure to record a failure is not worth a second failure
  }
}

/** The Stripe customer we already know about for this account, if any. */
export async function lookupCustomer(
  userId: string,
): Promise<{ email: string | null; customerId: string | null }> {
  const sb = client();
  const secret = stripeEnv().billingSecret;
  if (!sb || !secret) return { email: null, customerId: null };
  const { data, error } = await sb.rpc("df20_billing_profile", {
    p_secret: secret,
    p_user_id: userId,
  });
  if (error || !data) return { email: null, customerId: null };
  const d = data as { email?: string | null; customer_id?: string | null };
  return { email: d.email ?? null, customerId: d.customer_id ?? null };
}
