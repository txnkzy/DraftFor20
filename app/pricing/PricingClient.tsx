"use client";

import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { Footer, Header } from "@/components/site/Chrome";
import { PlanCards } from "@/components/premium/PlanCards";
import { usePremium } from "@/lib/premium";

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
