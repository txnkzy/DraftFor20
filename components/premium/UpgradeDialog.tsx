"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Padlock } from "./Padlock";
import { accessToken } from "@/lib/auth";
import type { PlanId } from "@/lib/premium";

interface Config {
  configured: boolean;
  plans: Record<PlanId, { price: string; period: string; available: boolean }>;
}

/**
 * What a locked control does when you click it.
 *
 * A padlock that does nothing teaches people the feature is broken. This
 * names the specific thing they just reached for, shows what else comes with
 * it, and puts both prices one click away — the pass especially, because "one
 * dollar for tonight" is a much smaller decision than a subscription and it
 * is usually the honest answer to "I just want to try this once".
 */
const ALSO = [
  "Type any category you like, or have someone else build the list",
  "Reuse decks you have saved",
  "Content Creator rooms: the 9:16 board, record mode, the OBS source",
  "Let your audience vote on who drafted better",
  "Your full scouting report, and your own branding on the results card",
];

export function UpgradeDialog({
  feature,
  why,
  signedIn,
  returnTo,
  onClose,
}: {
  /** the thing they just clicked, named exactly */
  feature: string;
  /** one line on why it is worth having */
  why: string;
  signedIn: boolean;
  returnTo: string;
  onClose: () => void;
}) {
  const [cfg, setCfg] = useState<Config | null>(null);
  const [busy, setBusy] = useState<PlanId | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  useEffect(() => {
    let off = false;
    void (async () => {
      try {
        const res = await fetch("/api/billing/config", { cache: "no-store" });
        const d = (await res.json()) as Config;
        if (!off) setCfg(d);
      } catch {
        if (!off) setCfg({
          configured: false,
          plans: {
            premium: { price: "$5", period: "/month", available: false },
            pass: { price: "$1", period: "for 24 hours", available: false },
          },
        });
      }
    })();
    return () => { off = true; };
  }, []);

  async function checkout(plan: PlanId) {
    setBusy(plan);
    setError(null);
    try {
      const token = await accessToken();
      const res = await fetch("/api/billing/checkout", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          ...(token ? { authorization: `Bearer ${token}` } : {}),
        },
        body: JSON.stringify({ plan, returnTo }),
      });
      const d = (await res.json()) as { url?: string; configured?: boolean; message?: string };
      if (d.url) {
        window.location.assign(d.url);
        return;
      }
      if (d.configured === false) {
        setCfg((c) => (c ? { ...c, configured: false } : c));
      } else if (d.message === "DF20_EMAIL_UNVERIFIED") {
        setError("Confirm your email first — we sent you a link when you signed up.");
      } else {
        setError(d.message ?? "Checkout could not start. Nothing was charged.");
      }
      setBusy(null);
    } catch {
      setError("Checkout could not start. Nothing was charged.");
      setBusy(null);
    }
  }

  const live = Boolean(cfg?.configured);

  return (
    <div
      className="fixed inset-0 z-50 grid place-items-center px-4"
      style={{ background: "rgba(10,11,15,0.82)" }}
      role="dialog"
      aria-modal="true"
      aria-label={`${feature} is a premium feature`}
      onClick={onClose}
    >
      <div
        className="panel w-full max-w-md p-6"
        style={{ borderRadius: "var(--radius-card)" }}
        onClick={(e) => e.stopPropagation()}
      >
        <p className="type-label flex items-center gap-1.5 text-muted">
          <Padlock /> premium feature
        </p>
        <h2 className="type-display mt-2 text-[1.5rem] leading-tight">{feature}</h2>
        <p className="mt-2 text-[0.9375rem] leading-relaxed text-muted">{why}</p>

        <p className="type-label mt-5 text-muted">it also unlocks</p>
        <ul className="mt-2 flex flex-col gap-1.5">
          {ALSO.map((a) => (
            <li key={a} className="flex gap-2 text-[0.8125rem] leading-snug text-muted">
              <span className="shrink-0 text-teal">&middot;</span>
              {a}
            </li>
          ))}
        </ul>

        <div className="mt-6 flex flex-col gap-2">
          {!signedIn ? (
            <>
              <Link href="/signup" className="btn btn-primary h-12 px-4 text-[0.875rem]">
                Make a free account
              </Link>
              <p className="text-[0.75rem] text-muted">
                Premium is tied to an account. Making one is free.
              </p>
            </>
          ) : !cfg ? (
            <p className="type-label text-muted">checking what&apos;s available</p>
          ) : !live ? (
            <p className="type-label text-muted">
              payments are not switched on yet &middot; nothing to buy today
            </p>
          ) : (
            <>
              <Button
                variant="primary"
                className="w-full"
                disabled={busy !== null}
                onClick={() => void checkout("pass")}
              >
                {busy === "pass"
                  ? "Opening checkout"
                  : `Just tonight — ${cfg.plans.pass.price} for 24 hours`}
              </Button>
              <Button
                variant="ghost"
                className="w-full"
                disabled={busy !== null}
                onClick={() => void checkout("premium")}
              >
                {busy === "premium"
                  ? "Opening checkout"
                  : `Premium — ${cfg.plans.premium.price}${cfg.plans.premium.period}`}
              </Button>
            </>
          )}

          {error ? <p className="text-[0.8125rem] text-coral">{error}</p> : null}

          <button className="type-label mt-1 text-muted hover:text-ink" onClick={onClose}>
            not now
          </button>
        </div>
      </div>
    </div>
  );
}

/** Shared trigger: a padlocked control that opens the dialog when clicked. */
export function useUpgradeDialog() {
  const [open, setOpen] = useState<{ feature: string; why: string } | null>(null);
  return {
    open,
    ask: (feature: string, why: string) => setOpen({ feature, why }),
    close: () => setOpen(null),
  };
}
