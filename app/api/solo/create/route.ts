import { createClient } from "@supabase/supabase-js";
import { NextResponse } from "next/server";
import { randomUUID } from "node:crypto";
import { allow, clientIp } from "@/lib/rateLimit";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// AUTH: public by design — Quick Play needs no account. Same shape as
// /api/rooms: the RPC does the real validation, this decides who reaches it.
//
// SOLO ROOMS ARE CREATED HERE RATHER THAN BY A DIRECT RPC CALL, because the
// daily cap keys on a device key and a key the CLIENT chooses whether to send
// is not a cap at all — omitting it read as "first-time player, allow". The
// cookie is read and stamped here, server-side, so the key is not optional.
// A caller hitting create_solo_room directly still gets counted when they
// present a cookie, and is caught by the per-IP backstop below when they
// do not.
const COOKIE = "df20_sk";
const YEAR = 60 * 60 * 24 * 365;

export async function POST(req: Request) {
  let body: Record<string, unknown>;
  try {
    body = (await req.json()) as Record<string, unknown>;
  } catch {
    return NextResponse.json({ message: "Bad request." }, { status: 400 });
  }

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) {
    return NextResponse.json({ message: "Supabase is not configured." }, { status: 500 });
  }

  // the device key: whatever cookie they already hold, or a fresh one we set
  const raw = req.headers.get("cookie") ?? "";
  const hit = raw.match(/(?:^|;\s*)df20_sk=([A-Za-z0-9_-]{16,64})/);
  const deviceKey = hit ? hit[1] : `sk_${randomUUID().replace(/-/g, "")}`;
  const fresh = !hit;

  // Backstop for a caller with no cookie at all — a fresh key every request
  // would otherwise be unlimited games. Deliberately loose: a shared network
  // is a real thing and this is a soft gate, not a paywall.
  if (!(await allow("solo_ip", clientIp(req), 12, 86400))) {
    return NextResponse.json({ message: "DF20_SOLO_LIMIT" }, { status: 429 });
  }

  // signed in? pass the token so auth.uid() resolves and the cap keys on the
  // account instead, which clearing a cookie cannot dodge
  const token = req.headers.get("authorization")?.replace(/^Bearer /i, "") ?? "";
  const sb = createClient(url, key, {
    auth: { persistSession: false },
    ...(token ? { global: { headers: { Authorization: `Bearer ${token}` } } } : {}),
  });

  const num = (v: unknown, d: number) =>
    typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : d;

  const { data, error } = await sb.rpc("create_solo_room", {
    p_host_name: typeof body.hostName === "string" ? body.hostName : "",
    p_pool_source: typeof body.poolSource === "string" ? body.poolSource : "builtin",
    p_pool_ref: typeof body.poolRef === "string" ? body.poolRef : null,
    p_roster_size: num(body.rosterSize, 5),
    p_timer_seconds: num(body.timerSeconds, 20),
    p_device_key: deviceKey,
  });

  const res = error
    ? NextResponse.json({ message: error.message }, { status: 400 })
    : NextResponse.json(data, { status: 200 });

  if (fresh) {
    res.cookies.set(COOKIE, deviceKey, {
      httpOnly: true,
      sameSite: "lax",
      secure: process.env.NODE_ENV === "production",
      path: "/",
      maxAge: YEAR,
    });
  }
  return res;
}
