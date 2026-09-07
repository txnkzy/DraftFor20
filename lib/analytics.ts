"use client";

/**
 * Conversion tracking, off by default.
 *
 * The privacy policy says this site does not watch you, and that has been
 * true. Adding GA4 makes it conditionally untrue, so the condition is the
 * whole design: Consent Mode v2 is initialised with EVERY storage type
 * DENIED, for everyone, everywhere — not only where the law insists — and
 * gtag.js is not fetched at all until somebody actively accepts. Decline, or
 * simply ignore the banner, and the site behaves exactly as the policy
 * describes: no third-party request, no cookie, no identifier.
 *
 * That is stricter than US law requires. It is the only version of this worth
 * shipping on a product whose pitch includes not tracking people.
 */

export const CONSENT_KEY = "df20:consent";
export type Consent = "granted" | "denied";

const listeners = new Set<() => void>();

export function readConsent(): Consent | null {
  try {
    const v = localStorage.getItem(CONSENT_KEY);
    return v === "granted" || v === "denied" ? v : null;
  } catch {
    return null;
  }
}

export function setConsent(v: Consent) {
  try {
    localStorage.setItem(CONSENT_KEY, v);
  } catch {
    /* private browsing: the choice just won't survive a refresh */
  }
  applyConsent(v);
  listeners.forEach((l) => l());
}

export function onConsentChange(cb: () => void): () => void {
  listeners.add(cb);
  return () => {
    listeners.delete(cb);
  };
}

/* ── the gtag plumbing ──────────────────────────────────────────────────── */

type Gtag = (...args: unknown[]) => void;
interface W extends Window {
  dataLayer?: unknown[];
  gtag?: Gtag;
}

function w(): W | null {
  return typeof window === "undefined" ? null : (window as W);
}

/** Queue commands before the script exists; gtag.js drains dataLayer on load. */
export function gtag(...args: unknown[]) {
  const win = w();
  if (!win) return;
  win.dataLayer = win.dataLayer ?? [];
  win.dataLayer.push(args);
}

/** Called once, as early as possible, BEFORE any measurement can happen. */
export function initConsentDefaults() {
  gtag("consent", "default", {
    ad_storage: "denied",
    ad_user_data: "denied",
    ad_personalization: "denied",
    analytics_storage: "denied",
    functionality_storage: "denied",
    personalization_storage: "denied",
    security_storage: "granted",
    wait_for_update: 500,
  });
}

function applyConsent(v: Consent) {
  gtag("consent", "update", {
    ad_storage: v,
    ad_user_data: v,
    ad_personalization: v,
    analytics_storage: v,
    functionality_storage: v,
    personalization_storage: v,
  });
}

/* ── the funnel ─────────────────────────────────────────────────────────────
   Five events, chosen to answer one question: how many people who arrive end
   up in a draft. Nothing carries a display name, a room title, a pick, an
   email or a room code — only the shape of what happened. */

export type FunnelEvent =
  | "sign_up"
  | "room_created"
  | "draft_completed"
  | "purchase";

export function track(event: FunnelEvent, params: Record<string, string | number> = {}) {
  // A no-op until consent exists. Nothing is buffered for later replay:
  // events from before somebody agreed to be measured are not ours to keep.
  if (readConsent() !== "granted") return;
  gtag("event", event, params);
}
