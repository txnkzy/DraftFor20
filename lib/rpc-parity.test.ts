import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * EVERY RPC THE APP CALLS MUST BE DEFINED BY A MIGRATION.
 *
 * plpgsql does not validate a function body at creation, and PostgREST only
 * fails at call time, so a caller shipped without its function is invisible
 * until a user clicks the button. That is not hypothetical: on 20 Sep,
 * create_rematch, df20_name_squash and room_scouting were all live in the
 * app and absent from the database at once. df20_name_squash was the worst —
 * join_room called it, so NOBODY COULD JOIN A ROOM, and the only symptom was
 * an error message in one person's browser.
 *
 * This is a static check. It cannot know whether a migration was APPLIED —
 * only df20_selfcheck() can, and it runs in the bundle footer. What it does
 * catch is the other half: code merged ahead of the SQL that supports it.
 */

const ROOT = join(import.meta.dirname, "..");
const CODE_DIRS = ["app", "components", "lib"];

function walk(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    if (name === "node_modules" || name === ".next") continue;
    const full = join(dir, name);
    if (statSync(full).isDirectory()) walk(full, out);
    else if (/\.(ts|tsx)$/.test(name)) out.push(full);
  }
  return out;
}

/** Names the app asks PostgREST for. */
function calledRpcs(): Map<string, string> {
  const found = new Map<string, string>();
  for (const dir of CODE_DIRS) {
    for (const file of walk(join(ROOT, dir))) {
      const src = readFileSync(file, "utf8");
      for (const m of src.matchAll(/\.rpc\(\s*"([a-z0-9_]+)"/g)) {
        if (!found.has(m[1])) found.set(m[1], file.slice(ROOT.length + 1));
      }
    }
  }
  return found;
}

/** Names any migration defines. */
function definedFunctions(): Set<string> {
  const dir = join(ROOT, "supabase", "migrations");
  const out = new Set<string>();
  for (const name of readdirSync(dir)) {
    if (!name.endsWith(".sql")) continue;
    const src = readFileSync(join(dir, name), "utf8");
    for (const m of src.matchAll(
      /create\s+(?:or\s+replace\s+)?function\s+public\.([a-z0-9_]+)/gi,
    )) {
      out.add(m[1].toLowerCase());
    }
  }
  return out;
}

describe("every RPC the app calls is defined in a migration", () => {
  it("has no callers without a function", () => {
    const called = calledRpcs();
    const defined = definedFunctions();
    const orphans = [...called.entries()]
      .filter(([name]) => !defined.has(name))
      .map(([name, file]) => `${name}  (called from ${file})`);
    expect(orphans, `\n${orphans.join("\n")}\n`).toEqual([]);
  });

  it("found something to check, so a broken matcher cannot pass silently", () => {
    expect(calledRpcs().size).toBeGreaterThan(30);
    expect(definedFunctions().size).toBeGreaterThan(50);
  });
});

/**
 * A migration that is not in build-bundle.sh does not exist as far as a fresh
 * install is concerned. Four numbered files and four timestamped ones were
 * applied to production by hand and never registered, so APPLY_V7.sql built a
 * database missing the rematch, the room scouting and the restored grants.
 */
describe("every migration is registered in the bundle", () => {
  it("leaves nothing out", () => {
    const bundle = readFileSync(join(ROOT, "supabase", "build-bundle.sh"), "utf8");
    const missing = readdirSync(join(ROOT, "supabase", "migrations"))
      .filter((f) => f.endsWith(".sql"))
      .map((f) => f.replace(/\.sql$/, ""))
      // 0000–0007 are the base schema; the bundle is additive and starts at 0008
      .filter((b) => !/^000[0-7]_/.test(b))
      .filter((b) => !bundle.includes(b));
    expect(missing, `\n${missing.join("\n")}\n`).toEqual([]);
  });
});
