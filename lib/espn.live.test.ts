/**
 * Live, opt-in: LIVE_ESPN_TEST=1 npx vitest run lib/espn.live.test.ts
 * Hits ESPN, Wikipedia and Wikidata for real.
 */
import { expect, it } from "vitest";
import { fetchRoster, fetchTeams, resolvePlayerTitle } from "./espn";
import { resolveImages } from "./images/resolve";

const live = it.runIf(!!process.env.LIVE_ESPN_TEST);

live("resolves a real roster to verified articles + free images", { timeout: 300_000 }, async () => {
  const teams = await fetchTeams();
  const jax = teams.find((t) => /Jaguars/.test(t.name));
  expect(jax).toBeTruthy();

  const roster = (await fetchRoster(jax!.id)).slice(0, 18);
  console.log(`\n${jax!.name} — ${roster.length} players sampled`);

  const items: { name: string; title: string | null }[] = [];
  for (const p of roster) {
    const title = await resolvePlayerTitle(p, null);
    items.push({ name: p.name, title });
  }

  const imgs = await resolveImages(items, { freeOnly: true });
  let free = 0;
  for (let i = 0; i < items.length; i++) {
    const r = imgs[i];
    if (r.source !== "generated") free++;
    console.log(
      `  ${items[i].name.padEnd(22)} ${(items[i].title ?? "-").padEnd(34)} ${r.source.padEnd(11)} ${r.license}`,
    );
  }
  console.log(`  free pictures: ${free}/${items.length}`);

  expect(imgs).toHaveLength(items.length);
  expect(imgs.every((r) => r.license !== "nonfree")).toBe(true);
});
