/**
 * Deterministic diff categorisation. No AI, no summarising, no interpretation
 * of intent — every field here is read directly off the diff.
 *
 * Tuned for one question: "has the other person already done this?" That makes
 * NEW FILES and NEW MIGRATIONS the important output, not line counts. A file
 * that did not exist yesterday is the strongest possible evidence that
 * somebody has started on something.
 */

export type Category =
  | "database"
  | "api"
  | "ui"
  | "logic"
  | "dependency"
  | "config"
  | "docs"
  | "other";

export const CATEGORY_LABEL: Record<Category, string> = {
  database: "Database schema",
  api: "API route",
  ui: "UI",
  logic: "Logic",
  dependency: "Dependency",
  config: "Configuration",
  docs: "Docs",
  other: "Other",
};

/** Checked against the real tree; first match wins, so order matters. */
export function categorise(path: string): Category {
  if (path.startsWith("supabase/migrations/")) return "database";
  if (path.startsWith("supabase/")) return "database";
  if (path.startsWith("app/api/")) return "api";
  if (path === "package.json" || path === "package-lock.json") return "dependency";
  if (path.startsWith("components/")) return "ui";
  if (path.startsWith("app/") && /\.(tsx|css)$/.test(path)) return "ui";
  if (path.startsWith("lib/")) return "logic";
  if (/\.md$/.test(path)) return "docs";
  if (
    path.startsWith(".claude/") ||
    path.startsWith(".env") ||
    /^(next\.config|tsconfig|eslint\.config|postcss\.config|vercel)\./.test(path) ||
    /\.(json|ya?ml|sh)$/.test(path)
  ) {
    return "config";
  }
  return "other";
}

export interface ChangedFile {
  path: string;
  status: string; // added | modified | removed | renamed
  additions: number;
  deletions: number;
  patch?: string;
}

export interface CommitEntry {
  sha: string;
  shortSha: string;
  url: string;
  author: string;
  at: string;
  /** the commit subject, shown verbatim as metadata — never interpreted */
  subject: string;
  categories: Partial<Record<Category, ChangedFile[]>>;
  newFiles: string[];
  newMigrations: string[];
  removedFiles: string[];
  depsAdded: string[];
  depsRemoved: string[];
  routeHandlers: string[];
  sqlFunctions: string[];
  additions: number;
  deletions: number;
}

/** Dependencies, read straight out of the package.json patch. */
export function dependencyDelta(patch: string | undefined): {
  added: string[];
  removed: string[];
} {
  const added: string[] = [];
  const removed: string[] = [];
  if (!patch) return { added, removed };

  // a dependency line is rigid: "name": "version"
  const line = /^([+-])\s*"([^"]+)"\s*:\s*"([^"]+)"\s*,?\s*$/;
  for (const raw of patch.split("\n")) {
    const m = line.exec(raw);
    if (!m) continue;
    const [, sign, name, version] = m;
    // skip the handful of top-level string fields that share the shape
    if (["name", "version", "private", "description", "license", "main"].includes(name)) continue;
    (sign === "+" ? added : removed).push(`${name}@${version}`);
  }
  // a version bump shows as both; report it as neither add nor remove
  const bumped = new Set(
    added.map((a) => a.split("@")[0]).filter((n) => removed.some((r) => r.startsWith(`${n}@`))),
  );
  return {
    added: added.filter((a) => !bumped.has(a.split("@")[0])),
    removed: removed.filter((r) => !bumped.has(r.split("@")[0])),
  };
}

/**
 * Two structural shapes rigid enough to match safely. Anything looser — a
 * general export diff — needs a real parser, and a changelog that is
 * sometimes wrong is worse than one that is coarser.
 */
export function structuralNames(files: ChangedFile[]): {
  routeHandlers: string[];
  sqlFunctions: string[];
} {
  const routeHandlers = new Set<string>();
  const sqlFunctions = new Set<string>();

  for (const f of files) {
    if (!f.patch) continue;
    for (const raw of f.patch.split("\n")) {
      if (!raw.startsWith("+")) continue;
      const line = raw.slice(1);

      if (f.path.startsWith("app/api/")) {
        const m = /^export\s+async\s+function\s+(GET|POST|PUT|PATCH|DELETE|HEAD)\b/.exec(line);
        if (m) routeHandlers.add(`${m[1]} ${f.path.replace(/^app\/api\//, "/api/").replace(/\/route\.tsx?$/, "")}`);
      }

      if (f.path.startsWith("supabase/")) {
        const m = /create\s+or\s+replace\s+function\s+public\.(\w+)\s*\(/i.exec(line);
        if (m) sqlFunctions.add(m[1]);
      }
    }
  }
  return { routeHandlers: [...routeHandlers], sqlFunctions: [...sqlFunctions] };
}

export function buildEntry(
  meta: { sha: string; url: string; author: string; at: string; subject: string },
  files: ChangedFile[],
): CommitEntry {
  const categories: Partial<Record<Category, ChangedFile[]>> = {};
  for (const f of files) {
    const c = categorise(f.path);
    (categories[c] ??= []).push(f);
  }

  const pkg = files.find((f) => f.path === "package.json");
  const deps = dependencyDelta(pkg?.patch);
  const structural = structuralNames(files);

  return {
    sha: meta.sha,
    shortSha: meta.sha.slice(0, 7),
    url: meta.url,
    author: meta.author,
    at: meta.at,
    subject: meta.subject,
    categories,
    newFiles: files.filter((f) => f.status === "added").map((f) => f.path),
    newMigrations: files
      .filter((f) => f.status === "added" && f.path.startsWith("supabase/migrations/"))
      .map((f) => f.path.replace("supabase/migrations/", "")),
    removedFiles: files.filter((f) => f.status === "removed").map((f) => f.path),
    depsAdded: deps.added,
    depsRemoved: deps.removed,
    routeHandlers: structural.routeHandlers,
    sqlFunctions: structural.sqlFunctions,
    additions: files.reduce((t, f) => t + f.additions, 0),
    deletions: files.reduce((t, f) => t + f.deletions, 0),
  };
}
