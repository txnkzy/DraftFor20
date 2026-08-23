"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Footer, Header, SetupNotice } from "@/components/site/Chrome";
import { BillingPanel } from "@/components/premium/BillingPanel";
import { BADGES } from "@/lib/badges";
import { ScoutingReport, type ScoutReport } from "@/components/profile/ScoutingReport";
import { HandleRow } from "@/components/profile/HandleRow";
import { signInHref, signOut } from "@/lib/auth";
import { supabaseBrowser, supabaseConfigured } from "@/lib/supabase/client";

interface Stats {
  signed_in: boolean;
  display_name: string | null;
  email: string | null;
  logo_url: string | null;
  created_at?: string;
  hosted: number;
  played: number;
  finished: number;
  wins: number;
  losses: number;
  undecided: number;
  decks: number;
  badges: string[];
  premium: {
    active: boolean;
    until: string | null;
    source: string | null;
    status: string | null;
    has_customer?: boolean;
  };
}

interface Deck {
  id: string;
  name: string;
  source: string | null;
  item_count: number;
  created_at: string;
}

export function ProfileClient() {
  if (!supabaseConfigured()) return <SetupNotice />;
  return <Profile />;
}

function Profile() {
  const [stats, setStats] = useState<Stats | null>(null);
  const [decks, setDecks] = useState<Deck[]>([]);
  const [scout, setScout] = useState<ScoutReport | null>(null);
  const [ready, setReady] = useState(false);

  const read = useCallback(async () => {
    const sb = supabaseBrowser();
    const [{ data: s }, { data: d }, { data: r }] = await Promise.all([
      sb.rpc("my_profile_stats"),
      sb.rpc("my_decks"),
      sb.rpc("my_scouting_report"),
    ]);
    return {
      stats: (s as Stats | null) ?? null,
      decks: (d as Deck[] | null) ?? [],
      scout: (r as ScoutReport | null) ?? null,
    };
  }, []);

  useEffect(() => {
    let off = false;
    void (async () => {
      const next = await read();
      if (off) return;
      setStats(next.stats);
      setDecks(next.decks);
      setScout(next.scout);
      setReady(true);
    })();
    return () => {
      off = true;
    };
  }, [read]);

  async function removeDeck(id: string) {
    await supabaseBrowser().rpc("delete_deck", { p_id: id });
    const next = await read();
    setStats(next.stats);
    setDecks(next.decks);
    setScout(next.scout);
  }

  if (!ready) {
    return (
      <>
        <Header thin />
        <main className="mx-auto w-full max-w-2xl px-4 py-14">
          <h1 className="type-display text-[1.75rem]">Your profile</h1>
          <p className="type-label mt-2 text-muted">loading</p>
        </main>
      </>
    );
  }

  if (!stats?.signed_in) {
    return (
      <>
        <Header thin />
        <main className="mx-auto w-full max-w-2xl px-4 py-14">
          <h1 className="type-display text-[1.75rem]">Your profile</h1>
          <p className="mt-2 text-[0.9375rem] text-muted">
            Sign in to see your drafts, your record and your saved decks. Playing never needs an
            account.
          </p>
          <Link href={signInHref("/profile")} className="btn btn-primary mt-5 h-12 px-5 text-[0.875rem]">
            Sign in
          </Link>
        </main>
        <Footer />
      </>
    );
  }

  const p = stats.premium;

  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-2xl px-4 py-10">
        <div className="flex items-center gap-4">
          {stats.logo_url ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={stats.logo_url} alt="" className="h-12 w-12 object-contain" />
          ) : null}
          <div>
            <h1 className="type-display text-[1.75rem]">
              {stats.display_name || "Your profile"}
            </h1>
            <HandleRow email={stats.email} />
          </div>
        </div>

        {/* ── the numbers ────────────────────────────────────────────────── */}
        <dl className="mt-8 grid grid-cols-2 gap-x-4 gap-y-5 border-y py-5 sm:grid-cols-4 rule">
          <Stat label="hosted" value={stats.hosted} />
          <Stat label="played" value={stats.played} />
          <Stat label="finished" value={stats.finished} />
          <Stat label="saved decks" value={stats.decks} />
        </dl>

        <section className="mt-7">
          <h2 className="type-display text-[1rem]">Record</h2>
          <p className="mt-1 text-[0.875rem] leading-relaxed text-muted">
            Nothing here is calculated. A draft counts as a win when the players themselves
            agreed on the winner in the one-tap vote at the end; a split decision is neither.
          </p>
          <dl className="mt-3 grid grid-cols-3 gap-4">
            <Stat label="won" value={stats.wins} />
            <Stat label="lost" value={stats.losses} />
            <Stat label="no call" value={stats.undecided} />
          </dl>
        </section>

        {/* ── the scouting report ────────────────────────────────────────
            Sits next to the raw record rather than replacing it: won / lost
            is one clean fact and this is four soft ones, and a page can hold
            both. */}
        {scout?.signed_in ? (
          <ScoutingReport report={scout} signedIn={Boolean(stats.email)} />
        ) : null}

        {/* ── badges ─────────────────────────────────────────────────────── */}
        <section className="mt-9">
          <h2 className="type-display text-[1rem]">Badges</h2>
          <ul className="mt-3 grid gap-2 sm:grid-cols-2">
            {BADGES.map((b) => {
              const has = stats.badges.includes(b.id);
              return (
                <li
                  key={b.id}
                  className="flex items-baseline gap-2 border p-3 rule"
                  style={{
                    opacity: has ? 1 : 0.45,
                    borderColor: has ? "var(--color-teal)" : undefined,
                  }}
                >
                  <span
                    className="type-label"
                    style={{ color: has ? "var(--color-teal)" : "var(--color-muted)" }}
                  >
                    {b.name}
                  </span>
                  <span className="ml-auto text-right text-[0.75rem] text-muted">{b.how}</span>
                </li>
              );
            })}
          </ul>
        </section>

        {/* ── saved decks ────────────────────────────────────────────────── */}
        <section className="mt-9">
          <h2 className="type-display text-[1rem]">Your decks</h2>
          <p className="mt-1 text-[0.875rem] leading-relaxed text-muted">
            Categories you kept from a finished draft. The items stay hidden — even from you —
            so a list somebody else built for you is still a surprise the second time.
          </p>
          <ul className="mt-3 flex flex-col">
            {decks.length === 0 ? (
              <li className="type-label border-b py-3 text-muted rule">
                nothing saved yet &middot; finish a draft and choose &ldquo;save this deck&rdquo;
              </li>
            ) : null}
            {decks.map((d) => (
              <li key={d.id} className="flex items-baseline gap-3 border-b py-3 rule">
                <span className="type-display truncate text-[0.875rem]">{d.name}</span>
                <span className="type-num shrink-0 text-[0.75rem] text-muted">
                  {d.item_count} items
                </span>
                <Link
                  href={`/new?deck=${d.id}`}
                  className="btn btn-ghost ml-auto h-9 shrink-0 px-3 text-[0.6875rem]"
                >
                  Deal from this
                </Link>
                <Button
                  variant="quiet"
                  size="sm"
                  aria-label={`Delete ${d.name}`}
                  onClick={() => void removeDeck(d.id)}
                >
                  &times;
                </Button>
              </li>
            ))}
          </ul>
        </section>

        {/* ── plan ───────────────────────────────────────────────────────── */}
        <BillingPanel premium={p} />

        <div className="mt-10 flex flex-wrap gap-2">
          <Link href="/new" className="btn btn-primary h-12 px-5 text-[0.875rem]">
            Start a room
          </Link>
          <Link href="/host" className="btn btn-ghost h-12 px-5 text-[0.875rem]">
            Host settings
          </Link>
          <SignOutButton />
        </div>
      </main>
      <Footer />
    </>
  );
}

/**
 * Signing out lived only on /host, which nothing has linked to since the
 * header started pointing at this page — so there was no way out of an
 * account without clearing cookies by hand.
 *
 * router.refresh() after the sign-out matters: without it the server
 * components keep rendering the session that no longer exists.
 */
function SignOutButton() {
  const router = useRouter();
  const [busy, setBusy] = useState(false);

  return (
    <Button
      variant="quiet"
      className="h-12 px-5 text-[0.875rem]"
      disabled={busy}
      onClick={() => {
        setBusy(true);
        void signOut()
          .then(() => {
            router.push("/");
            router.refresh();
          })
          .catch(() => setBusy(false));
      }}
    >
      {busy ? "Signing out" : "Sign out"}
    </Button>
  );
}

function Stat({ label, value }: { label: string; value: number }) {
  return (
    <div>
      <dt className="type-label text-muted">{label}</dt>
      <dd className="type-num text-[1.75rem] leading-none">{value}</dd>
    </div>
  );
}
