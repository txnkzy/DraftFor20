/**
 * ── SET THESE BEFORE YOU LAUNCH ────────────────────────────────────────────
 * The privacy policy and terms reference them. They are the only things in
 * the legal pages that depend on who is operating the service.
 */
/** Public origin, used by the sitemap, robots and OG tags. Set this when you
 *  point a real domain at the deploy. */
export const SITE_URL =
  process.env.NEXT_PUBLIC_SITE_URL?.replace(/\/$/, "") ?? "https://draftfor20.app";

export const OPERATOR = "DraftFor20";
export const CONTACT_EMAIL = "support@draftfor20.com";

/** Support line. Leave empty and every phone affordance stays hidden — do not
 *  put a number here until it actually rings somewhere. */
export const SUPPORT_PHONE = "";

/** tel: href for SUPPORT_PHONE, digits only with country code. */
export const SUPPORT_PHONE_HREF = SUPPORT_PHONE.replace(/[^\d+]/g, "");
export const JURISDICTION = "United States";

/** Last substantive revision of the legal pages. Bump when you edit them. */
export const LEGAL_UPDATED = "20 August 2026";

/** Rooms and everything in them are deleted after this long. Enforced by
 *  df20_purge_old_rooms() in supabase/migrations/0006_cron.sql. */
export const RETENTION_DAYS = 90;
