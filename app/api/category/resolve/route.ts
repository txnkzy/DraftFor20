import { NextResponse } from "next/server";
import { allow } from "@/lib/rateLimit";
import { fetchCategory } from "@/lib/wikipedia";
import { resolveImages } from "@/lib/images/resolve";
import { requireUser } from "@/lib/api/auth";

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

  // Typing your own category is the gated path. Verified here rather than
  // trusted from the UI, because this route is reachable with curl.
  const auth = await requireUser(req);
  if (auth instanceof NextResponse) return auth;
  const sb = auth.sb;

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
  if (!(await allow("wiki_lookup", auth.user.id, 10, 3600))) {
    return NextResponse.json({ message: "DF20_RATE_LIMITED" }, { status: 429 });
  }

  const found = await fetchCategory(query, minItems);
  if (!found) {
    return NextResponse.json({ source: null, message: "DF20_NO_MATCH" }, { status: 200 });
  }

  // Pictures are resolved HERE, once, and cached with the names — not per
  // room. A category costs this round-trip the first time anybody drafts it
  // and nothing on every draft after, which is what keeps it off the path
  // between two players waiting in a lobby.
  //
  // A failure is not fatal: resolveImages already degrades item by item, and
  // if the whole call throws, the category is still perfectly playable with
  // no pictures at all.
  let images: (string | null)[] = [];
  let licenses: (string | null)[] = [];
  try {
    const resolved = await resolveImages(found.items);
    // a generated card is not stored — a null URL tells the client to draw
    // one from the item name, which costs nothing and cannot go stale
    images = resolved.map((r) => (r.source === "generated" ? null : r.url));
    licenses = resolved.map((r) => (r.source === "generated" ? null : r.license));
  } catch {
    images = [];
    licenses = [];
  }

  // public encyclopedia content, cached with no opt-in so the next room asking
  // for the same thing costs Wikipedia nothing
  const secret = process.env.WIKI_WRITE_SECRET ?? "";
  const { data: cached, error } = await sb.rpc("df20_cache_wikipedia", {
    p_secret: secret,
    p_query: query,
    p_title: found.title,
    p_items: found.items.map((i) => i.name),
    // positional against p_items; the RPC pairs them by index
    p_images: images,
    p_licenses: licenses,
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
