import { NextResponse } from "next/server";
import { allow, clientIp } from "@/lib/rateLimit";
import { verifyPow } from "@/lib/pow";
import { anonClient, optionalUser, unconfigured } from "@/lib/api/auth";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Room creation goes through here rather than straight to the RPC so it can be
 * rate limited and gated behind a proof of work. The RPC itself still does all
 * the real validation; this only decides whether the caller gets to reach it.
 */
export async function POST(req: Request) {
  const ip = clientIp(req);

  let body: Record<string, unknown>;
  try {
    body = (await req.json()) as Record<string, unknown>;
  } catch {
    return NextResponse.json({ message: "Bad request." }, { status: 400 });
  }

  const challenge = typeof body.challenge === "string" ? body.challenge : "";
  const nonce = typeof body.nonce === "number" ? body.nonce : -1;
  if (!(await verifyPow(challenge, nonce))) {
    return NextResponse.json({ message: "DF20_BOT_CHECK_FAILED" }, { status: 400 });
  }

  // 8 rooms per IP per 10 minutes, and 40 per hour
  if (!(await allow("create_room_10m", ip, 8, 600))) {
    return NextResponse.json({ message: "DF20_RATE_LIMITED" }, { status: 429 });
  }
  if (!(await allow("create_room_1h", ip, 40, 3600))) {
    return NextResponse.json({ message: "DF20_RATE_LIMITED" }, { status: 429 });
  }

  const num = (v: unknown, fallback: number) =>
    typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : fallback;

  // DELIBERATELY optional. Anonymous play is the product: two people open a
  // room with a code and neither needs an account. A signed-in host talks to
  // PostgREST as themselves so auth.uid() resolves and create_room can
  // attribute the room to their profile; everyone else gets the free shelf.
  // The RPC decides what each of those is allowed to ask for.
  const auth = await optionalUser(req);
  const sb = auth?.sb ?? anonClient();
  if (!sb) return unconfigured();
  const { data, error } = await sb.rpc("create_room", {
    p_title: typeof body.title === "string" ? body.title : "Football Draft",
    p_roster_size: num(body.rosterSize, 5),
    p_bankroll_cents: num(body.bankrollCents, 2000),
    p_min_bid_cents: num(body.minBidCents, 100),
    p_timer_seconds: num(body.timerSeconds, 15),
    p_host_name: typeof body.hostName === "string" ? body.hostName : "",
    p_is_private: body.isPrivate !== false,
    p_gives_per_player: num(body.givesPerPlayer, 2),
    p_brand_accent: typeof body.brandAccent === "string" && body.brandAccent ? body.brandAccent : null,
    p_brand_logo_url: typeof body.brandLogoUrl === "string" && body.brandLogoUrl ? body.brandLogoUrl : null,
    // provenance only: an id the server resolves itself. The client never
    // holds, sends or receives the item list.
    p_pool_source: typeof body.poolSource === "string" ? body.poolSource : "builtin",
    p_pool_ref: typeof body.poolRef === "string" ? body.poolRef : null,
    // standard unless the caller asks for creator AND the RPC agrees they
    // have premium; this route does not get a say in that
    p_content_mode: body.contentMode === "creator" ? "creator" : "standard",
    // defaults to true when absent, matching how the trend is actually played
    p_allow_broke: body.allowBroke !== false,
  });

  if (error) return NextResponse.json({ message: error.message }, { status: 400 });
  return NextResponse.json(data, { status: 200 });
}
