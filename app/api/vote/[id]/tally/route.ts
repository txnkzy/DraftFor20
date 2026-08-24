import { createClient } from "@supabase/supabase-js";
import { NextResponse } from "next/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * The spectator tally, polled instead of pushed.
 *
 * THE PROBLEM THIS SOLVES: the vote page used to open a realtime connection
 * per viewer. Players are bounded — two per room — but spectators are not, so
 * one popular link could consume more of the realtime budget than every live
 * game put together, during exactly the traffic spike this is meant to
 * survive. A number that moves every few seconds does not need a websocket;
 * the live bid war does, and keeps one.
 *
 * THE CACHE is what makes polling cheaper than pushing rather than just
 * differently expensive. The aggregate is memoised per room for a few seconds,
 * so a thousand spectators polling the same room cost ONE database query every
 * TALLY_TTL_MS, not a thousand. On serverless this cache is per instance, so
 * the real figure is one query per instance per window — still two or three
 * orders of magnitude below per-viewer connections, and it degrades towards
 * the uncached cost rather than falling over.
 *
 * THE BLIND RULE is enforced twice: the cookie says whether this browser has
 * voted, and get_audience_tally_for_voter refuses a key that has not. The
 * cookie is the fast path; the database is what makes the fast path safe to
 * trust, because a forged cookie still gets nothing from the RPC.
 */
const TALLY_TTL_MS = 3_000;
const MAX_CACHE_ENTRIES = 500;

interface Tally {
  total: number;
  by_player: Record<string, number>;
}

const cache = new Map<string, { at: number; tally: Tally }>();

function readCache(key: string): Tally | null {
  const hit = cache.get(key);
  if (!hit) return null;
  if (Date.now() - hit.at > TALLY_TTL_MS) {
    cache.delete(key);
    return null;
  }
  return hit.tally;
}

function writeCache(key: string, tally: Tally) {
  // a spike across many rooms must not grow this without bound
  if (cache.size >= MAX_CACHE_ENTRIES) {
    const oldest = [...cache.entries()].sort((a, b) => a[1].at - b[1].at)[0];
    if (oldest) cache.delete(oldest[0]);
  }
  cache.set(key, { at: Date.now(), tally });
}

function ref(raw: string): string {
  const v = (raw ?? "").trim();
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v)
    ? v.toLowerCase()
    : v.toUpperCase();
}

export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const room = ref(id);

  const cookie = req.headers.get("cookie") ?? "";
  const key = cookie.match(/(?:^|;\s*)df20_av=([A-Za-z0-9_-]{16,64})/)?.[1];
  if (!key) {
    // no voter cookie at all: this browser has certainly not voted
    return NextResponse.json({ status: "not_voted" }, { headers: { "Cache-Control": "no-store" } });
  }

  const cached = readCache(room);
  if (cached) {
    return NextResponse.json(
      { status: "open", tally: cached, cached: true },
      { headers: { "Cache-Control": "no-store" } },
    );
  }

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !anon) {
    return NextResponse.json({ status: "gone" }, { status: 200 });
  }

  const sb = createClient(url, anon, { auth: { persistSession: false } });
  const { data, error } = await sb.rpc("get_audience_tally_for_voter", {
    p_code: room,
    p_voter_key: key,
  });
  if (error) {
    return NextResponse.json({ status: "gone" }, { headers: { "Cache-Control": "no-store" } });
  }

  const d = (data ?? {}) as { status?: string; tally?: Tally };
  if (d.status === "open" && d.tally) writeCache(room, d.tally);

  return NextResponse.json(
    { status: d.status ?? "gone", tally: d.tally ?? null },
    { headers: { "Cache-Control": "no-store" } },
  );
}
