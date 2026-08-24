import { describe, expect, it } from "vitest";
import { licenseOf, mapLimit } from "./sources";

describe("licenseOf", () => {
  it("reads the free/non-free split off the Wikimedia path", () => {
    // this distinction is the whole licensing story and it is in the URL
    expect(licenseOf("https://upload.wikimedia.org/wikipedia/commons/3/34/Sean_Connery.jpg")).toBe(
      "free",
    );
    expect(licenseOf("https://upload.wikimedia.org/wikipedia/en/4/43/Dr._No_poster.jpg")).toBe(
      "nonfree",
    );
  });

  it("treats anything unrecognised as non-free rather than assuming safety", () => {
    expect(licenseOf("https://example.com/poster.jpg")).toBe("nonfree");
  });
});

describe("mapLimit", () => {
  it("preserves input order regardless of completion order", async () => {
    const out = await mapLimit([30, 1, 20, 2], 4, async (ms) => {
      await new Promise((r) => setTimeout(r, ms));
      return ms;
    });
    expect(out).toEqual([30, 1, 20, 2]);
  });

  it("never exceeds the concurrency cap", async () => {
    let live = 0;
    let peak = 0;
    await mapLimit([...Array(20).keys()], 3, async () => {
      peak = Math.max(peak, ++live);
      await new Promise((r) => setTimeout(r, 5));
      live--;
      return null;
    });
    expect(peak).toBeLessThanOrEqual(3);
  });

  it("handles an empty list without hanging", async () => {
    expect(await mapLimit([], 4, async () => 1)).toEqual([]);
  });
});
