import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";
import { fetchCategory } from "@/lib/wikipedia";
import { resolveImages } from "@/lib/images/resolve";

interface Row {
  name: string;
  image_url: string | null;
  image_license: "free" | "nonfree" | null;
}

/**
 * A category that is already SEEDED, read back as it actually sits in
 * Postgres — not re-resolved.
 *
 * This has to come before the Wikipedia path or the preview lies. Typing
 * "one piece" resolves on Wikipedia to "List of One Piece characters", whose
 * entries mostly redirect to group articles, so the cascade hands Jinbe the
 * Straw Hats line-up and Shanks the Four Emperors. 0044 seeded that category
 * from MyAnimeList precisely to avoid that, and a preview showing the version
 * we rejected is worse than showing nothing.
 *
 * Returns null when nothing is seeded under that name, and the caller falls
 * through to the live cascade — which is the correct preview for a category
 * no one has curated.
 */
async function seeded(query: string, freeOnly: boolean) {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  const secret = process.env.DF20_DEV_SECRET;
  if (!url || !key || !secret) return null;

  const sb = createClient(url, key, { auth: { persistSession: false } });
  const { data, error } = await sb.rpc("df20_library_items", {
    p_secret: secret,
    p_query: query,
  });
  if (error || !data) return null;

  const hit = data as { source: string; name: string; items: Row[] };
  if (!hit.items?.length) return null;

  return {
    query,
    article: hit.name,
    freeOnly,
    seeded: hit.source,
    items: hit.items.map((r) => {
      // freeOnly has to apply here too. These rows are stored fair-use art,
      // so the toggle that drops non-free images from the live cascade must
      // drop them from a seeded category as well — otherwise the switch
      // silently means "except the curated ones", which is not a policy.
      const drop = freeOnly && r.image_license === "nonfree";
      const url = drop ? null : r.image_url;
      return {
        name: r.name,
        url,
        // a seeded row never went through the cascade, so name it honestly
        // rather than claiming a tier it did not come from
        source: url ? `seeded:${hit.source}` : "generated",
        license: url ? r.image_license ?? "generated" : "generated",
      };
    }),
  };
}

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * DEV ONLY. Resolves a category and returns the whole deck with pictures, so
 * /dev/cards can browse categories without a CLI round-trip.
 *
 * Hard-guarded on NODE_ENV rather than left to a deploy-time deletion: this
 * route runs unauthenticated Wikipedia fetches and returns ITEMS, which is
 * exactly what the real category route refuses to do. It must never answer in
 * production even if the file ships by mistake.
 */
/**
 * Module-scope memo. A resolve is ~1.5-2s of Wikipedia and Wikidata traffic,
 * and browsing means hitting the same handful of categories repeatedly — so
 * without this the browser re-pays full price to go back to a category it
 * showed a moment ago. Survives for the life of the dev server, which is the
 * right lifetime for encyclopedia content that changes on a scale of days.
 *
 * In-flight requests are memoised too, not just finished ones: two clicks in
 * quick succession would otherwise start two identical resolves.
 */
const cache = new Map<string, Promise<unknown>>();

export async function GET(req: Request) {
  if (process.env.NODE_ENV !== "development") {
    return new NextResponse("Not found", { status: 404 });
  }

  const url = new URL(req.url);
  const query = (url.searchParams.get("q") ?? "").trim().slice(0, 80);
  const freeOnly = url.searchParams.get("free") === "1";
  if (query.length < 2) {
    return NextResponse.json({ message: "q is required" }, { status: 400 });
  }

  const key = `${freeOnly ? "free:" : "any:"}${query.toLowerCase()}`;
  let job = cache.get(key);
  if (!job) {
    job = (async () => {
      // seeded first: a curated category must preview as what a room will
      // actually deal, not as what Wikipedia would have given us
      const stored = await seeded(query, freeOnly);
      if (stored) return stored;

      const found = await fetchCategory(query, 8);
      if (!found) return null;
      const resolved = await resolveImages(found.items, { freeOnly });
      return {
        query,
        article: found.title,
        freeOnly,
        items: resolved.map((r) => ({
          name: r.name,
          url: r.source === "generated" ? null : r.url,
          source: r.source,
          license: r.license,
        })),
      };
    })();
    cache.set(key, job);
    // a failure must not be memoised, or the category is broken until restart
    job.catch(() => cache.delete(key));
  }

  const body = await job;
  if (!body) {
    cache.delete(key); // a miss is worth retrying; the article may appear later
    return NextResponse.json({ message: `No Wikipedia list matched "${query}".` }, { status: 404 });
  }
  return NextResponse.json(body);
}
