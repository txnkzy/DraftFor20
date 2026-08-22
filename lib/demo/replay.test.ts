import { describe, expect, it } from "vitest";
import { frameAt } from "./replay";

/**
 * The scroll sequence is a pure function of progress, so the whole hand can be
 * tested without a browser. What is NOT covered here is Framer reporting
 * scroll progress, which is one documented call.
 */
describe("frameAt: the scripted hand", () => {
  it("opens with a dealt card and nothing bid", () => {
    const f = frameAt(0);
    expect(f.view.itemName).toBe("Ja'Marr Chase");
    expect(f.view.phase).toBe("offering");
    expect(f.caption).toMatch(/deck deals/i);
    expect(f.view.players[0].bankrollCents).toBe(2000);
    expect(f.view.players[1].bankrollCents).toBe(2000);
  });

  it("walks the whole hand as progress advances", () => {
    const seen = new Set<string>();
    for (let p = 0; p <= 1; p += 0.01) seen.add(frameAt(p).caption);
    // deal, take, raise, pass, lock, deal, give, lock -> 6 distinct captions
    expect(seen.size).toBeGreaterThanOrEqual(5);
  });

  it("pushes the price up over the sequence", () => {
    const bids = [0.05, 0.2, 0.35, 0.5].map((p) => frameAt(p).view.currentBidCents);
    expect(bids[bids.length - 1]).toBeGreaterThan(bids[0]);
    expect(Math.max(...bids)).toBe(700);
  });

  it("locks the card and takes the money off the winner", () => {
    let locked: ReturnType<typeof frameAt> | null = null;
    for (let p = 0; p <= 1; p += 0.005) {
      const f = frameAt(p);
      if (f.lock && !f.lock.gifted) { locked = f; break; }
    }
    expect(locked).not.toBeNull();
    expect(locked!.lock!.itemName).toBe("Ja'Marr Chase");
    expect(locked!.lock!.priceCents).toBe(700);
    // after the lock, seat 1 is down $7 and holds a player
    const after = frameAt(0.75);
    expect(after.view.players[0].bankrollCents).toBe(1300);
    expect(after.view.players[0].filled).toBeGreaterThanOrEqual(1);
  });

  it("ends with a card handed over for free, costing a give", () => {
    const end = frameAt(0.99);
    expect(end.lock?.gifted).toBe(true);
    expect(end.lock?.priceCents).toBe(0);
    expect(end.view.players[1].givesLeft).toBe(1); // Bo spent one of two
  });

  it("never shows a bankroll below zero or a reserve breach", () => {
    for (let p = 0; p <= 1; p += 0.01) {
      for (const pl of frameAt(p).view.players) {
        expect(pl.bankrollCents).toBeGreaterThanOrEqual(0);
        expect(pl.maxLegalBidCents).toBeLessThanOrEqual(pl.bankrollCents);
      }
    }
  });

  it("clamps out-of-range progress instead of throwing", () => {
    expect(() => frameAt(-1)).not.toThrow();
    expect(() => frameAt(2)).not.toThrow();
    expect(frameAt(-1).view.itemName).toBe("Ja'Marr Chase");
  });
});
