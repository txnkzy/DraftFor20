"use client";

/**
 * THE RAIL — the signature element.
 *
 * One bar per player, always on screen, in three regions:
 *   SPENT     recessed
 *   LIVE      what you may legally commit right now (= server's max legal bid)
 *   RESERVED  hatched. min_bid x remaining slots. Legally untouchable.
 *
 * During a bid war your bid slides along the live region as a bright marker
 * and you watch it close on the hatch. Hitting the wall flashes the hatch
 * rather than throwing a toast, so the Reserve Rule is something you SEE.
 */
export function Rail({
  startingCents,
  bankrollCents,
  maxLegalBidCents,
  markerCents = null,
  accent,
  flashKey = 0,
  height = 10,
}: {
  startingCents: number;
  bankrollCents: number;
  maxLegalBidCents: number;
  /** a pending or standing bid, drawn as a marker along the live region */
  markerCents?: number | null;
  accent: string;
  /** bump to replay the hatch flash: the element remounts and the CSS
   *  animation runs once, so no timer state is needed */
  flashKey?: number;
  height?: number;
}) {
  const total = Math.max(startingCents, 1);
  const spent = Math.max(startingCents - bankrollCents, 0);
  const live = Math.max(Math.min(maxLegalBidCents, bankrollCents), 0);
  const reserved = Math.max(bankrollCents - live, 0);
  const pct = (v: number) => `${Math.max(0, Math.min(100, (v / total) * 100))}%`;

  const markerAt =
    markerCents !== null && markerCents > 0 ? Math.min(spent + markerCents, total) : null;

  return (
    <div className="rail-track relative w-full" style={{ height }}>
      <div className="absolute inset-0 flex">
        <div className="rail-spent h-full" style={{ width: pct(spent) }} />
        <div className="h-full" style={{ width: pct(live), background: accent }} />
        <div
          key={flashKey}
          className={`hatch-reserve h-full ${flashKey ? "anim-hatch" : ""}`}
          style={{ width: pct(reserved) }}
        />
      </div>
      {markerAt !== null ? (
        <div
          className="absolute w-[2px] bg-bone"
          style={{ left: pct(markerAt), top: -3, bottom: -3, transition: "left 160ms linear" }}
          aria-hidden
        />
      ) : null}
    </div>
  );
}
