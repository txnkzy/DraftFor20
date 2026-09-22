"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { CardImage } from "@/components/board/CardImage";
import { FlipReveal } from "@/components/lineup/FlipReveal";
import { Footer, Header, SetupNotice } from "@/components/site/Chrome";
import { readableError } from "@/lib/game/errors";
import {
  useLineupToken,
  voterKey,
  type LineupState,
  type PlacedCard,
} from "@/lib/lineup/session";
import { supabaseBrowser, supabaseConfigured } from "@/lib/supabase/client";

/**
 * One URL, two jobs, decided by whether this browser holds the token.
 *
 * Hold it and you are playing. Do not and you were sent the link, so you see
 * the finished lineup and rate it. That is why the share link is just the
 * page you were already on — there is no second address to explain.
 */
export function LineupClient({ code }: { code: string }) {
  if (!supabaseConfigured()) return <SetupNotice />;
  return <Lineup code={code} />;
}

function Lineup({ code }: { code: string }) {
  const token = useLineupToken(code);

  // undefined means "not read yet" — on the server, and for the first paint.
  // Branching before then would flash the rating form at the player who is
  // actually mid-run.
  if (token === undefined) {
    return (
      <>
        <Header thin />
        <main className="mx-auto w-full max-w-2xl px-4 py-10">
          <p className="type-label text-muted">loading</p>
        </main>
      </>
    );
  }
  return token ? <Playing code={code} token={token} /> : <Rating code={code} />;
}

/* ── playing ──────────────────────────────────────────────────────────── */

function Playing({ code, token }: { code: string; token: string }) {
  const [state, setState] = useState<LineupState | null>(null);
  const [pool, setPool] = useState<string[]>([]);
  /* THE RIFFLE MUST NOT START BEFORE ITS IMAGES DO. pool is in FlipReveal's
     effect deps, so an empty-then-full pool re-runs that effect — the cleanup
     clears the pending settle timer and the "already played this card" guard
     then schedules nothing, leaving the card spinning forever. Holding the
     first render until the images are in hand means the effect runs once per
     card, which is the only number that is correct. */
  const [poolReady, setPoolReady] = useState(false);
  const [busy, setBusy] = useState(false);
  const [settled, setSettled] = useState(false);
  /* Stable identity: FlipReveal keeps this in its effect deps, and an inline
     arrow would restart the riffle on every render. */
  const onSettled = useCallback(() => setSettled(true), []);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data, error: e } = await supabaseBrowser().rpc("my_lineup_state", {
      p_code: code,
      p_token: token,
    });
    if (e) {
      setError(readableError(e.message));
      return null;
    }
    return data as LineupState;
  }, [code, token]);

  useEffect(() => {
    let off = false;
    void (async () => {
      const s = await load();
      if (!off && s) setState(s);
    })();
    return () => {
      off = true;
    };
  }, [load]);

  /* The flip images are fetched once per run, by category. */
  useEffect(() => {
    if (!state?.category || pool.length) return;
    let off = false;
    void (async () => {
      const { data } = await supabaseBrowser().rpc("list_free_categories");
      const hit = ((data as { id: string; name: string }[]) ?? []).find(
        (c) => c.name === state.category,
      );
      if (!hit) {
        // no images to riffle: play the card straight rather than hang
        if (!off) setPoolReady(true);
        return;
      }
      const { data: imgs } = await supabaseBrowser().rpc("lineup_flip_images", {
        p_library_id: hit.id,
      });
      if (off) return;
      setPool((imgs as string[]) ?? []);
      setPoolReady(true);
    })();
    return () => {
      off = true;
    };
  }, [state?.category, pool.length]);

  async function place(slot: number) {
    if (busy || !state?.current) return;
    setBusy(true);
    setError(null);
    setSettled(false);
    const { data, error: e } = await supabaseBrowser().rpc("place_lineup_card", {
      p_code: code,
      p_token: token,
      p_slot: slot,
    });
    setBusy(false);
    if (e) {
      setError(readableError(e.message));
      return;
    }
    setState(data as LineupState);
  }

  if (error && !state) {
    return (
      <>
        <Header thin />
        <main className="mx-auto w-full max-w-2xl px-4 py-10">
          <p className="type-label text-coral">{error}</p>
        </main>
      </>
    );
  }
  if (!state) {
    return (
      <>
        <Header thin />
        <main className="mx-auto w-full max-w-2xl px-4 py-10">
          <p className="type-label text-muted">dealing</p>
        </main>
      </>
    );
  }

  if (state.status === "complete") return <Finished code={code} state={state} />;

  const placed = new Map(state.slots.map((s) => [s.slot, s]));

  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-2xl px-4 py-8">
        <div className="flex items-baseline justify-between gap-3">
          <h1 className="type-display text-[1.5rem]">{state.category}</h1>
          <span className="type-label text-muted">
            card <span className="type-num text-ink">{state.revealed}</span> of{" "}
            <span className="type-num">{state.slot_count}</span>
          </span>
        </div>

        <div className="mt-5">
          {poolReady ? (
            <FlipReveal card={state.current} pool={pool} onSettled={onSettled} />
          ) : (
            <div className="panel flex items-center justify-center" style={{ height: 260 }}>
              <span className="type-label text-muted">shuffling</span>
            </div>
          )}
        </div>

        <p className="type-label mt-6 text-center text-muted">
          {settled ? "where does it go?" : " "}
        </p>

        {/* THE SLOTS. A filled one is not a button — the whole mode is that
            you cannot move a card once it is down. */}
        <ol className="mt-3 flex flex-col gap-2">
          {Array.from({ length: state.slot_count }, (_, i) => i + 1).map((slot) => {
            const card = placed.get(slot);
            return (
              <li key={slot}>
                {card ? (
                  <div className="panel flex items-center gap-3 px-3 py-2">
                    <span className="type-num w-6 shrink-0 text-[1.125rem] text-gold">{slot}</span>
                    <CardImage
                      name={card.name}
                      url={card.image_url}
                      height={44}
                      className="h-11 w-11 shrink-0"
                    />
                    <span className="text-[0.9375rem] text-ink">{card.name}</span>
                  </div>
                ) : (
                  <Button
                    variant="ghost"
                    size="lg"
                    className="w-full justify-start gap-3"
                    disabled={busy || !settled}
                    onClick={() => void place(slot)}
                  >
                    <span className="type-num w-6 shrink-0 text-[1.125rem] text-gold">{slot}</span>
                    <span className="type-label text-muted">
                      {slot === 1 ? "best" : slot === state.slot_count ? "worst" : "open"}
                    </span>
                  </Button>
                )}
              </li>
            );
          })}
        </ol>

        {error ? <p className="mt-3 text-[0.8125rem] text-coral">{error}</p> : null}
      </main>
    </>
  );
}

