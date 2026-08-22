import type { ReactNode } from "react";
import { Footer, Header } from "./Chrome";
import { LEGAL_UPDATED } from "@/lib/site";

export function LegalShell({ title, children }: { title: string; children: ReactNode }) {
  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-2xl px-4 py-10">
        <h1 className="type-display text-[1.75rem]">{title}</h1>
        <p className="type-label mt-2 text-muted">last updated {LEGAL_UPDATED}</p>
        <div className="mt-8 flex flex-col gap-7">{children}</div>
      </main>
      <Footer />
    </>
  );
}

export function Clause({ heading, children }: { heading: string; children: ReactNode }) {
  return (
    <section className="border-t pt-4 rule">
      <h2 className="type-display text-[1rem]">{heading}</h2>
      <div className="mt-2 flex flex-col gap-3 text-[0.9375rem] leading-relaxed text-muted">
        {children}
      </div>
    </section>
  );
}
