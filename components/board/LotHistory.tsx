"use client";

import { formatCents } from "@/lib/money";
import { seatAccent } from "@/lib/game/view";
import type { BidEvent, Player } from "@/lib/game/types";

const VERB: Record<string, string> = {
  reveal: "dealt",
  offer_take: "took it",
  offer_give: "gave it away",
  offer_forced: "had to take it",
  discard: "let it go",
  raise: "raised",
  pass: "passed",
  timeout_pass: "ran out",
  won: "wins it",
  blocked_win: "no room left",
};

/** The bid war, as a readable strip. This is the thing people rewatch. */
export function LotHistory({
  events,
  players,
  lotId,
}: {
  events: BidEvent[];
  players: Player[];
  lotId: string | null;
}) {
  const rows = events.filter((e) => e.lot_id === lotId);
  if (!lotId || rows.length === 0) return null;

  return (
    <ol className="flex flex-wrap items-center gap-x-2.5 gap-y-1">
      {rows.filter((e) => e.action !== "reveal").map((e) => {
        const p = players.find((x) => x.id === e.player_id);
        const accent = p ? seatAccent(p.seat) : "var(--color-muted)";
        const money = e.action === "raise" || e.action === "offer_take";
        return (
          <li key={e.id} className="flex items-baseline gap-1 whitespace-nowrap">
            <span className="type-label" style={{ color: accent }}>
              {p?.display_name ?? "—"}
            </span>
            {money ? (
              <span className="type-num text-[0.8125rem]" style={{ color: accent }}>
                {formatCents(e.amount_cents ?? 0)}
              </span>
            ) : (
              <span className="text-[0.75rem] text-muted">{VERB[e.action] ?? e.action}</span>
            )}
          </li>
        );
      })}
    </ol>
  );
}