/* ── finished, as the player who built it ─────────────────────────────── */

function Finished({ code, state }: { code: string; state: LineupState }) {
  const [copied, setCopied] = useState(false);
  const url = typeof window === "undefined" ? "" : `${window.location.origin}/rank/${code}`;

  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-2xl px-4 py-10">
        <p className="type-label text-teal">lineup locked</p>
        <h1 className="type-display mt-1 text-[1.75rem]">{state.category}</h1>

        <LineupList slots={state.slots} />

        <div className="mt-8 border p-5 rule">
          <h2 className="type-display text-[1.125rem]">Let them tell you how you did</h2>
          <p className="mt-2 text-[0.875rem] leading-relaxed text-muted">
            Send this to whoever will argue about it. They see the lineup, rate it out of ten, and
            only then find out what everyone else gave it.
          </p>
          <div className="mt-3 flex items-stretch gap-2">
            <code className="field type-num flex-1 truncate text-[0.8125rem]">{url}</code>
            <Button
              variant="primary"
              onClick={() =>
                void navigator.clipboard
                  .writeText(url)
                  .then(() => {
                    setCopied(true);
                    setTimeout(() => setCopied(false), 1600);
                  })
                  .catch(() => undefined)
              }
            >
              {copied ? "Copied" : "Copy link"}
            </Button>
          </div>
        </div>

        <div className="mt-6 flex flex-wrap gap-2">
          <Link href="/rank" className="btn btn-primary h-12 px-5 text-[0.875rem]">
            Run it back
          </Link>
          <Link href="/" className="btn btn-ghost h-12 px-5 text-[0.875rem]">
            Home
          </Link>
        </div>
      </main>
      <Footer />
    </>
  );
}

/* ── the link you were sent ───────────────────────────────────────────── */

