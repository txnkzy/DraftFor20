import { describe, expect, it } from "vitest";
import { isBroke, isUnderfunded, maxLegalBid, minRaise, reserveCents } from "./rules";

describe("maxLegalBid: Hard Cap + Reserve Rule", () => {
  it("matches the spec's worked example", () => {
    // 3 slots left total, this bid is for one of them, minimum bid $1
    // -> the other 2 need $1 each reserved -> max = bankroll - $2
    expect(maxLegalBid(1000, 100, 3)).toBe(800);
  });

  it("caps the opening bid of a standard $20 / 5 slot room at $16", () => {
    expect(maxLegalBid(2000, 100, 5)).toBe(1600);
  });

  it("lets a player spend everything on their last slot", () => {
    expect(maxLegalBid(2000, 100, 1)).toBe(2000);
    expect(maxLegalBid(200, 100, 1)).toBe(200);
  });

  it("is exact at the boundary where bankroll equals the full reserve", () => {
    // $5 across 5 slots at $1: every slot costs exactly the minimum
    expect(maxLegalBid(500, 100, 5)).toBe(100);
    expect(maxLegalBid(400, 100, 4)).toBe(100);
    expect(maxLegalBid(100, 100, 1)).toBe(100);
  });

  it("degrades instead of deadlocking in an underfunded room", () => {
    // $3 across 5 slots: raw formula is -$1, which would block every action
    expect(maxLegalBid(300, 100, 5)).toBe(100);
    expect(maxLegalBid(100, 100, 5)).toBe(100);
  });

  it("returns 0 for a broke player", () => {
    expect(maxLegalBid(0, 100, 2)).toBe(0);
    expect(maxLegalBid(50, 100, 3)).toBe(0);
  });

  it("falls back to the hard cap when the minimum bid is 0", () => {
    expect(maxLegalBid(500, 0, 5)).toBe(500);
    expect(maxLegalBid(0, 0, 5)).toBe(0);
  });

  it("never exceeds the bankroll and never goes negative", () => {
    for (let bankroll = 0; bankroll <= 2500; bankroll += 25) {
      for (let open = 0; open <= 8; open++) {
        for (const min of [0, 50, 100, 300]) {
          const m = maxLegalBid(bankroll, min, open);
          expect(m).toBeGreaterThanOrEqual(0);
          expect(m).toBeLessThanOrEqual(bankroll);
        }
      }
    }
  });

  it("leaves enough behind to fill every remaining slot when the room is funded", () => {
    // spend the maximum every single turn and you must still finish complete
    const MIN = 100;
    let bankroll = 2000;
    for (let open = 5; open > 0; open--) {
      const bid = maxLegalBid(bankroll, MIN, open);
      expect(bid).toBeGreaterThanOrEqual(MIN);
      bankroll -= bid;
      expect(bankroll).toBeGreaterThanOrEqual(MIN * (open - 1));
    }
    expect(bankroll).toBe(0);
  });

  it("returns 0 once there are no slots left to fill", () => {
    expect(maxLegalBid(2000, 100, 0)).toBe(0);
  });
});

describe("reserveCents", () => {
  it("reserves nothing on the final slot", () => {
    expect(reserveCents(100, 1)).toBe(0);
    expect(reserveCents(100, 0)).toBe(0);
  });
  it("reserves one minimum bid per other unfilled slot", () => {
    expect(reserveCents(100, 5)).toBe(400);
    expect(reserveCents(25, 3)).toBe(50);
  });
});

describe("isBroke", () => {
  it("is true only when a minimum bid is unaffordable and slots remain", () => {
    expect(isBroke(0, 100, 3)).toBe(true);
    expect(isBroke(99, 100, 1)).toBe(true);
    expect(isBroke(100, 100, 3)).toBe(false);
    expect(isBroke(0, 100, 0)).toBe(false);
    expect(isBroke(0, 0, 3)).toBe(false);
  });
});

describe("minRaise", () => {
  it("raises by at least the minimum bid", () => {
    expect(minRaise(700, 100)).toBe(800);
  });
  it("still moves when the minimum bid is 0", () => {
    expect(minRaise(700, 0)).toBe(701);
  });
});

describe("isUnderfunded", () => {
  it("flags rooms where somebody must go broke", () => {
    expect(isUnderfunded(300, 100, 5)).toBe(true);
    expect(isUnderfunded(500, 100, 5)).toBe(false);
    expect(isUnderfunded(2000, 100, 5)).toBe(false);
  });
});
