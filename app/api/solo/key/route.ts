import { NextResponse } from "next/server";
import { randomUUID } from "node:crypto";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// AUTH: public by design — it issues an anonymous device key and nothing more.
//
// The key is stamped by the SERVER into an httpOnly cookie, exactly like the
// audience vote's df20_av, so a second tab, a refresh and a devtools poke all
// present the same one. Clearing cookies still gets you three more games. That
// is a known limit, not an oversight: 97% of traffic is anonymous and Quick
// Play exists to rescue the ~1 room in 4 that never finds a second player, so
// a harder gate would cost more than it earns. Signing in keys the cap on the
// account instead, which cookie-clearing cannot dodge.
const COOKIE = "df20_sk";
const YEAR = 60 * 60 * 24 * 365;

export async function GET(req: Request) {
  const raw = req.headers.get("cookie") ?? "";
  const hit = raw.match(/(?:^|;\s*)df20_sk=([A-Za-z0-9_-]{16,64})/);
  if (hit) return NextResponse.json({ key: hit[1] });

  const key = `sk_${randomUUID().replace(/-/g, "")}`;
  const res = NextResponse.json({ key });
  res.cookies.set(COOKIE, key, {
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    path: "/",
    maxAge: YEAR,
  });
  return res;
}
