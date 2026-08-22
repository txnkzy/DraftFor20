"use client";

import { useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Padlock } from "./Padlock";
import { accessToken } from "@/lib/auth";
import type { PlanId } from "@/lib/premium";

interface BillingConfig {
  configured: boolean;
  plans: Record<PlanId, { price: string; period: string; available: boolean }>;
}

const COPY: Record<PlanId, { title: string; line: string; points: string[]; note: string }> = {
  premium: {
    title: "Premium",
    line: "Everything, for as long as you keep it.",
    points: [
      "Content Creator rooms — the 9:16 board, record mode, the OBS browser source",
      "Live audience tally while the vote is running",
      "Your full scouting report, not just the last five drafts",
      "Card branding: your logo, your accent, your handle",
    ],
    note: "Cancel any time from your profile. Takes effect at the end of the period you have paid for.",
  },
  pass: {
    title: "Game Night Pass",
    line: "One night, no subscription.",
    points: [
      "The same unlocks as Premium",
      "Runs for 24 hours from the moment it is bought",
      "Stacks on the end of a subscription rather than overwriting it",
      "One payment — nothing recurring, nothing to cancel",
    ],
    note: "Bought at 8pm, yours until 8pm tomorrow.",
  },
};

/**
 * The two ways to pay, and the one honest state when neither is switched on.
 *
 * The config endpoint is asked BEFORE a button is drawn, so with no Stripe
 * keys there is no checkout call to fail — the cards render priced and
 * explained, with "payments coming soon" where the button would be.
 */
export function PlanCards({
  signedIn,
  verified = true,
  returnTo = "/profile",
}: {
  signedIn: boolean;
  verified?: boolean;
  returnTo?: string;
}) {
  const [cfg, setCfg] = useState<BillingConfig | null>(null);
  const [busy, setBusy] = useState<PlanId | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let off = false;
    void (async () => {
      try {
        const res = await fetch("/api/billing/config", { cache: "no-store" });
        const d = (await res.json()) as BillingConfig;
        if (!off) setCfg(d);
      } catch {
        if (!off) {
          setCfg({
            configured: false,
            plans: {
              premium: { price: "$5", period: "/month", available: false },
              pass: { price: "$1", period: "for 24 hours", available: false },
            },
          });
        }
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
      if (d.configured === false) {
        setCfg((c) => (c ? { ...c, configured: false } : c));
        setBusy(null);
        return;
      }
      if (d.message === "DF20_EMAIL_UNVERIFIED") {
        setError("Confirm your email address first — we sent you a link when you signed up.");
        setBusy(null);
        return;
      }
      if (!res.ok || !d.url) {
        setError(d.message ?? "Checkout could not start. Nothing was charged.");
        setBusy(null);
        return;
      }
      window.location.assign(d.url);
    } catch {
      setError("Checkout could not start. Nothing was charged.");
      setBusy(null);
    }
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="grid gap-4 sm:grid-cols-2">
        {(["premium", "pass"] as const).map((id) => {
          const c = COPY[id];
          const p = cfg?.plans[id];
          const live = Boolean(cfg?.configured && p?.available);
          return (
            <section
              key={id}
              className="flex flex-col border p-5 rule"
              style={id === "premium" ? { borderColor: "var(--color-coral)" } : undefined}
            >
              <h2 className="type-display text-[1.25rem]">{c.title}</h2>
              <p className="mt-1 text-[0.875rem] text-muted">{c.line}</p>

              <p className="mt-4 flex items-baseline gap-1.5">
                <span className="type-num text-[2.5rem] leading-none text-gold">
                  {p?.price ?? (id === "premium" ? "$5" : "$1")}
                </span>
                <span className="type-label text-muted">
                  {p?.period ?? (id === "premium" ? "/month" : "for 24 hours")}
                </span>
              </p>

              <ul className="mt-4 flex flex-1 flex-col gap-2">
                {c.points.map((pt) => (
                  <li key={pt} className="flex gap-2 text-[0.875rem] leading-snug text-muted">
                    <span className="shrink-0 text-teal">·</span>
                    {pt}
                  </li>
                ))}
              </ul>

              <div className="mt-5">
                {!cfg ? (
                  <p className="type-label text-muted">checking what&apos;s available</p>
                ) : !live ? (
                  <p className="type-label flex items-center gap-1.5 text-muted">
                    <Padlock /> payments coming soon
                  </p>
                ) : !signedIn ? (
                  <a href="/signup" className="btn btn-ghost h-11 w-full px-4 text-[0.8125rem]">
                    Make an account first
                  </a>
                ) : !verified ? (
                  <p className="type-label text-muted">confirm your email first</p>
                ) : (
                  <Button
                    variant={id === "premium" ? "primary" : "ghost"}
                    className="w-full"
                    disabled={busy !== null}
                    onClick={() => void checkout(id)}
                  >
                    {busy === id
                      ? "Opening checkout"
                      : id === "premium"
                        ? "Subscribe"
                        : "Buy 24-hour pass"}
                  </Button>
                )}
              </div>

              <p className="mt-3 text-[0.75rem] leading-relaxed text-muted">{c.note}</p>
            </section>
          );
        })}
      </div>

      {error ? <p className="text-[0.8125rem] text-coral">{error}</p> : null}

      <p className="text-[0.75rem] leading-relaxed text-muted">
        Card details are handled by Stripe on their own checkout page and never touch this site.
        Play money in the game is not real money and nothing here is a wager.
      </p>
    </div>
  );
}
