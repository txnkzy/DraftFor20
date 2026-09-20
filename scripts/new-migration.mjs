#!/usr/bin/env node
/**
 * Create a migration whose name cannot collide with anybody else's.
 *
 *   npm run new:migration -- add_widget_table
 *
 * Two people picking the next number by hand will eventually pick the same
 * one, and git will not notice: two different filenames merge cleanly and the
 * problem only surfaces when somebody has to decide which runs first. This
 * project has had that four times. A UTC timestamp removes the class of
 * problem — you would have to create two files in the same second.
 *
 * Timestamps sort after the existing 00xx files as plain strings, so new work
 * always runs last, which is what you want. Nothing existing is renamed:
 * renaming a migration somebody has already applied buys nothing and risks it
 * running twice.
 */
import { writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const DIR = "supabase/migrations";
const raw = process.argv.slice(2).join("_").trim();

if (!raw) {
  console.error('name it: npm run new:migration -- add_widget_table');
  process.exit(1);
}

const slug = raw
  .toLowerCase()
  .replace(/[^a-z0-9]+/g, "_")
  .replace(/^_+|_+$/g, "");

const d = new Date();
const p = (n, w = 2) => String(n).padStart(w, "0");
const stamp =
  `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}` +
  `${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}`;

const file = join(DIR, `${stamp}_${slug}.sql`);
if (existsSync(file)) {
  console.error(`${file} already exists`);
  process.exit(1);
}

writeFileSync(
  file,
  `-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · ${slug.replace(/_/g, " ")}
--
-- WHAT THIS IS FOR, and why it is worth a migration. Say what was wrong or
-- missing before, not just what the SQL does — the SQL already says that.
--
-- Two house rules this file has to keep:
--   · re-runnable from a partial state. The Supabase SQL editor runs
--     statements one at a time and does not roll back on failure.
--   · never split a caller from its dependency across two files.
-- ═══════════════════════════════════════════════════════════════════════════

-- your SQL here
`,
  "utf8",
);

console.log(file);
