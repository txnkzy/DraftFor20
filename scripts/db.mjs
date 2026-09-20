#!/usr/bin/env node
/**
 * Apply migrations to Supabase without the copy-and-paste.
 *
 *   npm run db:status     what is applied, what is pending
 *   npm run db:baseline   record every current file as applied, WITHOUT running it
 *   npm run db:push       run the pending ones, oldest first
 *
 * WHY A LEDGER. Without one the only honest answer to "what is pending" is
 * "everything", and re-running everything on this project does not work: 0046
 * asserts Jujutsu Kaisen has 30 items and it has 28, so a full replay stops
 * there. `db:baseline` is the one-time escape — it writes the filenames into
 * the ledger without executing them, which is correct for a database that is
 * already up to date, and wrong for any other. Run it once, on a database you
 * believe is current.
 *
 * WHY NOT THE APP'S SUPABASE CLIENT. The rule in CLAUDE.md — no direct
 * Postgres connections — is about the APPLICATION, whose only path to the
 * database is PostgREST with a publishable key. This is an operator script
 * run by hand from a developer machine, with a credential the app never sees
 * and which lives nowhere in the repo.
 *
 * THE CREDENTIAL. Set SUPABASE_DB_URL yourself; this never stores or prints
 * it. Supabase dashboard → Project Settings → Database → Connection string →
 * URI, with your database password substituted in. Put it in .env.local
 * (gitignored) or export it in your shell.
 */
import { readdirSync, readFileSync } from "node:fs";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { createHash } from "node:crypto";
import pg from "pg";

const DIR = "supabase/migrations";
const cmd = process.argv[2] ?? "status";

/* .env.local is the same place the app's values live, so one file to edit */
function connectionString() {
  let url = process.env.SUPABASE_DB_URL;
  if (!url && existsSync(".env.local")) {
    const m = readFileSync(".env.local", "utf8").match(/^SUPABASE_DB_URL=(.+)$/m);
    if (m) url = m[1].trim().replace(/^["']|["']$/g, "");
  }
  if (!url) {
    console.error(
      "SUPABASE_DB_URL is not set.\n\n" +
        "  Supabase dashboard → Project Settings → Database → Connection string → URI\n" +
        "  Substitute your database password, then add it to .env.local as:\n\n" +
        "      SUPABASE_DB_URL=postgresql://postgres:...@db.<ref>.supabase.co:5432/postgres\n\n" +
        "  .env.local is gitignored. Nothing here prints or stores the value.",
    );
    process.exit(1);
  }
  return url;
}

const files = () =>
  readdirSync(DIR)
    .filter((f) => f.endsWith(".sql"))
    .sort();

const sha = (s) => createHash("sha256").update(s).digest("hex").slice(0, 12);

async function main() {
  const url = connectionString();
  /* Supabase requires TLS and presents a certificate this script has no chain
     for, hence rejectUnauthorized: false. A local socket or localhost has no
     TLS at all and refuses the handshake outright, so the two cases cannot
     share a setting. */
  const isLocal = /localhost|127\.0\.0\.1|host=\/|^postgres(ql)?:\/\/[^@]*@\//.test(url);
  const client = new pg.Client({
    connectionString: url,
    ssl: isLocal ? false : { rejectUnauthorized: false },
    application_name: "df20-db-script",
  });
  await client.connect();

  await client.query(`
    create table if not exists public.df20_schema_migrations (
      filename   text primary key,
      checksum   text not null,
      applied_at timestamptz not null default now()
    )`);
  await client.query(
    `revoke all on table public.df20_schema_migrations from public, anon, authenticated`,
  );

  const { rows } = await client.query(
    "select filename, checksum from public.df20_schema_migrations",
  );
  const applied = new Map(rows.map((r) => [r.filename, r.checksum]));
  const all = files();
  const pending = all.filter((f) => !applied.has(f));

  if (cmd === "status") {
    /* A file whose contents changed after it was applied is worth saying out
       loud: the database is not what the repo says it is, and re-running is
       the only way back. It is not an error — plenty of edits are harmless. */
    const drifted = all.filter(
      (f) => applied.has(f) && applied.get(f) !== sha(readFileSync(join(DIR, f), "utf8")),
    );
    console.log(`applied: ${applied.size}   pending: ${pending.length}   of ${all.length} files`);
    if (pending.length) console.log("\npending:\n" + pending.map((f) => "  " + f).join("\n"));
    if (drifted.length)
      console.log(
        "\nchanged since they were applied (re-run to be sure the database matches):\n" +
          drifted.map((f) => "  " + f).join("\n"),
      );
    if (!pending.length && !drifted.length) console.log("\nup to date.");
  } else if (cmd === "baseline") {
    for (const f of pending) {
      await client.query(
        "insert into public.df20_schema_migrations (filename, checksum) values ($1,$2) on conflict do nothing",
        [f, sha(readFileSync(join(DIR, f), "utf8"))],
      );
    }
    console.log(`baselined ${pending.length} file(s) as already applied. Nothing was executed.`);
  } else if (cmd === "push") {
    if (!pending.length) {
      console.log("nothing pending.");
    }
    for (const f of pending) {
      const sql = readFileSync(join(DIR, f), "utf8");
      process.stdout.write(`  ${f} … `);
      try {
        /* No wrapping transaction. Several of these contain their own DO
           blocks and CREATE INDEX, and the Supabase SQL editor these were
           written for runs statements one at a time — so they are built to be
           re-runnable from a partial state rather than to roll back. Matching
           that behaviour keeps the two paths identical. */
        await client.query(sql);
        await client.query(
          "insert into public.df20_schema_migrations (filename, checksum) values ($1,$2) " +
            "on conflict (filename) do update set checksum = excluded.checksum, applied_at = now()",
          [f, sha(sql)],
        );
        console.log("ok");
      } catch (e) {
        console.log("FAILED");
        console.error(`\n${f}: ${e.message}\n`);
        console.error("Stopped. Nothing after this file was applied.");
        await client.end();
        process.exit(1);
      }
    }
    await client.query("notify pgrst, 'reload schema'");
    console.log("\nschema cache reload sent.");
  } else {
    console.error(`unknown command "${cmd}" — use status, baseline or push`);
    await client.end();
    process.exit(1);
  }

  await client.end();
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
