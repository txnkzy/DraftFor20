"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Footer, Header } from "@/components/site/Chrome";
import { formatCents } from "@/lib/money";
import { seatAccent } from "@/lib/game/view";

interface Row {
  pick: number;
  item: string;
  price_cents: number;
  gifted: boolean;
}
interface VotePlayer {
  id: string;
  seat: number;
  name: string;
  leftover_cents: number;
  spent_cents: number;
  rows: Row[];
}
interface VoteState {
  status: "open" | "gone" | "not_finished" | "unconfigured";
  room_id?: string;
  code?: string;
  title?: string;
  category?: string | null;
  starting_cents?: number;
  players?: VotePlayer[];
  your_vote?: string | null;
  tally?: { total: number; by_player: Record<string, number> } | null;
}

/**
 * The audience judge.
 *
 * BLIND FIRST. Nobody is shown the running tally until they have committed to
 * an answer, and that is not a UI decision — get_audience_state returns null
 * for the tally until this browser's key appears in audience_votes, so the
 * numbers are not in the page to be found.
 *
 * The call to action after voting is the point of the whole feature: someone
 * who just spent thirty seconds arguing about two rosters is exactly the
 * person who wants to build one.
 */
interface Tally {
  total: number;
  by_player: Record<string, number>;
}

/** every POLL_MS, with jitter so a thousand tabs do not align into a spike */
const POLL_MS = 4000;
const JITTER_MS = 1200;

function usePolledTally(roomRef: string, enabled: boolean): Tally | null {
  const [tally, setTally] = useState<Tally | null>(null);

  useEffect(() => {
    if (!enabled) return;
    let stopped = false;
    let timer: ReturnType<typeof setTimeout>;

    const tick = async () => {
      try {
        const res = await fetch(`/api/vote/${roomRef}/tally`, { cache: "no-store" });
        const d = (await res.json()) as { status?: string; tally?: Tally };
        if (!stopped && d.status === "open" && d.tally) setTally(d.tally);
      } catch {
        /* a dropped poll is a stale number for four seconds, nothing more */
      }
      if (!stopped) timer = setTimeout(() => void tick(), POLL_MS + Math.random() * JITTER_MS);
    };

    timer = setTimeout(() => void tick(), Math.random() * JITTER_MS);
    return () => {
      stopped = true;
      clearTimeout(timer);
    };
  }, [roomRef, enabled]);

  return tally;
}

