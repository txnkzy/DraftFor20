import "server-only";
import Stripe from "stripe";
import { SITE_URL } from "@/lib/site";
import { RECURRING, type PlanId } from "@/lib/plans";

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
  weekPriceId: string;
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
    weekPriceId: read("STRIPE_WEEK_PRICE_ID"),
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
  /** the monthly subscription has a price id */
  subscription: boolean;
  /** the weekly subscription has a price id */
  week: boolean;
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
  if (!e.weekPriceId) missing.push("STRIPE_WEEK_PRICE_ID");
  if (!e.passPriceId) missing.push("STRIPE_PASS_PRICE_ID");
  if (!e.webhookSecret) missing.push("STRIPE_WEBHOOK_SECRET");
  if (!e.billingSecret) missing.push("DF20_BILLING_SECRET");

  /* Each plan stands on its own. A missing STRIPE_WEEK_PRICE_ID hides the
     week card and leaves the other two buyable, rather than reading as "the
     whole shop is shut" — which is what listing it in `missing` would imply
     if anything gated on that list. Nothing does; it is for the operator. */
  const hasKey = Boolean(e.secretKey);
  return {
    configured: hasKey && Boolean(e.priceId || e.weekPriceId || e.passPriceId),
    subscription: hasKey && Boolean(e.priceId),
    week: hasKey && Boolean(e.weekPriceId),
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

/* ── what Stripe actually charges ──────────────────────────────────────────
 *
 * The prices on the page were a hand-kept copy of the prices in Stripe, and
 * nothing checked that the two agreed. Raise one without the other and a
 * customer reads $1 on the card, presses it, and Stripe asks them for $2.99
 * — which is the single worst bug this surface can have, because it looks
 * exactly like a bait and switch and the customer is right to say so.
 *
 * So the number comes from the Price object. The literals in PLANS stay as
 * the fallback for an unconfigured install, which is also the only thing a
 * local dev sees.
 *
 * Memoised for five minutes. Prices change roughly never, the config
 * endpoint is hit on every render of every upgrade surface, and three API
 * calls per render would be three chances to be rate-limited into showing
 * the fallback.
 */
export interface LivePrice {
  price: string;
  period: string;
}

let priceMemo: { at: number; value: Record<string, LivePrice> } | null = null;
const PRICE_TTL_MS = 5 * 60_000;

/** "/month", "for 24 hours" — Stripe's own recurrence, in this site's words. */
function periodOf(price: Stripe.Price): string {
  const r = price.recurring;
  if (!r) return "for 24 hours";
  const n = r.interval_count ?? 1;
  if (n === 1) return `/${r.interval}`;
  return `every ${n} ${r.interval}s`;
}

/** 299 -> "$2.99", 500 -> "$5". Trailing ".00" is noise on a price tag. */
function amountOf(price: Stripe.Price): string | null {
  if (typeof price.unit_amount !== "number") return null;
  const s = new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: (price.currency || "usd").toUpperCase(),
    minimumFractionDigits: price.unit_amount % 100 === 0 ? 0 : 2,
  }).format(price.unit_amount / 100);
  return s;
}

/**
 * planId -> what Stripe will charge. Missing keys mean "ask PLANS instead":
 * no key set, or the lookup failed. A failed lookup must never blank a price
 * or block the page — a slightly stale number is recoverable, an empty one is
 * not.
 */
export async function livePlanPrices(): Promise<Record<string, LivePrice>> {
  const now = Date.now();
  if (priceMemo && now - priceMemo.at < PRICE_TTL_MS) return priceMemo.value;

  const stripe = getStripe();
  const e = stripeEnv();
  const wanted: [PlanId, string, string][] = [
    ["premium", e.priceId, "STRIPE_PRICE_ID"],
    ["week", e.weekPriceId, "STRIPE_WEEK_PRICE_ID"],
    ["pass", e.passPriceId, "STRIPE_PASS_PRICE_ID"],
  ];
  const out: Record<string, LivePrice> = {};
  if (!stripe) return out;

  await Promise.all(
    wanted.map(async ([plan, id, envName]) => {
      if (!id) return;
      try {
        const price = await stripe.prices.retrieve(id);

        /* TWO WAYS A PRICE CAN BE WRONG RATHER THAN MISSING, both of which
           render a perfectly convincing page and then fail at Checkout.
           Stripe prices are immutable, so changing one means creating a new
           one and archiving the old — and an env var still pointing at the
           archived one retrieves fine, shows the OLD number, and refuses the
           session. Shout about it where the operator will see it. */
        if (price.active === false) {
          console.error(
            `stripe price ${id} is ARCHIVED — ${envName} still points at it. ` +
              `The page will show its old amount and checkout will fail.`,
          );
        }
        const shouldRecur = RECURRING.has(plan);
        if (shouldRecur !== Boolean(price.recurring)) {
          console.error(
            `stripe price ${id} (${envName}) is ${price.recurring ? "recurring" : "one-off"}, ` +
              `but ${plan} is opened in ${shouldRecur ? "subscription" : "payment"} mode. ` +
              `Checkout will reject this.`,
          );
        }

        const amount = amountOf(price);
        if (amount) out[plan] = { price: amount, period: periodOf(price) };
      } catch (err) {
        console.error("stripe price lookup failed", plan, (err as Error)?.message);
      }
    }),
  );

  priceMemo = { at: now, value: out };
  return out;
}
