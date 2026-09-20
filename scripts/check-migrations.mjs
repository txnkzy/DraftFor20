#!/usr/bin/env node
/**
 * Two people numbering migrations by hand will collide, and git will not
 * notice. `0057_one_free_lookup.sql` and `0057_usernames_and_leaderboard.sql`
 * are different filenames, so a merge containing both is perfectly clean —
 * the damage shows up later, when somebody has to decide which 0057 runs
 * first, or when two files on one number touch the same function and the
 * winner is whichever happened to run last.
 *
 * Node rather than bash on purpose: this has to run on Windows too.
 *
 *   node scripts/check-migrations.mjs
 */
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const DIR = "supabase/migrations";
const files = readdirSync(DIR)
  .filter((f) => f.endsWith(".sql"))
  .sort();

/* Collisions that shipped before this check existed and are applied
   everywhere. Renaming a migration somebody has already run buys nothing and
   risks it running twice, so these are recorded as debt rather than fixed.
   Do not add to this list to silence a NEW collision — renumber instead,
   which is free as long as the migration has not been applied yet. */
const HISTORICAL = new Set(["0041"]);

let failed = false;
const err = (m) => {
  failed = true;
  console.error(`  ERROR  ${m}`);
};
const note = (m) => console.log(`  note   ${m}`);

/* ── 1. two migrations claiming one number ─────────────────────────────── */
const byNumber = new Map();
for (const f of files) {
  const n = (f.match(/^(\d+)/) || [])[1];
  if (!n) {
    note(`${f} has no leading number`);
    continue;
  }
  byNumber.set(n, [...(byNumber.get(n) ?? []), f]);
}
for (const [n, group] of [...byNumber].sort()) {
  if (group.length < 2) continue;
  if (HISTORICAL.has(n)) {
    note(`migration ${n} is claimed by ${group.length} files (known, already applied)`);
  } else {
    err(`migration ${n} is claimed by ${group.length} files: ${group.join(", ")}`);
  }
}

/* ── 2. one function, two migrations ───────────────────────────────────── */
/* Redefining a function in a LATER migration is normal — that is how these
   evolve, and admin_activity has legitimately been rewritten three times.
   Redefining it from two files on the SAME number is not, because nothing
   decides which one wins. Everything else is printed for a human to glance
   at rather than failed on. */
const defs = new Map();
for (const f of files) {
  const src = readFileSync(join(DIR, f), "utf8");
  for (const m of src.matchAll(/create or replace function public\.([a-z0-9_]+)\s*\(/g)) {
    defs.set(m[1], [...(defs.get(m[1]) ?? []), f]);
  }
}
for (const [fn, where] of [...defs].sort()) {
  /* Deduplicate by FILE first. Two definitions inside one migration is an
     overload pair — df20_cache_wikipedia has three arities in 0043 — and
     entirely normal. What matters is two separate files on one number. */
  const uniqueFiles = [...new Set(where)];
  if (uniqueFiles.length < 2) continue;

  const collided = new Map();
  for (const f of uniqueFiles) {
    const n = f.match(/^(\d+)/)[1];
    collided.set(n, [...(collided.get(n) ?? []), f]);
  }
  for (const [n, group] of collided) {
    if (group.length > 1) {
      err(`public.${fn}() is defined by ${group.length} different files on ${n}: ${group.join(", ")}`);
    }
  }
}

console.log(
  failed
    ? "\nmigrations: PROBLEMS ABOVE — fix before pushing"
    : `\nmigrations: ${files.length} files, numbering clean`,
);
process.exit(failed ? 1 : 0);
