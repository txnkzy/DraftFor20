import { createClient } from "@supabase/supabase-js";
import { NextResponse } from "next/server";
import { recentCommits } from "@/lib/changelog/github";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Admin-only. The admin check is the database's, not this route's — same
 * df20_is_admin() every other admin surface uses, asked as the caller.
 */
export async function GET(req: Request) {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  const token = req.headers.get("authorization")?.replace(/^Bearer /i, "") ?? "";
  if (!url || !anon || !token) {
    return NextResponse.json({ message: "DF20_NOT_AUTHORISED" }, { status: 401 });
  }

  const sb = createClient(url, anon, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const { data: isAdmin } = await sb.rpc("df20_is_admin");
  if (isAdmin !== true) {
    return NextResponse.json({ message: "DF20_NOT_AUTHORISED" }, { status: 403 });
  }

  const { configured, entries, nextMigration } = await recentCommits();
  return NextResponse.json(
    { configured, entries, nextMigration },
    { headers: { "Cache-Control": "no-store" } },
  );
}
