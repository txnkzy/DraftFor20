"use client";

import { useCallback, useEffect, useState } from "react";
import { accessToken } from "@/lib/auth";
import { CATEGORY_LABEL, type Category, type CommitEntry } from "@/lib/changelog/categorize";
import { supabaseBrowser } from "@/lib/supabase/client";

/**
 * What the other person has been doing.
 *
 * Built for one question — "has this already been done?" — which is why NEW
 * FILES and NEW MIGRATIONS are given more room than line counts. A file that
 * did not exist last week is the strongest evidence that somebody has already
 * started on the thing you are about to start.
 *
 * Every field is read off the diff. The commit subject is shown verbatim as
 * metadata and never treated as a description of what changed; the file list
 * underneath is what actually happened.
 */
interface AuditRow {
  id: number;
  actor: string | null;
  action: string;
  target: string | null;
  detail: string | null;
  at: string;
}

const CATS: Category[] = ["database", "api", "ui", "logic", "dependency", "config", "docs"];

function ago(iso: string): string {
  const ms = Date.now() - Date.parse(iso);
  if (!Number.isFinite(ms)) return "";
  const m = Math.floor(ms / 60000);
  if (m < 60) return `${m}m ago`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h ago`;
  return `${Math.floor(h / 24)}d ago`;
}

export function Changelog() {
  const [entries, setEntries] = useState<CommitEntry[]>([]);
  const [audit, setAudit] = useState<AuditRow[]>([]);
  const [nextMigration, setNextMigration] = useState<string | null>(null);
  const [configured, setConfigured] = useState(true);
  const [problem, setProblem] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [cat, setCat] = useState<Category | "all">("all");
  const [who, setWho] = useState<string>("all");

  const load = useCallback(async () => {
    const token = await accessToken();
    const [commits, log] = await Promise.all([
      fetch("/api/admin/changelog", {
        headers: token ? { authorization: `Bearer ${token}` } : {},
        cache: "no-store",
      })
        .then((r) => r.json())
        .catch((e: unknown) => ({
          configured: true,
          entries: [],
          nextMigration: null,
          problem: `The changelog request itself failed: ${e instanceof Error ? e.message : String(e)}`,
        })),
      supabaseBrowser().rpc("admin_audit_log", { p_limit: 40 }),
    ]);
    return {
      commits: (commits.entries ?? []) as CommitEntry[],
      configured: commits.configured !== false,
      nextMigration: (commits.nextMigration ?? null) as string | null,
      problem: (commits.problem ?? null) as string | null,
      audit: ((log.data as AuditRow[] | null) ?? []),
    };
  }, []);

  useEffect(() => {
    let off = false;
    void (async () => {
      const d = await load();
      if (off) return;
      setEntries(d.commits);
      setAudit(d.audit);
      setConfigured(d.configured);
      setNextMigration(d.nextMigration);
      setProblem(d.problem);
      setLoading(false);
    })();
    return () => { off = true; };
  }, [load]);

  const authors = ["all", ...new Set(entries.map((e) => e.author))];
  const shown = entries.filter(
    (e) =>
      (who === "all" || e.author === who) &&
      (cat === "all" || (e.categories[cat]?.length ?? 0) > 0),
  );

  return (
    <section className="mt-11">
      <h2 className="type-display text-[1rem]">Changelog</h2>
      <p className="mt-1.5 max-w-2xl text-[0.875rem] leading-relaxed text-muted">
        What has changed in the repository, read straight off each diff. Nothing here is
        summarised or interpreted — the commit message is shown as metadata, and the file list
        underneath it is what actually happened.
      </p>

      {nextMigration ? (
        <p className="mt-4 border p-3 text-[0.875rem] rule">
          <span className="type-label text-gold">next migration number</span>{" "}
          <span className="type-num text-ink">{nextMigration}</span>{" "}
          <span className="text-muted">
            &mdash; take this one so you do not collide with the other person.
          </span>
        </p>
      ) : null}

      {!configured ? (
        <p className="mt-4 border border-dashed p-3 text-[0.875rem] leading-relaxed text-muted rule">
          <span className="type-label text-muted">commits unavailable</span> No{" "}
          <span className="type-num text-ink">GITHUB_TOKEN</span> reached this deployment, so only
          in-app admin actions are listed below. Set it in the project&apos;s environment variables
          for the Production environment — without the{" "}
          <span className="type-num text-ink">NEXT_PUBLIC_</span> prefix — and redeploy, since a
          running deployment does not pick up a new variable.
        </p>
      ) : null}

      {/* A token that is set and REFUSED used to look exactly like one that
          works: the notice above disappeared and nothing replaced it. */}
      {configured && problem ? (
        <p className="mt-4 border border-gold p-3 text-[0.875rem] leading-relaxed text-ink">
          <span className="type-label text-gold">
            {entries.length > 0 ? "token ignored" : "commits unavailable"}
          </span>{" "}
          {problem}
          {entries.length > 0 ? "" : " In-app admin actions are still listed below."}
        </p>
      ) : null}

      <div className="mt-4 flex flex-wrap gap-1.5">
        {(["all", ...CATS] as const).map((c) => (
          <button
            key={c}
            onClick={() => setCat(c as Category | "all")}
            className={`type-label border px-2.5 py-1.5 ${
              cat === c ? "border-coral text-coral" : "text-muted rule hover:text-ink"
            }`}
          >
            {c === "all" ? "Everything" : CATEGORY_LABEL[c as Category]}
          </button>
        ))}
      </div>

      {authors.length > 2 ? (
        <div className="mt-2 flex flex-wrap gap-1.5">
          {authors.map((a) => (
            <button
              key={a}
              onClick={() => setWho(a)}
              className={`type-label border px-2.5 py-1.5 ${
                who === a ? "border-teal text-teal" : "text-muted rule hover:text-ink"
              }`}
            >
              {a === "all" ? "Anyone" : a}
            </button>
          ))}
        </div>
      ) : null}

      {loading ? <p className="type-label mt-4 text-muted">loading</p> : null}

      <ul className="mt-4 flex flex-col">
        {shown.map((e) => (
          <li key={e.sha} className="border-b py-4 rule">
            <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1">
              <a
                href={e.url}
                target="_blank"
                rel="noreferrer"
                className="type-num text-[0.8125rem] text-teal hover:text-ink"
              >
                {e.shortSha}
              </a>
              <span className="min-w-0 flex-1 truncate text-[0.875rem]">{e.subject}</span>
              <span className="type-label shrink-0 text-muted">{e.author}</span>
              <span className="type-label shrink-0 text-muted">{ago(e.at)}</span>
            </div>

            {/* the two things that stop duplicated work */}
            {e.newMigrations.length > 0 ? (
              <p className="type-num mt-2 text-[0.8125rem] text-gold">
                new migration: {e.newMigrations.join(", ")}
              </p>
            ) : null}
            {e.newFiles.length > 0 ? (
              <p className="mt-1.5 text-[0.8125rem] leading-relaxed">
                <span className="type-label text-teal">new files</span>{" "}
                <span className="font-mono text-[0.75rem] text-muted">
                  {e.newFiles.join("  ")}
                </span>
              </p>
            ) : null}
            {e.removedFiles.length > 0 ? (
              <p className="mt-1 text-[0.8125rem]">
                <span className="type-label text-coral">deleted</span>{" "}
                <span className="font-mono text-[0.75rem] text-muted">
                  {e.removedFiles.join("  ")}
                </span>
              </p>
            ) : null}
            {e.depsAdded.length > 0 || e.depsRemoved.length > 0 ? (
              <p className="mt-1 text-[0.8125rem]">
                <span className="type-label text-gold">dependencies</span>{" "}
                <span className="type-num text-[0.75rem] text-muted">
                  {e.depsAdded.map((d) => `+${d}`).join(" ")}{" "}
                  {e.depsRemoved.map((d) => `-${d}`).join(" ")}
                </span>
              </p>
            ) : null}
            {e.routeHandlers.length > 0 ? (
              <p className="type-num mt-1 text-[0.75rem] text-muted">
                routes: {e.routeHandlers.join(", ")}
              </p>
            ) : null}
            {e.sqlFunctions.length > 0 ? (
              <p className="type-num mt-1 text-[0.75rem] text-muted">
                sql functions: {e.sqlFunctions.join(", ")}
              </p>
            ) : null}

            <div className="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-[0.75rem] text-muted">
              {CATS.filter((c) => e.categories[c]?.length).map((c) => (
                <span key={c} title={e.categories[c]!.map((f) => f.path).join("\n")}>
                  {CATEGORY_LABEL[c]} &middot; {e.categories[c]!.length}
                </span>
              ))}
              <span className="type-num">
                +{e.additions} &minus;{e.deletions}
              </span>
            </div>
          </li>
        ))}
      </ul>

      {/* in-app admin actions, already logged server-side */}
      <h3 className="type-display mt-9 text-[0.9375rem]">Admin actions</h3>
      <ul className="mt-2 flex flex-col">
        {audit.length === 0 ? (
          <li className="type-label border-b py-3 text-muted rule">nothing recorded yet</li>
        ) : null}
        {audit.map((a) => (
          <li key={a.id} className="flex flex-wrap items-baseline gap-x-3 border-b py-2.5 rule">
            <span className="type-label text-gold">{a.action}</span>
            <span className="min-w-0 flex-1 truncate text-[0.8125rem] text-muted">
              {a.detail ?? a.target ?? ""}
            </span>
            <span className="type-label shrink-0 text-muted">{a.actor ?? "system"}</span>
            <span className="type-label shrink-0 text-muted">{ago(a.at)}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}
