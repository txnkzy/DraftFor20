"use client";

import { usePathname } from "next/navigation";
import Script from "next/script";
import { useCallback, useEffect, useSyncExternalStore } from "react";
import {
  gtag,
  initConsentDefaults,
  onConsentChange,
  readConsent,
  setConsent,
  type Consent,
} from "@/lib/analytics";

const GA_ID = process.env.NEXT_PUBLIC_GA_ID ?? "";

/**
 * Measurement, and the banner that gates it.
 *
 * gtag.js is NOT rendered until somebody has said yes. That is the difference
 * between "we set the consent flags correctly" and "we made no third-party
 * request at all" — only the second is honest about a site whose privacy
 * policy says loading a page tells nobody you visited.
 *
 * Costs nothing when unconfigured: with no NEXT_PUBLIC_GA_ID the whole thing
 * renders null, so a fork or a preview deploy has no banner and no script.
 */
export function Analytics() {
  /* Same external-store pattern the seat token uses, for the same reason: the
     server render and the hydrating client render must agree on "no choice
     yet", and only then may the real value arrive. */
  const subscribe = useCallback((cb: () => void) => {
    const off = onConsentChange(cb);
    window.addEventListener("storage", cb);
    return () => {
      off();
      window.removeEventListener("storage", cb);
    };
  }, []);
  const consent: Consent | null = useSyncExternalStore(subscribe, readConsent, () => null);

  /* The server cannot know what this visitor already chose, so it renders the
     banner for everyone — which means a returning visitor who declined weeks
     ago watches it appear and vanish on every page load. This says "not on
     the server", so the banner only ever exists once the real answer does. */
  const mounted = useSyncExternalStore(
    () => () => {},
    () => true,
    () => false,
  );

  // denied, before anything is able to measure
  useEffect(() => initConsentDefaults(), []);

  /* NOT OVER A LIVE SURFACE. The banner is fixed to the bottom, which on a
     375px phone lands exactly on top of Raise and Pass while a bid clock is
     running. Asking somebody to answer a cookie question mid-auction is the
     wrong trade in both directions, so these routes never show it. Anyone who
     only ever arrives at a room link is therefore never measured — which is
     the safe direction to fail in, and the honest one. */
  const path = usePathname() ?? "";
  const liveSurface = /^\/(room|obs|vote|judge|setup)(\/|$)/.test(path);

  if (!GA_ID) return null;

  return (
    <>
      {consent === "granted" ? (
        <>
          <Script
            id="ga-src"
            strategy="afterInteractive"
            src={`https://www.googletagmanager.com/gtag/js?id=${GA_ID}`}
          />
          <Script id="ga-init" strategy="afterInteractive">
            {`window.dataLayer=window.dataLayer||[];
              function gtag(){dataLayer.push(arguments);}
              gtag('js', new Date());
              gtag('config', '${GA_ID}', { anonymize_ip: true });`}
          </Script>
        </>
      ) : null}

      {mounted && consent === null && !liveSurface ? <ConsentBanner /> : null}
    </>
  );
}

function ConsentBanner() {
  return (
    <div
      role="dialog"
      aria-label="Analytics consent"
      className="fixed inset-x-0 bottom-0 z-50 border-t bg-board px-4 py-3 rule"
    >
      <div className="mx-auto flex w-full max-w-3xl flex-col gap-3 sm:flex-row sm:items-center">
        {/* Four lines of copy plus two buttons ate ~180px off the bottom of
            every page on a 375px screen. The short form says the same thing;
            the full version is kept for screens with room for it. */}
        <p className="flex-1 text-[0.8125rem] leading-relaxed text-muted">
          <span className="text-ink">Measure how the site is doing?</span>{" "}
          <span className="sm:hidden">
            Google Analytics, only if you allow it. Decline and nothing loads.{" "}
          </span>
          <span className="hidden sm:inline">
            Google Analytics tells us how many people arrive and how many start a draft. Say no
            and nothing loads — no request, no cookie, no identifier. Either way the game is
            unchanged.{" "}
          </span>
          <a className="text-gold underline" href="/privacy">
            What we collect
          </a>
        </p>
        <div className="flex shrink-0 gap-2">
          <button
            type="button"
            className="btn btn-ghost h-11 px-4 text-[0.8125rem]"
            onClick={() => setConsent("denied")}
          >
            No thanks
          </button>
          <button
            type="button"
            className="btn btn-primary h-11 px-4 text-[0.8125rem]"
            onClick={() => {
              setConsent("granted");
              // the visit that granted it still counts
              gtag("event", "page_view");
            }}
          >
            Allow
          </button>
        </div>
      </div>
    </div>
  );
}