export function VoteClient({ roomRef }: { roomRef: string }) {
  const [s, setS] = useState<VoteState | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let off = false;
    void (async () => {
      try {
        const res = await fetch(`/api/vote/${roomRef}`, { cache: "no-store" });
        const d = (await res.json()) as VoteState;
        if (!off) setS(d);
      } catch {
        if (!off) setS({ status: "gone" });
      }
    })();
    return () => { off = true; };
  }, [roomRef]);

  async function vote(playerId: string) {
    setBusy(true);
    setError(null);
    try {
      const res = await fetch(`/api/vote/${roomRef}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ winnerPlayerId: playerId }),
      });
      const d = (await res.json()) as VoteState & { message?: string };
      if (!res.ok) {
        setError(
          d.message?.includes("RATE_LIMITED")
            ? "That's a lot of votes from one place. Give it a bit."
            : "That vote didn't go through.",
        );
      } else {
        setS(d);
      }
    } catch {
      setError("That vote didn't go through.");
    }
    setBusy(false);
  }

  /* POLLED, NOT PUSHED. A realtime connection per spectator is the one thing
     here that scales with an audience rather than with players, so a viral
     link could exhaust the connection budget on its own. A number that moves
     every few seconds does not need a websocket; the bid war does, and keeps
     one. Polling starts only after voting, so the blind rule is unchanged. */
  const hasVoted = Boolean(s?.your_vote);
  const polled = usePolledTally(roomRef, hasVoted);
  const tally = polled ?? s?.tally ?? null;
  const total = tally?.total ?? 0;

  if (!s) {
    return (
      <>
        <Header thin />
        <main className="grid min-h-[60dvh] place-items-center px-4">
          <p className="type-label text-muted">loading the board</p>
        </main>
      </>
    );
  }

  if (s.status !== "open" || !s.players || s.players.length < 2) {
    return (
      <>
        <Header thin />
        <main className="mx-auto grid min-h-[60dvh] w-full max-w-md place-items-center px-4 text-center">
        <div>
          <h1 className="type-display text-[1.75rem]">
            {s.status === "not_finished"
              ? "This draft isn't finished"
              : `Nothing to judge at ${s.code ?? roomRef}`}
          </h1>
          <p className="mt-2 text-[0.9375rem] leading-relaxed text-muted">
            {s.status === "not_finished"
              ? "Come back when both rosters are full."
              : "That link doesn't match a finished draft."}
          </p>
          <Link href="/new" className="btn btn-primary mt-6 h-12 px-5 text-[0.875rem]">
            Start a free room
          </Link>
        </div>
        </main>
        <Footer />
      </>
    );
  }

  const voted = Boolean(s.your_vote);

  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-3xl px-4 py-8">
        <header className="flex flex-col gap-1">
          <span className="type-label text-muted">the internet decides &middot; {s.code ?? ""}</span>
          <h1 className="type-display text-[1.875rem]">Who drafted it better?</h1>
          <p className="mt-1 text-[0.9375rem] text-muted">
            {s.title}
            {s.starting_cents ? ` · ${formatCents(s.starting_cents)} each` : ""}. No algorithm
            picked a winner. {voted ? "Here's how it's going." : "You call it."}
          </p>
        </header>

        <div className="mt-7 grid grid-cols-2 gap-4 sm:gap-8">
          {s.players.map((p) => {
            const accent = seatAccent(p.seat);
            const n = tally?.by_player?.[p.id] ?? 0;
            const pct = total > 0 ? Math.round((n / total) * 100) : 0;
            const mine = s.your_vote === p.id;
            return (
              <section key={p.id} className="flex min-w-0 flex-col">
                <div className="flex items-baseline gap-2 border-b pb-2 rule">
                  <span style={{ width: 9, height: 9, background: accent }} aria-hidden />
                  <span className="type-display truncate text-[1rem]">{p.name}</span>
                  {mine ? <span className="type-label text-teal">yours</span> : null}
                </div>

                <ul className="mt-1 flex flex-col">
                  {p.rows.map((r) => (
                    <li key={r.pick} className="flex items-baseline gap-2 border-b py-2 rule">
                      <span className="type-num w-5 shrink-0 text-[0.6875rem] text-muted">
                        {r.pick}
                      </span>
                      <span className="min-w-0 flex-1 truncate text-[0.875rem]" title={r.item}>
                        {r.item}
                      </span>
                      <span
                        className="type-num shrink-0 text-[0.875rem]"
                        style={{ color: r.gifted ? "var(--color-teal)" : "var(--color-gold)" }}
                      >
                        {r.gifted ? "free" : formatCents(r.price_cents)}
                      </span>
                    </li>
                  ))}
                </ul>

                <div className="mt-3">
                  <span className="type-label text-muted">finished with</span>
                  <p className="type-num text-[2rem] leading-none" style={{ color: accent }}>
                    {formatCents(p.leftover_cents)}
                  </p>
                </div>

                {voted ? (
                  <div className="mt-4">
                    <div className="flex items-baseline justify-between">
                      <span className="type-num text-[1.5rem]" style={{ color: accent }}>
                        {pct}%
                      </span>
                      <span className="type-label text-muted">
                        {n} {n === 1 ? "vote" : "votes"}
                      </span>
                    </div>
                    <div
                      className="mt-1.5"
                      style={{
                        height: 6,
                        background: "color-mix(in oklab, var(--color-muted) 22%, transparent)",
                      }}
                    >
                      <div
                        style={{
                          width: `${pct}%`,
                          height: "100%",
                          background: accent,
                          transition: "width 420ms cubic-bezier(.2,.9,.3,1)",
                        }}
                      />
                    </div>
                  </div>
                ) : (
                  <Button
                    variant="primary"
                    size="lg"
                    className="mt-4 w-full"
                    disabled={busy}
                    onClick={() => void vote(p.id)}
                  >
                    {p.name}
                  </Button>
                )}
              </section>
            );
          })}
        </div>

        {error ? <p className="mt-4 text-[0.8125rem] text-coral">{error}</p> : null}

        {!voted ? (
          <p className="type-label mt-6 text-center text-muted">
            vote first &middot; the tally is hidden until you do
          </p>
        ) : null}

        {/* ── the loop. This is the whole reason the vote exists. ───────── */}
        {voted ? (
          <section className="mt-9 border p-5 text-center rule" style={{ borderColor: "var(--color-coral)" }}>
            <h2 className="type-display text-[1.5rem]">Think you can draft better?</h2>
            <p className="mx-auto mt-2 max-w-md text-[0.9375rem] leading-relaxed text-muted">
              Two people, {s.starting_cents ? formatCents(s.starting_cents) : "$20"} each, and a
              deck neither of you has seen. Takes about five minutes and you get a card like this
              one at the end.
            </p>
            <Link href="/new" className="btn btn-primary mt-5 h-14 px-6 text-[0.9375rem]">
              Start a free room
            </Link>
            <p className="type-label mt-3 text-muted">no account needed</p>
          </section>
        ) : null}

        {/* only after voting: before, `total` is 0 because the server has not
            told this browser the tally, and printing that would be a made-up
            number rather than a hidden one */}
        {voted ? (
          <p className="mt-6 text-center text-[0.75rem] text-muted">
            {total} {total === 1 ? "person has" : "people have"} judged this draft
          </p>
        ) : null}
      </main>
      <Footer />
    </>
  );
}
