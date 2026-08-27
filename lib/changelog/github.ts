import "server-only";
import { buildEntry, type ChangedFile, type CommitEntry } from "./categorize";

/**
 * Commits, fetched on demand rather than ingested.
 *
 * Two people checking "what has the other one been doing" do not need a
 * webhook, a secret, a commits table and a cron between them and an answer.
 * GitHub already stores this; copying it locally only creates something that
 * can drift. A short server-side cache keeps a page refresh from spending
 * rate limit.
 *
 * Optional, like every other integration here: no token, no commits, and the
 * page says so instead of breaking.
 */
const REPO = process.env.GITHUB_REPO || "txnkzy/DraftFor20";
const API = "https://api.github.com";
const CACHE_MS = 60_000;
const COMMITS = 25;

let cache: { at: number; entries: CommitEntry[]; nextMigration: string | null } | null = null;

export function githubConfigured(): boolean {
  return Boolean((process.env.GITHUB_TOKEN ?? "").trim());
}

type Headers = Record<string, string>;

function anonHeaders(): Headers {
  return {
    Accept: "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "DraftFor20-changelog",
  };
}

function headers(): Headers {
  return {
    Authorization: `Bearer ${(process.env.GITHUB_TOKEN ?? "").trim()}`,
    ...anonHeaders(),
  };
}

/**
 * The number to use next. This is the single most useful line on the page:
 * two people both reaching for 0041 is the collision that actually happens,
 * and it is a merge conflict in a file that must apply in order.
 */
async function nextMigrationNumber(h: Headers): Promise<string | null> {
  try {
    const res = await fetch(`${API}/repos/${REPO}/contents/supabase/migrations`, {
      headers: h,
      cache: "no-store",
    });
    if (!res.ok) return null;
    const files = (await res.json()) as { name: string }[];
    let top = -1;
    for (const f of files) {
      const m = /^(\d{4})_/.exec(f.name);
      if (m) top = Math.max(top, Number(m[1]));
    }
    return top < 0 ? null : String(top + 1).padStart(4, "0");
  } catch {
    return null;
  }
}

/**
 * Why the list came back empty, in words an admin can act on. A token that is
 * SET but rejected used to look exactly like a token that works and a
 * repository with no commits: the notice disappeared and nothing replaced it,
 * so the only visible result of fixing the environment variable was nothing
 * happening. Reporting the refusal is the difference between "it did not
 * work" and knowing which of four things to go and change.
 */
function refusal(code: number): string {
  if (code === 401) {
    return `GitHub rejected the token (401). GITHUB_TOKEN is wrong, revoked, or expired — fine-grained tokens expire on a date you set.`;
  }
  if (code === 403 || code === 429) {
    return `GitHub refused the request (${code}). Either the token cannot read ${REPO}, or the API rate limit is spent.`;
  }
  if (code === 404) {
    return `GitHub has no ${REPO} it will show this token (404). Check GITHUB_REPO, and that the token's resource owner can see the repository.`;
  }
  return `GitHub returned ${code}.`;
}

export async function recentCommits(): Promise<{
  configured: boolean;
  entries: CommitEntry[];
  nextMigration: string | null;
  problem: string | null;
}> {
  if (!githubConfigured()) {
    return { configured: false, entries: [], nextMigration: null, problem: null };
  }

  if (cache && Date.now() - cache.at < CACHE_MS) {
    return {
      configured: true,
      entries: cache.entries,
      nextMigration: cache.nextMigration,
      problem: null,
    };
  }

  try {
    /* This repository is PUBLIC — the same request succeeds with no
       credentials at all. So a token GitHub refuses should never leave the
       page emptier than having no token would: try again without it, and if
       that works, show the commits and say the token is being ignored. */
    const listUrl = `${API}/repos/${REPO}/commits?per_page=${COMMITS}`;
    let use: Headers = headers();
    let listRes = await fetch(listUrl, { headers: use, cache: "no-store" });
    let tokenRefused: string | null = null;

    if (!listRes.ok && (listRes.status === 401 || listRes.status === 403)) {
      const rejected = refusal(listRes.status);
      const anon = await fetch(listUrl, { headers: anonHeaders(), cache: "no-store" });
      if (anon.ok) {
        tokenRefused = `${rejected} These commits were read without it, which works because the repository is public — but that path is rate limited and shared, so it will not always be here.`;
        use = anonHeaders();
        listRes = anon;
      }
    }

    if (!listRes.ok) {
      return {
        configured: true,
        entries: [],
        nextMigration: null,
        problem: refusal(listRes.status),
      };
    }

    const list = (await listRes.json()) as {
      sha: string;
      html_url: string;
      commit: { message: string; author: { name?: string; date?: string } };
      author: { login?: string } | null;
    }[];

    // the list endpoint carries no file data, so each commit needs its own
    // call. Sequential and capped rather than parallel: this runs rarely and
    // being polite to the API matters more than being fast.
    const entries: CommitEntry[] = [];
    for (const c of list) {
      let files: ChangedFile[] = [];
      try {
        const one = await fetch(`${API}/repos/${REPO}/commits/${c.sha}`, {
          headers: use,
          cache: "no-store",
        });
        if (one.ok) {
          const d = (await one.json()) as {
            files?: { filename: string; status: string; additions: number; deletions: number; patch?: string }[];
          };
          files = (d.files ?? []).map((f) => ({
            path: f.filename,
            status: f.status,
            additions: f.additions,
            deletions: f.deletions,
            patch: f.patch,
          }));
        }
      } catch {
        /* a commit whose detail will not load still lists as metadata */
      }

      entries.push(
        buildEntry(
          {
            sha: c.sha,
            url: c.html_url,
            author: c.author?.login ?? c.commit.author?.name ?? "unknown",
            at: c.commit.author?.date ?? "",
            subject: (c.commit.message ?? "").split("\n")[0],
          },
          files,
        ),
      );
    }

    const nextMigration = await nextMigrationNumber(use);
    // failures are deliberately not cached, so fixing the token shows at once
    cache = { at: Date.now(), entries, nextMigration };
    return { configured: true, entries, nextMigration, problem: tokenRefused };
  } catch (e) {
    return {
      configured: true,
      entries: [],
      nextMigration: null,
      problem: `Could not reach the GitHub API: ${e instanceof Error ? e.message : String(e)}`,
    };
  }
}
