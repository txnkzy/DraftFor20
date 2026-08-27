"use client";

import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { LibraryOptIn } from "./LibraryOptIn";
import { ExportPanel } from "./ExportPanel";
import { VoteLink } from "./VoteLink";
import { buildCardModel } from "@/lib/results/cardModel";
import { formatCents } from "@/lib/money";
import { seatAccent } from "@/lib/game/view";
import { useAudienceTally, type AudienceTally } from "@/lib/game/useAudienceTally";
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
                        <span className="type-label ml-1.5 text-teal">given</span>
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

      <div className="flex flex-wrap items-center gap-2">
        <Link href="/new" className="btn btn-ghost h-11 px-4 text-[0.8125rem]">
          Run it back
        </Link>
      </div>
    </div>
  );
}
