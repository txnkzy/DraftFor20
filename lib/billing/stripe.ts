import "server-only";
import Stripe from "stripe";
import { SITE_URL } from "@/lib/site";

/**
 * Stripe, optional by design.
 *
 * There are no keys on this project yet, and the whole site has to keep
 * working without them. So nothing here throws on a missing variable: every
 * entry point asks `billingStatus()` first and the UI renders "payments
 * coming soon" instead of attempting a call that cannot succeed.
 *
 * Secrets are read from the environment on the server and never sent to a
 * browser. The only thing the client is ever told is which plans are
 * purchasable, as booleans.
 */
export interface StripeEnv {
  secretKey: string;
  webhookSecret: string;
  priceId: string;
  passPriceId: string;
  billingSecret: string;
  siteUrl: string;
}

function read(name: string): string {
  return (process.env[name] ?? "").trim();
}

export function stripeEnv(): StripeEnv {
  return {
    secretKey: read("STRIPE_SECRET_KEY"),
    webhookSecret: read("STRIPE_WEBHOOK_SECRET"),
    priceId: read("STRIPE_PRICE_ID"),
    passPriceId: read("STRIPE_PASS_PRICE_ID"),
    billingSecret: read("DF20_BILLING_SECRET"),
    // canonical www: the apex 308-redirects, and Stripe does not follow a
    // redirect on a return URL — it just lands the customer on one
    siteUrl: read("NEXT_PUBLIC_SITE_URL") || SITE_URL,
  };
}

export interface BillingStatus {
  /** any checkout at all is possible */
  configured: boolean;
  /** the $5/mo subscription has a price id */
  subscription: boolean;
  /** the 24-hour pass has a price id */
  pass: boolean;
  /** the webhook can verify signatures AND write to Postgres */
  webhookReady: boolean;
  /** why it is off, for the operator. Never shown to a visitor. */
  missing: string[];
}

export function billingStatus(): BillingStatus {
  const e = stripeEnv();
  const missing: string[] = [];
  if (!e.secretKey) missing.push("STRIPE_SECRET_KEY");
  if (!e.priceId) missing.push("STRIPE_PRICE_ID");
  if (!e.passPriceId) missing.push("STRIPE_PASS_PRICE_ID");
  if (!e.webhookSecret) missing.push("STRIPE_WEBHOOK_SECRET");
  if (!e.billingSecret) missing.push("DF20_BILLING_SECRET");

  const hasKey = Boolean(e.secretKey);
  return {
    configured: hasKey && Boolean(e.priceId || e.passPriceId),
    subscription: hasKey && Boolean(e.priceId),
    pass: hasKey && Boolean(e.passPriceId),
    webhookReady: Boolean(e.webhookSecret && e.billingSecret),
    missing,
  };
}

let cached: Stripe | null = null;

/** null when there is no secret key. Callers must handle null, not assume. */
export function getStripe(): Stripe | null {
  const key = stripeEnv().secretKey;
  if (!key) return null;
  if (!cached) cached = new Stripe(key);
  return cached;
}

/** Where Checkout comes back to. Absolute, because Stripe redirects to it. */
export function siteOrigin(req?: Request): string {
  const configured = stripeEnv().siteUrl;
  if (configured) return configured.replace(/\/+$/, "");
  if (req) {
    try {
      return new URL(req.url).origin;
    } catch {
      /* fall through */
    }
  }
  return SITE_URL;
}
