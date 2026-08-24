"use client";

import Link from "next/link";
import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { Footer, Header, SetupNotice } from "@/components/site/Chrome";
import { BillingPanel } from "@/components/premium/BillingPanel";
import { PlanCards } from "@/components/premium/PlanCards";
import { accessToken, signInHref } from "@/lib/auth";
import { usePremium } from "@/lib/premium";
import { supabaseConfigured } from "@/lib/supabase/client";

/**
 * Billing, in one place.
 *
 * CANCELLING AND CARDS GO THROUGH STRIPE'S PORTAL, on purpose. Cancelling,
 * swapping a card, retrying a failed payment and downloading an invoice are
 * four pages Stripe already maintains, and building our own would mean
 * handling card details — PCI scope this project has deliberately never had.
 * The one button below opens all four.
 */
export function BillingClient() {
  if (!supabaseConfigured()) return <SetupNotice />;
  return <Billing />;
}

function Billing() {
  const premium = usePremium();
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

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
          ? "Payments aren't switched on yet, so there is nothing to manage."
          : (d.message ?? "Could not open the billing portal."),
      );
    } catch {
      setMessage("Could not open the billing portal.");
    }
    setBusy(false);
  }

  if (premium.loading) {
    return (
      <>
        <Header thin />
        <main className="mx-auto w-full max-w-2xl px-4 py-14">
          <p className="type-label text-muted">loading</p>
        </main>
      </>
    );
  }

  if (!premium.signedIn) {
    return (
      <>
        <Header thin />
        <main className="mx-auto w-full max-w-2xl px-4 py-14">
          <h1 className="type-display text-[1.75rem]">Billing</h1>
          <p className="mt-2 text-[0.9375rem] text-muted">Sign in to see your plan.</p>
          <Link href={signInHref("/profile/billing")}
                className="btn btn-primary mt-5 h-12 px-5 text-[0.875rem]">
            Sign in
          </Link>
        </main>
        <Footer />
      </>
    );
  }

  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-2xl px-4 py-10">
        <Link href="/profile" className="type-label text-muted hover:text-ink">
          &larr; back to profile
        </Link>
        <h1 className="type-display mt-2 text-[1.75rem]">Billing</h1>

        <BillingPanel premium={{
          active: premium.active,
          until: premium.until,
          source: premium.source,
          status: premium.status,
          has_customer: premium.hasCustomer,
        }} />

        {/* ── payment methods and cancellation ─────────────────────────── */}
        <section className="mt-9">
          <h2 className="type-display text-[1rem]">Payment methods &amp; cancellation</h2>
          <p className="mt-1.5 text-[0.875rem] leading-relaxed text-muted">
            Cards, cancellation, past invoices and retrying a failed payment all live in
            Stripe&apos;s billing portal. It opens with your account already loaded.
          </p>
          <ul className="mt-3 flex flex-col">
            {[
              "Add, replace or remove a saved card",
              "Cancel a subscription — access continues to the end of the period you paid for",
              "Download every past invoice and receipt",
              "Update the billing address on your receipts",
            ].map((f) => (
              <li key={f} className="flex gap-2 border-b py-2.5 text-[0.875rem] text-muted rule">
                <span className="shrink-0 text-teal">&middot;</span>
                {f}
              </li>
            ))}
          </ul>

          <div className="mt-4">
            <Button variant="primary" disabled={busy} onClick={() => void openPortal()}>
              {busy ? "Opening Stripe" : "Open the billing portal"}
            </Button>
          </div>
          {message ? <p className="mt-2 text-[0.8125rem] text-muted">{message}</p> : null}

          <p className="mt-3 text-[0.75rem] leading-relaxed text-muted">
            Card details are held by Stripe and never touch this site, which is why this is a
            link out rather than a form here.
          </p>
        </section>

        {/* somebody on the free tier came here to buy something */}
        {!premium.active ? (
          <section className="mt-11">
            <h2 className="type-display text-[1rem]">Upgrade</h2>
            <div className="mt-4">
              <PlanCards signedIn returnTo="/profile/billing" />
            </div>
          </section>
        ) : null}
      </main>
      <Footer />
    </>
  );
}
