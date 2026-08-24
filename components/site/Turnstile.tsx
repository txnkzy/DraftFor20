"use client";

import { useEffect, useRef, useState } from "react";

/**
 * Cloudflare Turnstile, rendered only when a site key exists.
 *
 * With no key configured this renders nothing and reports an empty token —
 * the server then records the outcome as "skipped" and lets the signup
 * through. An anti-bot measure that has not been set up yet must not be the
 * reason a real person cannot make an account.
 *
 * Passive by design: most visitors see a checkbox settle by itself and are
 * never asked to identify a bus.
 */
declare global {
  interface Window {
    turnstile?: {
      render: (el: HTMLElement, opts: Record<string, unknown>) => string;
      remove: (id: string) => void;
    };
  }
}

const SCRIPT = "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";

export function Turnstile({ onToken }: { onToken: (token: string) => void }) {
  const box = useRef<HTMLDivElement>(null);
  const [failed, setFailed] = useState(false);
  const siteKey = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY;

  useEffect(() => {
    if (!siteKey || !box.current) return;
    let widgetId: string | undefined;
    let cancelled = false;

    const mount = () => {
      if (cancelled || !box.current || !window.turnstile) return;
      widgetId = window.turnstile.render(box.current, {
        sitekey: siteKey,
        theme: "dark",
        callback: (t: string) => onToken(t),
        "error-callback": () => setFailed(true),
        "expired-callback": () => onToken(""),
      });
    };

    if (window.turnstile) {
      mount();
    } else {
      const existing = document.querySelector<HTMLScriptElement>(`script[src="${SCRIPT}"]`);
      const el = existing ?? document.createElement("script");
      if (!existing) {
        el.src = SCRIPT;
        el.async = true;
        document.head.appendChild(el);
      }
      el.addEventListener("load", mount);
      el.addEventListener("error", () => setFailed(true));
    }

    return () => {
      cancelled = true;
      if (widgetId && window.turnstile) {
        try {
          window.turnstile.remove(widgetId);
        } catch {
          /* already gone */
        }
      }
    };
  }, [siteKey, onToken]);

  if (!siteKey) return null;

  return (
    <div>
      <div ref={box} />
      {failed ? (
        <p className="mt-2 text-[0.75rem] text-muted">
          The bot check could not load. You can still sign up.
        </p>
      ) : null}
    </div>
  );
}
