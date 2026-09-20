"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { LibraryOptIn } from "./LibraryOptIn";
import { ExportPanel } from "./ExportPanel";
import { VoteLink } from "./VoteLink";
import { buildCardModel } from "@/lib/results/cardModel";
import { formatCents } from "@/lib/money";
import { seatAccent } from "@/lib/game/view";
import { useAudienceTally, type AudienceTally } from "@/lib/game/useAudienceTally";
import { Button } from "@/components/ui/Button";
import { readableError } from "@/lib/game/errors";
import { saveSeat } from "@/lib/game/session";
import { supabaseBrowser } from "@/lib/supabase/client";
import type { RoomState } from "@/lib/game/types";

/**
 * The audience tally for somebody sitting in this room. One read on mount to
 * catch votes cast before the page opened, then the websocket carries every
 * one after it.
 */
function useLiveAudience(
  roomId: string,
  code: string,
  sessionToken: string | null,
): AudienceTally | null {
  const [initial, setInitial] = useState<AudienceTally | null>(null);

  const read = useCallback(async () => {
    if (!sessionToken) return null;
    const { data } = await supabaseBrowser().rpc("get_audience_hub", {
      p_code: code,
      p_token: sessionToken,
    });
    return ((data as { tally?: AudienceTally } | null)?.tally ?? null) as AudienceTally | null;
  }, [code, sessionToken]);

  const refetch = useCallback(() => {
    void (async () => setInitial(await read()))();
  }, [read]);

  useEffect(() => {
    let off = false;
    void (async () => {
      const t = await read();
      if (!off) setInitial(t);
    })();
    return () => {
      off = true;
    };
  }, [read]);

  const pushed = useAudienceTally(roomId, Boolean(sessionToken), refetch);
  return pushed ?? initial;
}

interface Axis {
  key: string;
  label: string;
  score: number;
  snipes?: number;
  bought?: number;
  avg_price_cents?: number;
  losing_raises?: number;
  leftover_cents?: number;
}
interface ScoutPlayer {
  seat: number;
  name: string;
  title: string;
  axes: Axis[];
}
interface Scout {
  ready: boolean;
  players?: ScoutPlayer[];
  head_to_head?: {
    played: number;
    seat1_wins: number;
    seat2_wins: number;
    draws: number;
  } | null;
}

/** What each axis says about THIS draft, in the units a player recognises. */
function axisNote(a: Axis): string {
  if (a.key === "sniper" && a.bought !== undefined)
    return `${a.snipes} of ${a.bought} bought at the minimum`;
  if (a.key === "whale" && a.avg_price_cents !== undefined)
    return `${formatCents(a.avg_price_cents)} a card on average`;
  if (a.key === "instigator" && a.losing_raises !== undefined)
    return `${a.losing_raises} raise${a.losing_raises === 1 ? "" : "s"} that did not win`;
  if (a.key === "hoarder" && a.leftover_cents !== undefined)
    return `finished with ${formatCents(a.leftover_cents)}`;
  return "";
}

const TITLE_BLURB: Record<string, string> = {
  sniper: "took the minimum and let the rest go",
  whale: "paid up for the ones that mattered",
  instigator: "drove the price up and walked away",
  hoarder: "left the most money on the table",
  quiet: "nothing stood out",
};

