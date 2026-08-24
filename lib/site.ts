/**
 * ── SET THESE BEFORE YOU LAUNCH ────────────────────────────────────────────
 * The privacy policy and terms reference them. They are the only things in
 * the legal pages that depend on who is operating the service.
 */
/**
 * Public origin. Used by the sitemap, robots, OG tags, the export card's
 * watermark and Stripe's return URLs.
 *
 * The apex 308-redirects to www at Cloudflare, so www IS the canonical origin
 * and the fallback says so. Anything that has to match exactly — Supabase's
 * redirect allowlist, Stripe's webhook endpoint — must use the www form or it
 * will be handed a redirect it does not follow.
 *
 * NEXT_PUBLIC_ is inlined at BUILD time, so changing this on Vercel does
 * nothing until the next deploy.
 */
export const SITE_URL =
  process.env.NEXT_PUBLIC_SITE_URL?.replace(/\/$/, "") ?? "https://www.draftfor20.com";

export const OPERATOR = "DraftFor20";
export const CONTACT_EMAIL = "support@draftfor20.com";

/** Support is email-only and deliberately so. The phone number on card
 *  receipts is a Stripe business-profile field, set in their dashboard — it is
 *  not rendered by this app and there is no constant for it here. */
export const JURISDICTION = "United States";

/** Last substantive revision of the legal pages. Bump when you edit them. */
export const LEGAL_UPDATED = "20 August 2026";

/** Rooms and everything in them are deleted after this long. Enforced by
 *  df20_purge_old_rooms() in supabase/migrations/0006_cron.sql. */
export const RETENTION_DAYS = 90;
