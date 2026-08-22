import Link from "next/link";
import { HeaderAccount } from "./HeaderAccount";

export function Header({ thin = false }: { thin?: boolean }) {
  return (
    <header className="border-b rule">
      <div
        className={`mx-auto flex w-full max-w-5xl items-center justify-between gap-4 px-4 ${
          thin ? "py-2.5" : "py-4"
        }`}
      >
        <Link href="/" className="type-display text-[0.9375rem] tracking-tight">
          Draft<span className="text-gold">For20</span>
        </Link>
        <nav className="flex items-center gap-4">
          <Link href="/join" className="type-label text-muted hover:text-ink">
            Join
          </Link>
          <HeaderAccount />
          <Link href="/new" className="type-label text-gold hover:text-ink">
            Start a room
          </Link>
        </nav>
      </div>
    </header>
  );
}

export function Footer() {
  return (
    <footer className="mt-16 border-t rule">
      <div className="mx-auto flex w-full max-w-5xl flex-wrap items-center gap-x-5 gap-y-2 px-4 py-6">
        <span className="type-label text-muted">DraftFor20</span>
        <Link href="/privacy" className="text-[0.8125rem] text-muted hover:text-ink">
          Privacy
        </Link>
        <Link href="/terms" className="text-[0.8125rem] text-muted hover:text-ink">
          Terms
        </Link>
        <span className="ml-auto text-[0.75rem] text-muted/70">
          Play money. No wagering, no payouts.
        </span>
      </div>
    </footer>
  );
}

export function SetupNotice() {
  return (
    <main className="mx-auto w-full max-w-xl px-4 py-16">
      <h1 className="type-display text-[1.5rem]">Supabase isn&apos;t connected yet</h1>
      <p className="mt-3 text-[0.9375rem] text-muted">
        Copy <code className="type-num text-ink">.env.example</code> to{" "}
        <code className="type-num text-ink">.env.local</code>, fill in your project URL and anon
        key, apply the SQL in <code className="type-num text-ink">supabase/migrations</code>, then
        restart the dev server. Full steps are in the README.
      </p>
    </main>
  );
}
