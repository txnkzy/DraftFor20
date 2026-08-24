import { describe, expect, it } from "vitest";
import { buildEntry, categorise, dependencyDelta, structuralNames } from "./categorize";

describe("path categorisation", () => {
  it("maps the real tree", () => {
    expect(categorise("supabase/migrations/0040_x.sql")).toBe("database");
    expect(categorise("supabase/tests/v11.sql")).toBe("database");
    expect(categorise("app/api/vote/[id]/route.ts")).toBe("api");
    expect(categorise("components/admin/TrustSignals.tsx")).toBe("ui");
    expect(categorise("app/pricing/page.tsx")).toBe("ui");
    expect(categorise("app/globals.css")).toBe("ui");
    expect(categorise("lib/game/useRoom.ts")).toBe("logic");
    expect(categorise("package.json")).toBe("dependency");
    expect(categorise("next.config.ts")).toBe("config");
    expect(categorise(".env.example")).toBe("config");
    expect(categorise("CLAUDE.md")).toBe("docs");
  });

  it("puts api routes in api, not ui, despite living under app/", () => {
    expect(categorise("app/api/billing/webhook/route.ts")).toBe("api");
  });
});

describe("dependency delta", () => {
  it("reads adds and removes straight off the patch", () => {
    const patch = ['   "dependencies": {', '+    "recharts": "^3.10.1",', '-    "moment": "^2.29.0",', '     "next": "16.3.1"'].join("\n");
    expect(dependencyDelta(patch)).toEqual({ added: ["recharts@^3.10.1"], removed: ["moment@^2.29.0"] });
  });

  it("reports a version bump as neither an add nor a remove", () => {
    const patch = ['-    "next": "16.3.0",', '+    "next": "16.3.1",'].join("\n");
    expect(dependencyDelta(patch)).toEqual({ added: [], removed: [] });
  });

  it("ignores the top-level string fields that share the shape", () => {
    const patch = ['-  "version": "0.1.0",', '+  "version": "0.2.0",'].join("\n");
    expect(dependencyDelta(patch).added).toEqual([]);
  });
});

describe("structural names", () => {
  it("finds added route handlers and sql functions, and nothing else", () => {
    const r = structuralNames([
      { path: "app/api/vote/[id]/tally/route.ts", status: "added", additions: 1, deletions: 0,
        patch: "+export async function GET(req: Request) {\n+const x = 1;" },
      { path: "supabase/migrations/0040_x.sql", status: "added", additions: 1, deletions: 0,
        patch: "+create or replace function public.admin_user_signals(\n+  p_query text" },
      { path: "lib/game/view.ts", status: "modified", additions: 1, deletions: 0,
        patch: "+export function notAHandler() {}" },
    ]);
    expect(r.routeHandlers).toEqual(["GET /api/vote/[id]/tally"]);
    expect(r.sqlFunctions).toEqual(["admin_user_signals"]);
  });
});

describe("the entry", () => {
  it("surfaces new migrations by filename — the collision that matters", () => {
    const e = buildEntry(
      { sha: "abc1234567", url: "u", author: "logan", at: "2026-01-01", subject: "x" },
      [
        { path: "supabase/migrations/0041_new.sql", status: "added", additions: 40, deletions: 0 },
        { path: "components/x.tsx", status: "modified", additions: 3, deletions: 1 },
      ],
    );
    expect(e.newMigrations).toEqual(["0041_new.sql"]);
    expect(e.newFiles).toContain("supabase/migrations/0041_new.sql");
    expect(e.additions).toBe(43);
    expect(e.shortSha).toBe("abc1234");
  });
});