export function ResultsBoard({
  state,
  sessionToken = null,
}: {
  state: RoomState;
  /** a seated player's token: the audience tally is theirs to watch without
   *  having to vote in their own draft */
  sessionToken?: string | null;
}) {
  const card = buildCardModel(state);
  const audience = useLiveAudience(state.room.id, card.code, sessionToken);

  /* The four axes for THIS draft, both players. Read in the thirty seconds
     after it ends, which is when anyone cares — the same numbers on /profile
     a week later are trivia. */
  const [scout, setScout] = useState<Scout | null>(null);
  useEffect(() => {
    let off = false;
    void (async () => {
      const { data } = await supabaseBrowser().rpc("room_scouting", { p_code: card.code });
      if (!off) setScout((data as Scout | null) ?? null);
    })();
    return () => {
      off = true;
    };
  }, [card.code]);

  return (
    <div className="flex flex-col gap-7">
      <header className="flex flex-col gap-1">
        <span className="type-label text-muted">final board &middot; {card.code}</span>
        <h1 className="type-display text-[1.75rem]">{card.title}</h1>
      </header>

      <div className="grid grid-cols-2 gap-4 sm:gap-8">
        {card.players.map((p) => {
          const accent = seatAccent(p.seat);
          return (
            <section key={p.id} className="flex min-w-0 flex-col">
              <div className="flex items-baseline gap-2 border-b pb-2 rule">
                <span style={{ width: 9, height: 9, background: accent }} aria-hidden />
                <span className="type-display truncate text-[1rem]">{p.name}</span>
              </div>

              {p.busted ? (
                <p className="type-label mt-2 border border-coral px-2 py-1.5 text-center text-coral">
                  busted &middot; disqualified
                </p>
              ) : null}

              <ul className="mt-1 flex flex-col">
                {p.rows.map((r) => (
                  <li key={r.pick} className="flex items-baseline gap-2 border-b py-2 rule">
                    <span className="type-num w-5 shrink-0 text-[0.6875rem] text-muted">{r.pick}</span>
                    <span className="min-w-0 flex-1 truncate text-[0.875rem]" title={r.item}>
                      {r.item}
                      {r.gifted ? (
                        <span className="type-label ml-1.5 text-teal">{r.forced ? "forced" : "given"}</span>
                      ) : null}
                    </span>
                    <span
                      className="type-num shrink-0 text-[0.875rem]"
                      style={{ color: r.gifted ? "var(--color-teal)" : "var(--color-gold)" }}
                    >
                      {r.gifted ? "free" : formatCents(r.priceCents)}
                    </span>
                  </li>
                ))}
              </ul>

              <div className="mt-3">
                <span className="type-label text-muted">finished with</span>
                <p className="type-num text-[2rem] leading-none" style={{ color: accent }}>
                  {formatCents(p.leftoverCents)}
                </p>
                <p className="type-num mt-1 text-[0.6875rem] text-muted">
                  spent {formatCents(p.spentCents)} of {formatCents(card.startingCents)}
                </p>
              </div>
            </section>
          );
        })}
      </div>

      {card.topLot ? (
        <p className="border-y py-3 text-[0.9375rem] text-muted rule">
          Priciest buy:{" "}
          <span className="text-ink">{card.topLot.item}</span> at{" "}
          <span className="type-num text-gold">{formatCents(card.topLot.priceCents)}</span> to{" "}
          {card.topLot.winner}.
          {card.longestWar && card.longestWar.raises > 1
            ? ` ${card.longestWar.item} took ${card.longestWar.raises} raises to settle.`
            : ""}
          {card.giftCount > 0
            ? ` ${card.giftCount} ${card.giftCount === 1 ? "player was" : "players were"} handed over for free.`
            : ""}
        </p>
      ) : null}

      {/* HOW EACH OF YOU DRAFTED. The axes have existed since 0022 and lived
          on /profile, where nobody was looking. Side by side, immediately
          after, they are an argument rather than a statistic. */}
      {scout?.ready && scout.players && scout.players.length > 0 ? (
        <div className="flex flex-col gap-4">
          <div className="flex items-baseline justify-between gap-3">
            <h2 className="type-display text-[1.125rem]">How you drafted</h2>
            {scout.head_to_head && scout.head_to_head.played > 1 ? (
              <span className="type-num text-[0.8125rem] text-muted">
                {scout.head_to_head.played} drafts ·{" "}
                <span className="text-ink">
                  {scout.head_to_head.seat1_wins}&ndash;{scout.head_to_head.seat2_wins}
                </span>
                {scout.head_to_head.draws > 0 ? ` · ${scout.head_to_head.draws} drawn` : ""}
              </span>
            ) : null}
          </div>

          <div className="grid grid-cols-1 gap-6 sm:grid-cols-2">
            {scout.players.map((p) => {
              const accent = seatAccent(p.seat);
              return (
                <section key={p.seat} className="flex flex-col gap-3">
                  <div className="flex items-baseline gap-2">
                    <span style={{ width: 8, height: 8, background: accent }} aria-hidden />
                    <span className="type-display text-[0.9375rem]">{p.name}</span>
                    <span className="type-label" style={{ color: accent }}>
                      {p.title}
                    </span>
                  </div>
                  <p className="text-[0.8125rem] leading-snug text-muted">
                    {TITLE_BLURB[p.title] ?? ""}
                  </p>
                  <div className="flex flex-col gap-2.5">
                    {p.axes.map((a) => (
                      <div key={a.key}>
                        <div className="flex items-baseline gap-2">
                          <span className="type-label min-w-0 flex-1 truncate text-muted">
                            {a.label}
                          </span>
                          <span className="type-num shrink-0 text-[0.75rem] text-ink">
                            {a.score}
                          </span>
                        </div>
                        {/* The bar is the comparison between the two of you;
                            the note underneath is what produced it, so the
                            number is never something to take on trust. */}
                        <div
                          className="mt-1 w-full overflow-hidden"
                          style={{ height: 5, background: "var(--color-surface)", borderRadius: 3 }}
                          role="img"
                          aria-label={`${p.name} ${a.label}: ${a.score} out of 100`}
                        >
                          <div
                            style={{
                              width: `${a.score}%`,
                              height: "100%",
                              background: accent,
                              borderRadius: 3,
                            }}
                          />
                        </div>
                        <p className="mt-0.5 text-[0.6875rem] leading-snug text-muted">
                          {axisNote(a)}
                        </p>
                      </div>
                    ))}
                  </div>
                </section>
              );
            })}
          </div>
        </div>
      ) : null}

      {/* The players used to vote on who won, right here. Two people asked
          which of them won will each say themselves, which is a tie, which is
          nobody — so the control cost a tap and decided nothing. The audience
          vote below is the one that means something, because the people
          casting it have no side. */}

      {/* what the internet said, arriving over the same websocket the board
          uses. Only for somebody seated in this room: a spectator who has not
          voted is still bound by the blind rule. */}
      {audience && audience.total > 0 ? (
        <div className="border p-4 rule">
          <div className="flex items-baseline justify-between gap-3">
            <h2 className="type-display text-[1.125rem]">The audience</h2>
            <span className="type-num text-[0.75rem] text-muted">
              {audience.total} {audience.total === 1 ? "vote" : "votes"} &middot; live
            </span>
          </div>
          <ul className="mt-3 flex flex-col gap-2.5">
            {state.players.map((p) => {
              const n = audience.by_player?.[p.id] ?? 0;
              const pct = audience.total > 0 ? Math.round((n / audience.total) * 100) : 0;
              const accent = seatAccent(p.seat);
              return (
                <li key={p.id}>
                  <div className="flex items-baseline gap-2">
                    <span style={{ width: 8, height: 8, background: accent }} aria-hidden />
                    <span className="type-display text-[0.875rem]">{p.display_name}</span>
                    <span className="type-num ml-auto text-[0.875rem]" style={{ color: accent }}>
                      {pct}%
                    </span>
                  </div>
                  <div
                    className="mt-1"
                    style={{
                      height: 4,
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
                </li>
              );
            })}
          </ul>
        </div>
      ) : null}

      {/* free for everyone, on purpose: the vote link is how a finished draft
          turns into the next two players */}
      <VoteLink code={card.code} />

      <LibraryOptIn code={card.code} />

      <ExportPanel
        code={card.code}
        model={card}
        hostProfileId={state.room.host_profile_id}
      />

      <Rematch
        code={card.code}
        sessionToken={sessionToken}
        rematchCode={state.room.rematch_code ?? null}
      />
    </div>
  );
}

/**
 * "Run it back" used to be a link to /new. It carried nothing — not the
 * category, not the bankroll, not the roster size, and not the person you
 * had just played — so a rematch meant re-picking every setting and sending
 * a fresh code to somebody already sitting there.
 *
 * Now the first person to press it creates the room with both seats already
 * filled, and the other one sees it appear and joins. Neither is ever handed
 * the other's session token: each proves their old seat and collects only
 * their own. A spectator sees the invitation and cannot take a seat, which
 * is correct — they were never in the draft.
 */
function Rematch({
  code,
  sessionToken,
  rematchCode,
}: {
  code: string;
  sessionToken: string | null;
  rematchCode: string | null;
}) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function go(fn: "create_rematch" | "claim_rematch") {
    if (!sessionToken) return;
    setBusy(true);
    setError(null);
    const { data, error: e } = await supabaseBrowser().rpc(fn, {
      p_code: code,
      p_token: sessionToken,
    });
    setBusy(false);
    if (e) {
      setError(readableError(e.message));
      return;
    }
    const d = data as {
      code: string;
      token: string;
      seat: number;
      room_id: string;
      player_id: string;
    } | null;
    if (!d) return;
    /* Save the seat BEFORE navigating, or the new room loads with no
       identity and offers to seat you in a room you are already in. The
       session store filters on playerId, so a seat saved without one is
       silently discarded — which looks exactly like the rematch failing. */
    saveSeat({
      roomId: d.room_id,
      code: d.code,
      playerId: d.player_id,
      sessionToken: d.token,
      seat: d.seat,
    });
    router.push(`/room/${d.code}`);
  }

  if (!sessionToken) {
    return (
      <div className="flex flex-wrap items-center gap-2">
        <Link href="/new" className="btn btn-ghost h-11 px-4 text-[0.8125rem]">
          Start your own
        </Link>
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-2">
      <div className="flex flex-wrap items-center gap-2">
        {rematchCode ? (
          <Button variant="primary" size="lg" disabled={busy} onClick={() => void go("claim_rematch")}>
            {busy ? "Joining" : "Join the rematch"}
          </Button>
        ) : (
          <Button variant="ghost" size="lg" disabled={busy} onClick={() => void go("create_rematch")}>
            {busy ? "Setting it up" : "Run it back"}
          </Button>
        )}
        <Link href="/new" className="btn btn-ghost h-11 px-4 text-[0.8125rem]">
          Different settings
        </Link>
      </div>
      <p className="text-[0.8125rem] leading-snug text-muted">
        {rematchCode
          ? "Your opponent has already set one up — same settings, same category, freshly shuffled."
          : "Same settings, same category, dealt again. No code to send: they are seated already."}
      </p>
      {error ? <p className="text-[0.8125rem] text-coral">{error}</p> : null}
    </div>
  );
}
