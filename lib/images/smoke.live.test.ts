/**
 * Hits Wikipedia, Wikidata and the Cover Art Archive for real, so it is
 * opt-in: `LIVE_IMAGE_TEST=1 npx vitest run`. The rest of the suite stays
 * hermetic and a flaky network can never fail a build.
 */
import { expect, it } from "vitest";
import { resolveImages } from "./resolve";
import type { WikiItem } from "../wikipedia";

const live = it.runIf(!!process.env.LIVE_IMAGE_TEST);

const ITEMS: WikiItem[] = [
  { name: "Iron Man", title: "Iron Man" },
  { name: "Captain America", title: "Captain America" },
  { name: "Yosemite", title: "Yosemite National Park" },
  { name: "Cardiff City", title: "Cardiff City F.C." },
  { name: "Abbey Road", title: "Abbey Road" },
  { name: "Dr. No", title: "Dr. No (film)" },
  { name: "Zzqqx Nonexistent Thing", title: null },
];

live("resolves every item, live", { timeout: 60_000 }, async () => {
  const out = await resolveImages(ITEMS);
  for (const r of out) {
    console.log(`${r.name.padEnd(26)} ${r.source.padEnd(12)} ${r.license.padEnd(10)} ${r.url.slice(0, 76)}`);
  }
  expect(out).toHaveLength(ITEMS.length);
  expect(out.every((r) => r.url.length > 0)).toBe(true);
  expect(out.map((r) => r.name)).toEqual(ITEMS.map((i) => i.name));
});

live("freeOnly falls back to generated instead of serving fair-use", { timeout: 60_000 }, async () => {
  const out = await resolveImages(ITEMS, { freeOnly: true });
  console.log("\nfreeOnly:");
  for (const r of out) console.log(`  ${r.name.padEnd(26)} ${r.source.padEnd(12)} ${r.license}`);
  expect(out.every((r) => r.license !== "nonfree")).toBe(true);
  expect(out.every((r) => r.url.length > 0)).toBe(true);
});
