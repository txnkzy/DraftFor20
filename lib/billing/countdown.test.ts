import { describe, expect, it } from "vitest";
import { remaining } from "./countdown";

const NOW = Date.parse("2026-03-01T12:00:00Z");
const inMs = (ms: number) => new Date(NOW + ms).toISOString();

describe("the pass countdown", () => {
  it("shows days and hours for a subscription a month out", () => {
    expect(remaining(inMs(31 * 24 * 3_600_000), NOW)).toBe("31d 0h");
  });

  it("shows a fresh 24-hour pass as a day, then hours and minutes", () => {
    expect(remaining(inMs(24 * 3_600_000), NOW)).toBe("1d 0h");
    expect(remaining(inMs(23 * 3_600_000 + 41 * 60_000), NOW)).toBe("23h 41m");
  });

  it("drops to minutes and seconds in the last hour", () => {
    expect(remaining(inMs(9 * 60_000 + 5_000), NOW)).toBe("9m 5s");
  });

  it("is null once it has run out, so nothing renders a negative clock", () => {
    expect(remaining(inMs(0), NOW)).toBeNull();
    expect(remaining(inMs(-60_000), NOW)).toBeNull();
  });

  it("is null for a date it cannot parse", () => {
    expect(remaining("not a date", NOW)).toBeNull();
  });
});
