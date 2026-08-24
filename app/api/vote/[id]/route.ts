import { createClient } from "@supabase/supabase-js";
import { NextResponse } from "next/server";
import { randomUUID } from "node:crypto";
import { allow, clientIp } from "@/lib/rateLimit";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * The audience vote, behind a server-set cookie.
 *
 * ONE VOTE PER BROWSER SESSION PER ROOM, and the browser does not get a say
 * in which browser it is: the key lives in an httpOnly cookie this route
 * issues, so a second tab, a refresh and a devtools poke all present the same
 * key. The database holds the actual constraint — primary key (room_id,
 * voter_key) — and this only decides what key is presented.
 *
 * Clearing cookies still gets you a second vote. That is what the per-IP
 * limit underneath is for. Neither is airtight and neither pretends to be;
 * together they cost more than a refresh, which is the bar this has to clear.
 */
// AUTH: public by design — the audience vote is the acquisition loop, so
// requiring an account here would defeat the point. Identity is a capability
// instead: an httpOnly cookie this route issues, with the real constraint as
// a primary key (room_id, voter_key) in Postgres.
const COOKIE = "df20_av";
const YEAR = 60 * 60 * 24 * 365;

/** the URL carries either a room code or a room uuid; the RPC takes both */
function ref(raw: string): string {
  const v = (raw ?? "").trim();
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v)
    ? v.toLowerCase()
    : v.toUpperCase();
}

function sb() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) return null;
  return createClient(url, key, { auth: { persistSession: false } });
}

function readKey(req: Request): { key: string; fresh: boolean } {
  const raw = req.headers.get("cookie") ?? "";
  const hit = raw.match(/(?:^|;\s*)df20_av=([A-Za-z0-9_-]{16,64})/);
  if (hit) return { key: hit[1], fresh: false };
  return { key: `av_${randomUUID().replace(/-/g, "")}`, fresh: true };
}

function withCookie(res: NextResponse, key: string, fresh: boolean) {
  if (!fresh) return res;
  res.cookies.set(COOKIE, key, {
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    path: "/",
    maxAge: YEAR,
  });
  return res;
}

export async function GET(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const client = sb();
  if (!client) return NextResponse.json({ status: "unconfigured" }, { status: 200 });

  const { key, fresh } = readKey(req);
  const { data, error } = await client.rpc("get_audience_state", {
    p_code: ref(id),
    p_voter_key: key,
  });
  if (error) return NextResponse.json({ status: "gone" }, { status: 200 });
  return withCookie(NextResponse.json(data ?? { status: "gone" }), key, fresh);
}

export async function POST(req: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const client = sb();
  if (!client) return NextResponse.json({ message: "Not configured." }, { status: 503 });

  let winner = "";
  try {
    const body = (await req.json()) as { winnerPlayerId?: string };
    winner = String(body.winnerPlayerId ?? "");
  } catch {
    return NextResponse.json({ message: "Bad request." }, { status: 400 });
  }
  if (!/^[0-9a-f-]{36}$/i.test(winner)) {
    return NextResponse.json({ message: "Bad request." }, { status: 400 });
  }

  // a shared network should not be able to bury a room in votes
  if (!(await allow("aud_vote_ip", `${clientIp(req)}:${ref(id)}`, 10, 3600))) {
    return NextResponse.json({ message: "DF20_RATE_LIMITED" }, { status: 429 });
  }

  const { key, fresh } = readKey(req);
  const { data, error } = await client.rpc("cast_audience_vote", {
    p_code: ref(id),
    p_voter_key: key,
    p_winner_player_id: winner,
  });
  if (error) return NextResponse.json({ message: error.message }, { status: 400 });
  return withCookie(NextResponse.json(data), key, fresh);
}
