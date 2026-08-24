"use client";

import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { Footer, Header } from "@/components/site/Chrome";
import { PlanCards } from "@/components/premium/PlanCards";
import { usePremium } from "@/lib/premium";
import { useEffect, useState } from "react";

/**
 * One honest line at the top when checkout is off, so nobody works out for
 * themselves that the buttons do nothing.
 */
function NotOpenYet() {
  const [off, setOff] = useState(false);
  useEffect(() => {
    let stop = false;
    void (async () => {
      try {
        const res = await fetch("/api/billing/config", { cache: "no-store" });
        const d = (await res.json()) as { configured?: boolean };
        if (!stop) setOff(d.configured === false);
      } catch {
        if (!stop) setOff(true);
      }
    })();
    return () => { stop = true; };
  }, []);

  if (!off) return null;
  return (
    <p className="mt-5 border border-dashed px-3 py-2.5 text-[0.875rem] leading-relaxed text-muted rule">
      <span className="type-label text-gold">not open yet</span>{" "}
      Card payments are not switched on, so neither option can be bought at the moment. The
      prices below are final. Everything free keeps working exactly as it does now.
    </p>
  );
}

export function PricingClient() {
  const premium = usePremium();
  const q = useSearchParams();
  const cancelled = q.get("cancelled") === "1";

  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-3xl px-4 py-10">
        <h1 className="type-display text-[1.875rem]">Pricing</h1>
        <p className="mt-2 max-w-xl text-[0.9375rem] leading-relaxed text-muted">
          The game is free and stays free: every category on the shelf, every draft, the results
          card and the audience vote. Premium is for filming it.
        </p>

        <NotOpenYet />

        {cancelled ? (
          <p className="mt-5 border border-teal px-3 py-2.5 text-[0.875rem] text-ink">
            <span className="type-label text-teal">checkout cancelled</span>{" "}
            Nothing was charged. Everything free still works exactly as it did.
          </p>
        ) : null}

        {premium.active ? (
          <div className="mt-6 border p-4" style={{ borderColor: "var(--color-teal)" }}>
            <p className="type-label text-teal">you already have premium</p>
            <p className="mt-2 text-[0.875rem] text-muted">
              Nothing to buy. Your plan and its expiry are on{" "}
              <Link href="/profile" className="text-ink underline">your profile</Link>.
            </p>
          </div>
        ) : null}

        <div className="mt-8">
          <PlanCards signedIn={premium.signedIn} returnTo="/profile" />
        </div>

        <section className="mt-12">
          <h2 className="type-display text-[1rem]">What stays free</h2>
          <ul className="mt-3 flex flex-col">
            {[
              "Hosting and playing drafts, with no account at all",
              "Every premade category on the shelf",
              "The 1080×1920 results card, watermarked",
              "The audience vote link and its blind tally",
              "Custom categories, with a confirmed account",
            ].map((f) => (
              <li key={f} className="border-b py-2.5 text-[0.875rem] text-muted rule">
                {f}
              </li>
            ))}
          </ul>
        </section>
      </main>
      <Footer />
    </>
  );
}
