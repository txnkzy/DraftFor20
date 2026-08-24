"use client";

import type { ReactNode } from "react";
import { CardImage } from "./CardImage";
import { FlipDigits } from "./FlipDigits";
import { TensionBar } from "./TensionBar";
import { digitsOf } from "@/lib/money";
import { seatAccent, type BoardView } from "@/lib/game/view";

/**
 * The card currently on the block. Presentational only, so the landing page
 * can drive it from a scripted replay through the same component the live room
 * uses. It knows nothing about what is coming next, because nothing does
 * outside the database.
 */
export function BidBoard({
  view,
  children,
  lock = null,
  raiseKey = 0,
}: {
  view: BoardView;
  children?: ReactNode;
  lock?: { seat: number; itemName: string; priceCents: number; gifted: boolean } | null;
  /** bump to replay the raise pulse */
  raiseKey?: number;
}) {
  const bidding = view.phase === "bidding";
  const offering = view.phase === "offering";
  const highName = view.players.find((p) => p.seat === view.highBidderSeat)?.name ?? null;
  const clockName = view.players.find((p) => p.seat === view.onClockSeat)?.name ?? null;
  const openerName = view.players.find((p) => p.seat === view.openerSeat)?.name ?? null;

  if (lock) {
    const accent = seatAccent(lock.seat);
    const winner = view.players.find((p) => p.seat === lock.seat)?.name ?? "";
    return (
      <div
        className="panel flex flex-col items-center gap-1 px-4 py-8 text-center"
        style={{ borderRadius: "var(--radius-card)", borderColor: "var(--color-teal)" }}
      >
        <span className="type-label text-teal">{lock.gifted ? "handed over" : "locked"}</span>
        <p className="type-display anim-lock-drop mt-1 text-[1.75rem]">{lock.itemName}</p>
        <p className="type-num text-[1.5rem] leading-none text-gold">
          {lock.gifted ? "free" : <><span>$</span><FlipDigits text={digitsOf(lock.priceCents)} /></>}
        </p>
        <p className="type-label mt-1" style={{ color: accent }}>
          {winner}
        </p>
      </div>
    );
  }

  return (
    <div
      className="panel flex flex-col overflow-hidden"
      style={{ borderRadius: "var(--radius-card)" }}
    >
      <div className="flex items-baseline justify-between gap-3 border-b px-4 pb-2 pt-3 rule">
        <span className="type-label text-muted">on the block</span>
        <span className="type-num text-[0.6875rem] text-muted">
          {view.deckRemaining} left in the deck
        </span>
      </div>

      <div className="flex flex-col gap-3 px-4 py-5">
        {view.itemName ? (
          <div key={view.lotId ?? "none"} className="anim-deal flex flex-col gap-3">
            <CardImage name={view.itemName} url={view.imageUrl} height={112} />
            <p className="type-display text-[1.875rem] leading-[1.02]">{view.itemName}</p>
          </div>
        ) : (
          <p className="text-[0.9375rem] text-muted">
            {view.phase === "complete" ? "Both rosters are full." : "Dealing."}
          </p>
        )}

        {offering ? (
          <div className="flex items-end justify-between gap-3">
            <div className="flex flex-col">
              <span className="type-label text-muted">
                {openerName ? `${openerName} decides` : ""}
              </span>
              <span className="type-num text-[2.25rem] leading-none text-gold">
                <span>$</span>
                <FlipDigits text={digitsOf(view.currentBidCents)} />
              </span>
            </div>
            <span
              className={`type-num text-[1.75rem] leading-none ${view.critical ? "anim-clock-critical" : ""}`}
              style={{ color: view.urgent ? "var(--color-coral)" : "var(--color-ink)" }}
              title={view.noClock ? "no time limit" : undefined}
            >
              {view.noClock ? "\u221e" : (view.seconds ?? view.timerSeconds)}
            </span>
          </div>
        ) : null}

        {bidding ? (
          <>
            <div className="flex items-end justify-between gap-3">
              <div className="flex flex-col">
                <span className="type-label text-muted">
                  {highName ? `${highName} is high` : "opening bid"}
                </span>
                <span
                  key={raiseKey}
                  className="type-num anim-raise text-[3.25rem] leading-[0.9] text-gold"
                >
                  <span>$</span>
                  <FlipDigits text={digitsOf(view.currentBidCents)} />
                </span>
              </div>

              <div className="flex flex-col items-end">
                <span className="type-label text-muted">{clockName ? `${clockName} is up` : ""}</span>
                <span
                  className={`type-num text-[2.25rem] leading-[0.9] ${view.critical ? "anim-clock-critical" : ""}`}
                  style={{ color: view.urgent ? "var(--color-coral)" : "var(--color-ink)" }}
                  title={view.noClock ? "no time limit" : undefined}
                >
                  {view.noClock ? "\u221e" : (view.seconds ?? view.timerSeconds)}
                </span>
              </div>
            </div>
            {view.noClock ? null : (
              <TensionBar fraction={view.fraction} urgent={view.urgent} critical={view.critical} />
            )}
          </>
        ) : null}

        {offering && !view.noClock ? (
          <TensionBar fraction={view.fraction} urgent={view.urgent} critical={view.critical} />
        ) : null}
      </div>

      {children ? <div className="border-t px-4 py-4 rule">{children}</div> : null}
    </div>
  );
}
