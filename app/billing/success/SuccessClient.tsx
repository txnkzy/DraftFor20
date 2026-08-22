"use client";

import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { useEffect, useState } from "react";
import { Footer, Header } from "@/components/site/Chrome";
import { supabaseBrowser, supabaseConfigured } from "@/lib/supabase/client";
import { parsePremium, type PremiumState } from "@/lib/premium";

/**
 * The moment after Stripe takes the money.
 *
 * The webhook is what actually grants access, and it can land after the
 * customer is already looking at this page. So this WAITS rather than
 * claiming an upgrade the database has not been told about — and if the wait
 * runs out it says the payment went through and the unlock is still syncing,
 * which is true, instead of showing a failure that would send someone to
 * support over a purchase that worked.
 */
const POLL_MS = 1500;
const GIVE_UP_MS = 24_000;

export function SuccessClient() {
  const q = useSearchParams();
  const plan = q.get("plan") === "pass" ? "pass" : "premium";
  const rawNext = q.get("next") ?? "/profile";
  // only ever a path on this site
  const next = /^\/[^/\\]/.test(rawNext) ? rawNext : "/profile";

  const [state, setState] = useState<PremiumState | null>(null);
  const [timedOut, setTimedOut] = useState(false);

  useEffect(() => {
    if (!supabaseConfigured()) return;
    let off = false;
    const started = Date.now();

    const tick = async () => {
      const { data, error } = await supabaseBrowser().rpc("my_premium");
      if (off) return;
      if (!error) {
        const p = parsePremium(data);
        setState(p);
        if (p.active) return; // done: stop polling
      }
      if (Date.now() - started > GIVE_UP_MS) {
        setTimedOut(true);
        return;
      }
      setTimeout(() => void tick(), POLL_MS);
    };
    void tick();
    return () => { off = true; };
  }, []);

  const active = state?.active ?? false;
  const until = state?.until ? new Date(state.until) : null;

  return (
    <>
      <Header thin />
      <main className="mx-auto grid min-h-[60dvh] w-full max-w-lg place-items-center px-4 py-10">
        <div className="w-full text-center">
          {active ? (
            <>
              <p className="type-label text-teal">payment received</p>
              <h1 className="type-display mt-2 text-[1.875rem]">
                {plan === "pass" ? "Your 24 hours have started" : "You're on Premium"}
              </h1>
              <p className="mt-3 text-[0.9375rem] leading-relaxed text-muted">
                {plan === "pass"
                  ? "Everything premium is unlocked until "
                  : "Everything premium is unlocked. Your plan renews on "}
                <span className="type-num text-ink">
                  {until ? until.toLocaleString() : "shortly"}
                </span>
                .
              </p>
              <p className="mt-2 text-[0.875rem] leading-relaxed text-muted">
                Your results cards still carry the DraftFor20 watermark until you turn it off
                yourself — that is deliberate, and it is one toggle away under card options.
              </p>
              <div className="mt-6 flex flex-wrap justify-center gap-2">
                <Link href={next} className="btn btn-primary h-12 px-5 text-[0.875rem]">
                  Back to what you were doing
                </Link>
                <Link href="/profile" className="btn btn-ghost h-12 px-5 text-[0.875rem]">
                  See your plan
                </Link>
              </div>
            </>
          ) : timedOut ? (
            <>
              <p className="type-label text-gold">payment received</p>
              <h1 className="type-display mt-2 text-[1.75rem]">Still syncing</h1>
              <p className="mt-3 text-[0.9375rem] leading-relaxed text-muted">
                Stripe has your payment. The unlock is applied by a webhook that has not reported
                back yet — it usually takes seconds. Nothing is lost; reload your profile in a
                moment and it will be there.
              </p>
              <div className="mt-6 flex flex-wrap justify-center gap-2">
                <Link href="/profile" className="btn btn-primary h-12 px-5 text-[0.875rem]">
                  Go to your profile
                </Link>
              </div>
              <p className="mt-4 text-[0.75rem] text-muted">
                If it is still not showing in a few minutes, get in touch and quote{" "}
                <span className="type-num text-ink">{q.get("session_id")?.slice(0, 24) ?? "—"}</span>.
              </p>
            </>
          ) : (
            <>
              <p className="type-label text-muted">confirming with stripe</p>
              <h1 className="type-display mt-2 text-[1.75rem]">One moment</h1>
              <p className="mt-3 text-[0.9375rem] leading-relaxed text-muted">
                Your payment went through. Waiting for the unlock to register.
              </p>
            </>
          )}
        </div>
      </main>
      <Footer />
    </>
  );
}
