"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Padlock } from "./Padlock";
import { accessToken, signInHref, signUpHref } from "@/lib/auth";
import type { PlanId } from "@/lib/premium";

interface BillingConfig {
  configured: boolean;
  subscription: boolean;
  pass: boolean;
  plans: Record<PlanId, { price: string; period: string; available: boolean }>;
}

/**
 * The upgrade path, and the graceful-degradation story in one component.
 *
 * It asks the server what billing can actually do BEFORE it draws a button.
 * With no Stripe keys set the answer is configured:false and it renders
 * "payments coming soon" — a checkout call is never attempted, so there is
 * no request to fail, no 500 and nothing for a visitor to hit.
 */
export function UpgradeCard({
  feature,
  signedIn,
  compact = false,
}: {
  feature: string;
  signedIn: boolean;
  compact?: boolean;
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
        // treat an unreachable config endpoint exactly like unconfigured
        if (!off) setCfg({
          configured: false, subscription: false, pass: false,
          plans: {
            premium: { price: "$5", period: "/month", available: false },
            pass: { price: "$2", period: "for 24 hours", available: false },
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
        body: JSON.stringify({ plan, returnTo: window.location.pathname }),
      });
      const d = (await res.json()) as { url?: string; configured?: boolean; message?: string };
      if (d.configured === false) {
        // the server had the last word and it is still not switched on
        setCfg((c) => (c ? { ...c, configured: false } : c));
        setBusy(null);
        return;
      }
      if (!res.ok || !d.url) {
        setError(d.message ?? "Checkout could not start.");
        setBusy(null);
        return;
      }
      window.location.href = d.url;
    } catch {
      setError("Checkout could not start.");
      setBusy(null);
    }
  }

  const box = `border p-4 ${compact ? "" : "mt-4"} rule`;

  if (!signedIn) {
    return (
      <div className={box}>
        <p className="type-label flex items-center gap-1.5 text-muted">
          <Padlock /> {feature} is a premium feature
        </p>
        <p className="mt-2 text-[0.875rem] leading-relaxed text-muted">
          Premium is tied to an account. Making one is free and takes a moment.
        </p>
        <div className="mt-4 flex flex-wrap gap-2">
          <Link href={signUpHref("/profile")} className="btn btn-primary h-11 px-4 text-[0.8125rem]">
            Create an account
          </Link>
          <Link href={signInHref("/profile")} className="btn btn-ghost h-11 px-4 text-[0.8125rem]">
            I already have one
          </Link>
        </div>
      </div>
    );
  }

  if (!cfg) {
    return (
      <div className={box}>
        <p className="type-label text-muted">checking what&apos;s available</p>
      </div>
    );
  }

  if (!cfg.configured) {
    return (
      <div className={box}>
        <p className="type-label flex items-center gap-1.5 text-muted">
          <Padlock /> {feature} &middot; payments coming soon
        </p>
        <p className="mt-2 text-[0.875rem] leading-relaxed text-muted">
          Premium isn&apos;t on sale yet. Nothing is broken and nothing free has changed —
          every category on the shelf, every draft and every results card still works exactly
          as it does now. This unlocks when checkout opens.
        </p>
        <p className="type-label mt-3 text-muted">
          {cfg.plans.premium.price}
          <span className="text-muted">{cfg.plans.premium.period}</span>
          {" · "}
          {cfg.plans.pass.price}
          <span className="text-muted"> {cfg.plans.pass.period}</span>
        </p>
      </div>
    );
  }

  return (
    <div className={box}>
      <p className="type-label flex items-center gap-1.5 text-muted">
        <Padlock /> unlock {feature}
      </p>
      <div className="mt-3 flex flex-col gap-2 sm:flex-row">
        {cfg.plans.premium.available ? (
          <Button
            variant="primary"
            className="flex-1"
            disabled={busy !== null}
            onClick={() => void checkout("premium")}
          >
            {busy === "premium" ? "Opening checkout" : `Premium ${cfg.plans.premium.price}${cfg.plans.premium.period}`}
          </Button>
        ) : null}
        {cfg.plans.pass.available ? (
          <Button
            variant="ghost"
            className="flex-1"
            disabled={busy !== null}
            onClick={() => void checkout("pass")}
          >
            {busy === "pass" ? "Opening checkout" : `Game night pass ${cfg.plans.pass.price}`}
          </Button>
        ) : null}
      </div>
      <p className="mt-3 text-[0.75rem] leading-relaxed text-muted">
        The pass is one payment for 24 hours of everything premium. Card details are handled by
        Stripe on their own page; they never touch this site.
      </p>
      {error ? <p className="mt-2 text-[0.8125rem] text-coral">{error}</p> : null}
    </div>
  );
}
