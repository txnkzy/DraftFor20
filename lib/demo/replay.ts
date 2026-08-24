"use client";

import type { BoardPlayerView, BoardView } from "@/lib/game/view";

/**
 * A real hand of DraftFor20, expressed as a function of progress from 0 to 1.
 *
 * The landing page scrubs this with the scroll wheel and the room renders the
 * same BoardView shape from live data, so the marketing page is the product
 * rather than a picture of it.
 */

const TIMER = 15;
const ROSTER = 5;
const START = 2000;

type Step =
  | { t: "deal"; item: string; hold: number }
  | { t: "take"; seat: number; cents: number; hold: number }
  | { t: "raise"; seat: number; cents: number; hold: number }
  | { t: "pass"; seat: number; hold: number }
  | { t: "lock"; seat: number; item: string; cents: number; gifted: boolean; hold: number }
  | { t: "give"; seat: number; item: string; hold: number };

const SCRIPT: Step[] = [
  // holds are relative dwell, not seconds. Weighted so the moments that carry
  // meaning (a raise landing, a card locking) hold still, while connective
  // beats like a pass move on quickly.
  { t: "deal", item: "Ja'Marr Chase", hold: 2.0 },
  { t: "take", seat: 1, cents: 100, hold: 1.6 },
  { t: "raise", seat: 2, cents: 400, hold: 2.0 },
  { t: "raise", seat: 1, cents: 700, hold: 2.6 },
  { t: "pass", seat: 2, hold: 1.0 },
  { t: "lock", seat: 1, item: "Ja'Marr Chase", cents: 700, gifted: false, hold: 2.6 },
  { t: "deal", item: "Zach Ertz", hold: 1.8 },
  { t: "give", seat: 2, item: "Zach Ertz", hold: 1.4 },
  { t: "lock", seat: 1, item: "Zach Ertz", cents: 0, gifted: true, hold: 2.6 },
];

const TOTAL = SCRIPT.reduce((t, s) => t + s.hold, 0);

function mkPlayer(seat: number, name: string, bank: number, filled: number, gives: number): BoardPlayerView {
  const open = ROSTER - filled;
  const maxLegal = Math.max(Math.min(bank - 100 * Math.max(open - 1, 0), bank), 0);
  return {
    id: `demo-${seat}`, seat, name,
    bankrollCents: bank, maxLegalBidCents: maxLegal,
    openSlots: open, filled, total: ROSTER,
    isBroke: false, isHost: seat === 1, givesLeft: gives,
  };
}

export interface DemoFrame {
  view: BoardView;
  lock: { seat: number; itemName: string; priceCents: number; gifted: boolean } | null;
  caption: string;
}

const CAPTION: Record<Step["t"], string> = {
  deal: "The deck deals a name. Neither of you picked it and neither of you knows what is next.",
  take: "Ari takes them at the minimum. Now Bo can push the price up.",
  raise: "Every raise resets the clock.",
  pass: "Bo passes. That settles it.",
  lock: "It locks in and the money comes off the rail.",
  give: "Bo does not want him, so he lands on Ari's roster for free and burns a spot.",
};

/** progress is 0..1 */
export function frameAt(progress: number): DemoFrame {
  const at = Math.max(0, Math.min(0.9999, progress)) * TOTAL;
  let acc = 0;
  let index = 0;
  for (let i = 0; i < SCRIPT.length; i++) {
    if (at < acc + SCRIPT[i].hold) { index = i; break; }
    acc += SCRIPT[i].hold;
    index = i;
  }
  const step = SCRIPT[index];

  let a = START, b = START, aF = 0, bF = 0, aG = 2, bG = 2;
  for (let i = 0; i < index; i++) {
    const s = SCRIPT[i];
    if (s.t === "lock") {
      if (s.seat === 1) { a -= s.cents; aF += 1; } else { b -= s.cents; bF += 1; }
    } else if (s.t === "give") {
      if (s.seat === 1) aG -= 1; else bG -= 1;
    }
  }

  // standing bid and the live card
  let bid = 0, high = 1, item: string | null = null, opener = 1;
  for (let i = 0; i <= index; i++) {
    const s = SCRIPT[i];
    if (s.t === "deal") { item = s.item; bid = 100; }
    else if (s.t === "take") { bid = s.cents; high = s.seat; opener = s.seat; }
    else if (s.t === "raise") { bid = s.cents; high = s.seat; }
    else if (s.t === "lock" || s.t === "give") { item = null; }
  }

  const offering = step.t === "deal" || step.t === "give";
  const bidding = step.t === "take" || step.t === "raise" || step.t === "pass";

  // the clock resets on every take and raise
  let clockStart = 0;
  for (let i = index; i >= 0; i--) {
    if (SCRIPT[i].t === "take" || SCRIPT[i].t === "raise" || SCRIPT[i].t === "deal") {
      clockStart = SCRIPT.slice(0, i).reduce((t, s) => t + s.hold, 0);
      break;
    }
  }
  const elapsed = at - clockStart;
  const left = Math.max(TIMER - elapsed * 3.2, 0);
  const seconds = Math.ceil(left);

  return {
    view: {
      title: "Football Draft",
      phase: offering ? "offering" : bidding ? "bidding" : "offering",
      itemName: item,
      // the landing replay ships no artwork and fetches nothing: null draws
      // the generated card from the name, which is also an honest preview of
      // what a category with no pictures looks like
      imageUrl: null,
      currentBidCents: bid,
      highBidderSeat: bidding ? high : null,
      onClockSeat: bidding ? (high === 1 ? 2 : 1) : null,
      openerSeat: offering ? (step.t === "give" ? step.seat : opener) : null,
      deckRemaining: 28 - index,
      startingCents: START,
      minBidCents: 100,
      timerSeconds: TIMER,
      noClock: false,
      fraction: left / TIMER,
      seconds,
      urgent: seconds <= 5 && bidding,
      critical: seconds <= 3 && seconds > 0 && bidding,
      lotId: `demo-lot-${index}`,
      players: [mkPlayer(1, "Ari", a, aF, aG), mkPlayer(2, "Bo", b, bF, bG)],
      lastLock: null,
    },
    lock:
      step.t === "lock"
        ? { seat: step.seat, itemName: step.item, priceCents: step.cents, gifted: step.gifted }
        : null,
    caption: CAPTION[step.t],
  };
}
