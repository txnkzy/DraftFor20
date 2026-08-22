import { createClient } from "@supabase/supabase-js";
import { NextResponse } from "next/server";
import { allow } from "@/lib/rateLimit";
import { runLookupChain, type LibraryHit } from "@/lib/category/chain";
import { fetchWikidataCategory } from "@/lib/wikidata";
import { fetchCategory, rankByPageviews } from "@/lib/wikipedia";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Resolve a typed category name to a playable pool.
 *
 *   1 library / cache   2 Wikidata by sitelinks   3 Wikipedia by pageviews   4 nothing
 *
 * The response carries provenance and a COUNT. It never carries an item, from
 * any of the four sources. That is the whole point of doing this server-side.
 *
 * ONE lookup spends ONE unit of rate-limit budget. Steps 2 and 3 are two
 * halves of a single search as far as the person typing is concerned, and a
 * search that tried four Wikidata candidates and four pageview batches made
 * nine HTTP calls — charging any of that per-call would let one search empty
 * an hourly allowance.
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
  // both rosters, plus enough spare that the shuffled deck is not the whole
  // list in a slightly different order
  const keep = Math.min(Math.max(minItems * 4, 40), 120);

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
  const uid = who.user.id;

  let popularityFiltered: boolean | undefined;

  const outcome = await runLookupChain({
    libraryMatch: async () => {
      const { data } = await sb.rpc("df20_match_category", {
        p_query: query,
        p_min_items: minItems,
      });
      return (data as LibraryHit | null) ?? null;
    },

    // the one and only charge, keyed to the account rather than a shared IP
    spendBudget: () => allow("category_lookup", uid, 10, 3600),

    wikidata: async () => {
      const found = await fetchWikidataCategory(query, minItems, keep);
      return found ? { title: found.title, items: found.items, entityId: found.entityId } : null;
    },

    wikipedia: async () => {
      const found = await fetchCategory(query, minItems);
      if (!found) return null;
      const ranked = await rankByPageviews(found.items, keep);
      popularityFiltered = ranked.filtered;
      return { title: found.title, items: ranked.items, popularityFiltered: ranked.filtered };
    },
  });

  if (outcome.kind === "rate_limited") {
    return NextResponse.json({ message: "DF20_RATE_LIMITED" }, { status: 429 });
  }

  if (outcome.kind === "hit") {
    const h = outcome.hit;
    return NextResponse.json({
      source: h.source,
      sourceId: h.source_id,
      matchedName: h.name,
      itemCount: h.item_count,
      score: h.score,
    });
  }

  if (outcome.kind === "none") {
    return NextResponse.json({ source: null, message: "DF20_NO_MATCH" }, { status: 200 });
  }

  // public structured data either way, cached with no opt-in so the next room
  // asking for the same thing costs Wikimedia nothing
  const { list, from } = outcome;
  const { data: cached, error } = await sb.rpc("df20_cache_wikipedia", {
    p_secret: process.env.WIKI_WRITE_SECRET ?? "",
    p_query: query,
    p_title: list.title,
    p_items: list.items,
    p_source: from,
    p_entity_id: list.entityId ?? null,
  });
  if (error) {
    return NextResponse.json({ message: "Could not store that category." }, { status: 500 });
  }

  // a fallback-of-a-fallback nobody can see is one nobody ever fixes
  if (from === "wikipedia" && popularityFiltered === false) {
    console.warn(
      `[category] pageview ranking unavailable for "${query}" — served the parsed list capped at ${keep}`,
    );
  }

  const c = cached as { source_id: string; item_count: number };
  return NextResponse.json({
    source: from,
    sourceId: c.source_id,
    matchedName: list.title,
    itemCount: c.item_count,
    popularityFiltered: from === "wikidata" ? true : popularityFiltered,
  });
}
