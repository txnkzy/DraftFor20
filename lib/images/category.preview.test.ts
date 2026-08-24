/**
 * A tool, not a test. Resolves a real category end to end and writes it where
 * the /dev/cards page can render it.
 *
 *   CAT="current NFL teams" npx vitest run lib/images/category.preview.test.ts
 *   CAT="James Bond films" FREE=1 npx vitest run lib/images/category.preview.test.ts
 *
 * Then open http://localhost:3000/dev/cards
 *
 * Opt-in via CAT so it never runs in the normal suite — it hits Wikipedia,
 * Wikidata and the Cover Art Archive for real.
 */
import { writeFileSync } from "node:fs";
import { it } from "vitest";
import { fetchCategory } from "../wikipedia";
import { resolveImages } from "./resolve";

const QUERY = process.env.CAT ?? "";
const FREE_ONLY = !!process.env.FREE;

it.runIf(QUERY)("resolve a category", { timeout: 300_000 }, async () => {
  const found = await fetchCategory(QUERY, 8);
  if (!found) throw new Error(`no Wikipedia list matched "${QUERY}"`);

  const resolved = await resolveImages(found.items, { freeOnly: FREE_ONLY });
  const counts = resolved.reduce<Record<string, number>>((a, r) => {
    a[r.source] = (a[r.source] ?? 0) + 1;
    return a;
  }, {});
  const real = resolved.filter((r) => r.source !== "generated").length;

  // vitest swallows console.log in some reporters; throw-free summary via stderr
  process.stderr.write(
    `\n  query   : ${QUERY}${FREE_ONLY ? "  (freeOnly)" : ""}\n` +
      `  article : ${found.title}\n` +
      `  items   : ${resolved.length}\n` +
      `  sources : ${JSON.stringify(counts)}\n` +
      `  pictures: ${real}/${resolved.length} = ${Math.round((100 * real) / resolved.length)}%\n\n`,
  );

  writeFileSync(
    new URL("../../app/dev/cards/category.json", import.meta.url).pathname,
    JSON.stringify(
      {
        query: QUERY,
        article: found.title,
        items: resolved.map((r) => ({
          name: r.name,
          url: r.source === "generated" ? null : r.url,
          source: r.source,
          license: r.license,
        })),
      },
      null,
      2,
    ),
  );
});
