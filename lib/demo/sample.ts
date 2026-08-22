import type { CardModel } from "@/lib/results/cardModel";

/** A finished board, so the landing page shows the real card and not a mockup. */
export const SAMPLE_CARD: CardModel = {
  title: "Football Draft",
  code: "K7QM4P",
  rosterSize: 5,
  startingCents: 2000,
  accent: null,
  logoUrl: null,
  players: [
    {
      id: "a", seat: 1, name: "Ari",
      leftoverCents: 200, spentCents: 1800, busted: false,
      rows: [
        { pick: 1, item: "Josh Allen", priceCents: 700, gifted: false },
        { pick: 2, item: "Bijan Robinson", priceCents: 100, gifted: false },
        { pick: 3, item: "Ja'Marr Chase", priceCents: 800, gifted: false },
        { pick: 4, item: "Cade Otton", priceCents: 0, gifted: true },
        { pick: 5, item: "Younghoe Koo", priceCents: 200, gifted: false },
      ],
    },
    {
      id: "b", seat: 2, name: "Bo",
      leftoverCents: 0, spentCents: 2000, busted: false,
      rows: [
        { pick: 1, item: "Jayden Daniels", priceCents: 100, gifted: false },
        { pick: 2, item: "Saquon Barkley", priceCents: 900, gifted: false },
        { pick: 3, item: "Puka Nacua", priceCents: 100, gifted: false },
        { pick: 4, item: "Brock Bowers", priceCents: 800, gifted: false },
        { pick: 5, item: "Zach Ertz", priceCents: 100, gifted: false },
      ],
    },
  ],
  topLot: { item: "Saquon Barkley", priceCents: 900, winner: "Bo" },
  longestWar: { item: "Ja'Marr Chase", raises: 5 },
  giftCount: 1,
};
