"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Padlock } from "./Padlock";
import { accessToken } from "@/lib/auth";
import { remaining } from "@/lib/billing/countdown";

interface Premium {
  active: boolean;
  until: string | null;
  source: string | null;
  status: string | null;
  has_customer?: boolean;
}

const SOURCE_LABEL: Record<string, string> = {
  stripe_subscription: "Premium subscription",
  game_night_pass: "Game Night Pass",
  admin_grant: "Granted access",
};

/**
 * The label lives in state and is written by the interval, never computed
 * during render: reading the clock while rendering is impure, and React is
 * free to re-render whenever it likes.
 */
function useCountdown(until: string | null): string | null {
  const [label, setLabel] = useState<string | null>(null);

  useEffect(() => {
    if (!until) return;

    const update = () => {
      const next = remaining(until);
      setLabel(next);
      if (!next) clearInterval(id);   // it has run out; stop ticking
    };

    const id = setInterval(update, 1000);
    // the first reading is deferred by a microtask rather than run in the
    // effect body: a synchronous setState there cascades a second render
    queueMicrotask(update);
    return () => clearInterval(id);
  }, [until]);

  return label;
}

/**
 * What you are on, when it ends, and how to stop it.
 *
 * Cancellation is Stripe's hosted customer portal rather than a button here.
 * It is the standard route and the correct one: cancelling, changing a card,
 * reading past invoices and handling a failed payment are all one page Stripe
 * already maintains, and none of them are things this codebase should own.
 * A custom cancel button would be a worse copy of one of those four.
 */
export function BillingPanel({ premium }: { premium: Premium }) {
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const left = useCountdown(premium.active ? premium.until : null);

  async function openPortal() {
    setBusy(true);
    setMessage(null);
    try {
      const token = await accessToken();
      const res = await fetch("/api/billing/portal", {
        method: "POST",
        headers: token ? { authorization: `Bearer ${token}` } : {},
      });
      const d = (await res.json()) as { url?: string; configured?: boolean; message?: string };
      if (d.url) {
        window.location.assign(d.url);
        return;
      }
      setMessage(
        d.configured === false
          ? "Payments aren't switched on yet, so there's nothing to manage."
          : (d.message ?? "Could not open the billing portal."),
      );
    } catch {
      setMessage("Could not open the billing portal.");
    }
    setBusy(false);
  }

  if (!premium.active) {
    return (
      <section className="mt-9">
        <h2 className="type-display flex items-center gap-2 text-[1rem]">
          <Padlock size={13} /> Plan
        </h2>
        <div className="mt-3 border p-4 rule">
          <p className="type-label text-muted">free</p>
          <p className="mt-2 text-[0.875rem] leading-relaxed text-muted">
            Everything in the game works. Premium is for filming it: the Content Creator board,
            the OBS source, your full scouting report and card branding.
          </p>
          <Link href="/pricing" className="btn btn-primary mt-4 h-11 px-4 text-[0.8125rem]">
            See the options
          </Link>
        </div>
      </section>
    );
  }

  const label = SOURCE_LABEL[premium.source ?? ""] ?? "Premium";
  const isPass = premium.source === "game_night_pass";
  const isSub = premium.source === "stripe_subscription";
  const until = premium.until ? new Date(premium.until) : null;

  return (
    <section className="mt-9">
      <h2 className="type-display flex items-center gap-2 text-[1rem]">
        <Padlock size={13} open /> Plan
      </h2>
      <div className="mt-3 border p-4" style={{ borderColor: "var(--color-teal)" }}>
        <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
          <p className="type-label text-teal">{label}</p>
          {premium.status ? (
            <span className="type-label text-muted">{premium.status}</span>
          ) : null}
        </div>

        {left ? (
          <p className="type-num mt-2 text-[1.75rem] leading-none text-gold">
            {left} <span className="type-label text-muted">{isPass ? "left" : "until renewal"}</span>
          </p>
        ) : null}

        {until ? (
          <p className="type-num mt-1.5 text-[0.75rem] text-muted">
            {isPass ? "expires" : isSub ? "renews" : "runs until"} {until.toLocaleString()}
          </p>
        ) : null}

        <p className="mt-3 text-[0.875rem] leading-relaxed text-muted">
          Your results cards still carry the DraftFor20 watermark until you turn it off yourself,
          on any finished draft under &ldquo;card options&rdquo;.
        </p>

        {isSub || premium.has_customer ? (
          <>
            <div className="mt-4">
              <Button variant="ghost" size="sm" disabled={busy} onClick={() => void openPortal()}>
                {busy ? "Opening" : "Manage or cancel"}
              </Button>
            </div>
            <p className="mt-2 text-[0.75rem] leading-relaxed text-muted">
              Opens Stripe&apos;s billing portal — cancel, change your card, or download past
              invoices. Cancelling keeps your access until the end of the period you have paid for.
            </p>
          </>
        ) : isPass ? (
          <p className="mt-4 text-[0.75rem] leading-relaxed text-muted">
            A pass is a single payment. There is nothing recurring and nothing to cancel — it
            simply runs out. Buying another adds 24 hours to the end of this one.
          </p>
        ) : (
          <p className="mt-4 text-[0.75rem] leading-relaxed text-muted">
            This access was granted directly rather than bought, so there is no billing to manage.
          </p>
        )}

        {message ? <p className="mt-2 text-[0.8125rem] text-muted">{message}</p> : null}
      </div>
    </section>
  );
}
