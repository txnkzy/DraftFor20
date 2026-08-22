import { createClient } from "@supabase/supabase-js";
import { NextResponse } from "next/server";
import { allow } from "@/lib/rateLimit";
import { fetchCategory } from "@/lib/wikipedia";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Resolve a typed category name to a playable pool.
 *
 *   public library  ->  internal wikipedia cache  ->  fresh Wikipedia fetch
 *
 * The response carries provenance and a COUNT. It never carries an item, from
 * any of the three sources. That is the whole point of doing this server-side.
 */
export async function POST(req: Request) {
  let query = "";
  let rosterSize = 5;
  try {
    const body = (await req.json()) as { query?: string; rosterSize?: number };
    query = String(body.query ?? "").trim().slice(0, 80);
    if (typeof body.rosterSize === "number") rosterSize = Math.trunc(body.rosterSize);
  } catch {
    return NextResponse.json({ message: "Bad request." }, { status: 400 });
  }
  if (query.length < 2) {
    return NextResponse.json({ message: "Type a category name." }, { status: 400 });
  }
  if (rosterSize < 1 || rosterSize > 30) rosterSize = 5;
  const minItems = rosterSize * 2;

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) {
    return NextResponse.json({ message: "Supabase is not configured." }, { status: 500 });
  }
  const sb = createClient(url, key, { auth: { persistSession: false } });

  // Typing your own category is the premium path. Verified here rather than
  // trusted from the UI, because this route is reachable with curl.
  const bearer = req.headers.get("authorization")?.replace(/^Bearer /i, "") ?? "";
  const { data: who } = bearer ? await sb.auth.getUser(bearer) : { data: { user: null } };
  if (!who?.user) {
    return NextResponse.json({ message: "DF20_SIGNIN_REQUIRED" }, { status: 401 });
  }

  // library and cache hits are free; only the Wikipedia path is rationed
  const { data: hit } = await sb.rpc("df20_match_category", {
    p_query: query,
    p_min_items: minItems,
  });
  if (hit) {
    return NextResponse.json({
      source: hit.source,
      sourceId: hit.source_id,
      matchedName: hit.name,
      itemCount: hit.item_count,
      score: hit.score,
    });
  }

  // keyed to the account, not a shared IP
  if (!(await allow("wiki_lookup", who.user.id, 10, 3600))) {
    return NextResponse.json({ message: "DF20_RATE_LIMITED" }, { status: 429 });
  }

  const found = await fetchCategory(query, minItems);
  if (!found) {
    return NextResponse.json({ source: null, message: "DF20_NO_MATCH" }, { status: 200 });
  }

  // public encyclopedia content, cached with no opt-in so the next room asking
  // for the same thing costs Wikipedia nothing
  const secret = process.env.WIKI_WRITE_SECRET ?? "";
  const { data: cached, error } = await sb.rpc("df20_cache_wikipedia", {
    p_secret: secret,
    p_query: query,
    p_title: found.title,
    p_items: found.items,
  });
  if (error) {
    return NextResponse.json({ message: "Could not store that category." }, { status: 500 });
  }

  return NextResponse.json({
    source: "wikipedia",
    sourceId: cached.source_id,
    matchedName: cached.name,
    itemCount: cached.item_count,
  });
}
