"use client";

import { FlipDigits } from "./FlipDigits";
import { Rail } from "./Rail";
import { digitsOf, formatCents } from "@/lib/money";
import { seatAccent, type BoardPlayerView } from "@/lib/game/view";

export function PlayerStrip({
  p,
  startingCents,
  markerCents = null,
  isYou = false,
  onClock = false,
  isHigh = false,
  flashKey = 0,
  givesLeft = null,
  givesUnlimited = false,
}: {
  p: BoardPlayerView;
  startingCents: number;
  markerCents?: number | null;
  isYou?: boolean;
  onClock?: boolean;
  isHigh?: boolean;
  flashKey?: number;
  givesLeft?: number | null;
  /** the cap cannot bind, so a running count would be noise */
  givesUnlimited?: boolean;
}) {
  const accent = seatAccent(p.seat);
  return (
    <div
      className="flex flex-col gap-1.5 py-2.5 pl-2"
      style={{
        borderLeft: `2px solid ${onClock ? "var(--color-coral)" : "transparent"}`,
        transition: "border-color 160ms linear",
      }}
    >
      <div className="flex items-baseline gap-2">
        <span
          className="inline-block shrink-0"
          style={{ width: 8, height: 8, background: accent }}
          aria-hidden
        />
        <span className="type-display truncate text-[0.9375rem]">{p.name}</span>
        {isYou ? <span className="type-label text-muted">you</span> : null}
        {isHigh ? <span className="type-label text-coral">high</span> : null}
        {p.isBroke ? <span className="type-label text-coral">broke</span> : null}
        {givesLeft !== null && givesLeft > 0 ? (
          <span className="type-label text-teal">
            {givesUnlimited ? "\u221E gives" : `${givesLeft} give${givesLeft === 1 ? "" : "s"}`}
          </span>
        ) : null}

        <span className="type-num ml-auto shrink-0 text-[0.6875rem] text-muted">
          {p.filled}/{p.total}
        </span>
        <span
          className="shrink-0 text-[1.25rem] leading-none text-gold"
          title={`${formatCents(p.bankrollCents)} left`}
        >
          <span className="type-num">$</span>
          <FlipDigits text={digitsOf(p.bankrollCents)} />
        </span>
      </div>

      <Rail
        startingCents={startingCents}
        bankrollCents={p.bankrollCents}
        maxLegalBidCents={p.maxLegalBidCents}
        markerCents={markerCents}
        accent={accent}
        flashKey={flashKey}
      />
    </div>
  );
}
