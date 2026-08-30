"use client";

import { formatCents } from "@/lib/money";
import { seatAccent } from "@/lib/game/view";
import type { RosterEntry } from "@/lib/game/types";

/**
 * A flat list of who you got and what you paid. No positions, no categories:
 * a team is just N names and N prices.
 *
 * `lockedEntryId` is the row a card has just been won into. It arrives from
 * above, overshoots and settles, so the moment reads as the card LANDING on
 * this roster rather than a list quietly growing by one.
 */
export function RosterColumn({
  seat,
  name,
  rosterSize,
  roster,
  lockedEntryId = null,
}: {
  seat: number;
  name: string;
  rosterSize: number;
  roster: RosterEntry[];
  lockedEntryId?: string | null;
}) {
  const accent = seatAccent(seat);
  const rows = [...roster].sort((a, b) => a.pick_number - b.pick_number);
  const empty = Math.max(rosterSize - rows.length, 0);

  return (
    <div className="flex min-w-0 flex-col">
      <div className="flex items-baseline gap-2 border-b pb-1.5 rule">
        <span style={{ width: 8, height: 8, background: accent }} aria-hidden />
        <span className="type-display truncate text-[0.875rem]">{name}</span>
        <span className="type-num ml-auto text-[0.6875rem] text-muted">
          {rows.length}/{rosterSize}
        </span>
      </div>

      <ul
        className="grid"
        style={{ gridTemplateColumns: "max-content minmax(0,1fr) max-content" }}
      >
        {rows.map((r) => {
          const locked = lockedEntryId === r.id;
          return (
            <li
              key={r.id}
              className={`col-span-full grid items-baseline border-b py-2 rule ${
                locked ? "anim-land-glow" : ""
              }`}
              style={{ gridTemplateColumns: "subgrid" }}
            >
              <span className="type-num pr-2.5 text-[0.6875rem] text-muted">{r.pick_number}</span>
              <span
                className={`min-w-0 truncate pr-2.5 text-[0.8125rem] ${locked ? "anim-land" : ""}`}
                title={r.item_name}
              >
                {r.item_name}
                {r.gifted ? (
                  <span className="type-label ml-1.5 text-teal">{r.forced ? "forced" : "given"}</span>
                ) : null}
              </span>
              <span
                className={`type-num text-right text-[0.8125rem] ${locked ? "anim-land" : ""}`}
                style={{ color: r.gifted ? "var(--color-teal)" : "var(--color-gold)" }}
              >
                {r.gifted ? "free" : formatCents(r.price_cents)}
              </span>
            </li>
          );
        })}

        {Array.from({ length: empty }).map((_, i) => (
          <li
            key={`e${i}`}
            className="col-span-full grid items-baseline border-b py-2 rule"
            style={{ gridTemplateColumns: "subgrid" }}
          >
            <span className="type-num pr-2.5 text-[0.6875rem] text-muted">
              {rows.length + i + 1}
            </span>
            <span className="text-[0.8125rem] text-muted">&mdash;</span>
            <span />
          </li>
        ))}
      </ul>
    </div>
  );
}