function Rating({ code }: { code: string }) {
  const [lineup, setLineup] = useState<
    { ready: boolean; category?: string; by?: string | null; slots?: PlacedCard[] } | null
  >(null);
  const [tally, setTally] = useState<{
    voted: boolean;
    mine: number | null;
    count: number | null;
    average: number | null;
  } | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let off = false;
    void (async () => {
      const sb = supabaseBrowser();
      const { data, error: e } = await sb.rpc("public_lineup", { p_code: code });
      if (off) return;
      if (e) {
        setError(readableError(e.message));
        return;
      }
      setLineup(data as typeof lineup);
      const { data: t } = await sb.rpc("lineup_rating_state", {
        p_code: code,
        p_voter_key: voterKey(),
      });
      if (!off) setTally(t as typeof tally);
    })();
    return () => {
      off = true;
    };
  }, [code]);

  async function rate(score: number) {
    setBusy(true);
    setError(null);
    const { data, error: e } = await supabaseBrowser().rpc("rate_lineup", {
      p_code: code,
      p_voter_key: voterKey(),
      p_score: score,
    });
    setBusy(false);
    if (e) {
      setError(readableError(e.message));
      return;
    }
    setTally(data as typeof tally);
  }

  if (error) {
    return (
      <>
        <Header thin />
        <main className="mx-auto w-full max-w-2xl px-4 py-10">
          <p className="type-label text-coral">{error}</p>
        </main>
      </>
    );
  }
  if (!lineup) {
    return (
      <>
        <Header thin />
        <main className="mx-auto w-full max-w-2xl px-4 py-10">
          <p className="type-label text-muted">loading</p>
        </main>
      </>
    );
  }
  if (!lineup.ready) {
    return (
      <>
        <Header thin />
        <main className="mx-auto w-full max-w-2xl px-4 py-10">
          <h1 className="type-display text-[1.5rem]">Still being built</h1>
          <p className="mt-2 text-[0.9375rem] text-muted">
            This lineup isn&apos;t finished yet. Check back in a minute.
          </p>
          <Link href="/rank" className="btn btn-primary mt-5 h-12 px-5 text-[0.875rem]">
            Build your own
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
        <p className="type-label text-muted">
          {lineup.by ? `@${lineup.by} ranked` : "somebody ranked"}
        </p>
        <h1 className="type-display mt-1 text-[1.75rem]">{lineup.category}</h1>
        <p className="mt-2 text-[0.875rem] leading-relaxed text-muted">
          They saw these one at a time and had to place each one before seeing the next.
        </p>

        <LineupList slots={lineup.slots ?? []} />

        <div className="mt-8 border p-5 rule">
          {tally?.voted ? (
            <>
              <h2 className="type-display text-[1.125rem]">
                You gave it <span className="text-gold">{tally.mine}</span>
              </h2>
              <p className="mt-2 text-[0.9375rem] text-muted">
                Everyone else averages{" "}
                <span className="type-num text-ink">{tally.average}</span> across{" "}
                <span className="type-num text-ink">{tally.count}</span>{" "}
                {tally.count === 1 ? "rating" : "ratings"}.
              </p>
              <Link href="/rank" className="btn btn-primary mt-4 h-12 px-5 text-[0.875rem]">
                Now build yours
              </Link>
            </>
          ) : (
            <>
              <h2 className="type-display text-[1.125rem]">Rate it out of ten</h2>
              <p className="mt-2 text-[0.875rem] leading-relaxed text-muted">
                You only see what everyone else said once you have called it yourself.
              </p>
              <div className="mt-4 flex flex-wrap gap-1.5">
                {Array.from({ length: 10 }, (_, i) => i + 1).map((n) => (
                  <Button
                    key={n}
                    variant="ghost"
                    size="md"
                    className="w-11"
                    disabled={busy}
                    onClick={() => void rate(n)}
                  >
                    {n}
                  </Button>
                ))}
              </div>
            </>
          )}
        </div>
      </main>
      <Footer />
    </>
  );
}

function LineupList({ slots }: { slots: PlacedCard[] }) {
  return (
    <ol className="mt-6 flex flex-col gap-2">
      {slots.map((c) => (
        <li key={c.slot} className="panel flex items-center gap-3 px-3 py-2">
          <span className="type-num w-6 shrink-0 text-[1.125rem] text-gold">{c.slot}</span>
          <CardImage
            name={c.name}
            url={c.image_url}
            height={48}
            className="h-12 w-12 shrink-0"
          />
          <span className="text-[0.9375rem] text-ink">{c.name}</span>
        </li>
      ))}
    </ol>
  );
}
