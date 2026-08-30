import type { RoomState } from "@/lib/game/types";
import { isBusted, rosterOf, spentBy } from "@/lib/game/types";

export interface CardRow {
  pick: number;
  item: string;
  priceCents: number;
  gifted: boolean;
  /** optional so fixtures predating Force-or-Take still typecheck as rows */
  forced?: boolean;
}

export interface CardPlayer {
  id: string;
  seat: number;
  name: string;
  leftoverCents: number;
  spentCents: number;
  busted: boolean;
  rows: CardRow[];
}

export interface CardModel {
  title: string;
  code: string;
  rosterSize: number;
  startingCents: number;
  accent: string | null;
  logoUrl: string | null;
  players: CardPlayer[];
  /** the most expensive single buy in the room */
  topLot: { item: string; priceCents: number; winner: string } | null;
  /** the card that took the most raises to settle */
  longestWar: { item: string; raises: number } | null;
  giftCount: number;
}

/** One derivation shared by the results screen, the 9:16 card and the PNG. */
export function buildCardModel(s: RoomState): CardModel {
  const players: CardPlayer[] = s.players.map((p) => ({
    id: p.id,
    seat: p.seat,
    name: p.display_name,
    leftoverCents: p.bankroll_cents,
    spentCents: spentBy(s, p.id),
    busted: isBusted(s, p.id),
    rows: rosterOf(s, p.id).map((r) => ({
      pick: r.pick_number,
      item: r.item_name,
      priceCents: r.price_cents,
      gifted: r.gifted,
      forced: r.forced,
    })),
  }));

  let topLot: CardModel["topLot"] = null;
  for (const r of s.roster) {
    if (r.gifted) continue;
    if (!topLot || r.price_cents > topLot.priceCents) {
      topLot = {
        item: r.item_name,
        priceCents: r.price_cents,
        winner: s.players.find((x) => x.id === r.player_id)?.display_name ?? "",
      };
    }
  }

  const raises = new Map<string, number>();
  for (const e of s.events) {
    if (e.action !== "raise") continue;
    raises.set(e.lot_id, (raises.get(e.lot_id) ?? 0) + 1);
  }
  let longestWar: CardModel["longestWar"] = null;
  for (const [lotId, n] of raises) {
    if (longestWar && n <= longestWar.raises) continue;
    const ev = s.events.find((x) => x.lot_id === lotId && x.amount_cents !== null);
    if (!ev) continue;
    const entry = s.roster.find((r) => r.won_at >= ev.created_at);
    longestWar = { item: entry?.item_name ?? "", raises: n };
  }

  return {
    title: s.room.title,
    code: s.room.code,
    rosterSize: s.room.roster_size,
    startingCents: s.room.starting_bankroll_cents,
    accent: s.room.brand_accent,
    logoUrl: s.room.brand_logo_url,
    players,
    topLot,
    longestWar,
    giftCount: s.roster.filter((r) => r.gifted && !r.forced).length,
  };
}

/**
 * The card is a fixed 1080x1920 whatever the roster size, so the type scales
 * with the list length. Shared by the DOM card and the PNG route.
 */
export function cardMetrics(rowCount: number) {
  const t = rowCount <= 6 ? 0 : rowCount <= 10 ? 1 : 2;
  const pick = (a: number, b: number, c: number) => [a, b, c][t];
  return {
    titleSize: pick(84, 72, 60),
    nameSize: pick(52, 43, 34),
    numSize: pick(20, 18, 15),
    itemSize: pick(34, 28, 22),
    priceSize: pick(34, 28, 22),
    rowPadY: pick(44, 18, 10),
    totalSize: pick(150, 124, 100),
    columnGap: pick(48, 40, 32),
    railH: pick(14, 11, 8),
  };
}
