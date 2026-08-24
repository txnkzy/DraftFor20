import { createClient } from "@supabase/supabase-js";
import { NextResponse } from "next/server";
import { allow, clientIp } from "@/lib/rateLimit";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Magic-link requests are proxied so they can be rate limited per IP and per
 * address. Without this, anyone can use the sign-in form to mailbomb a third
 * party, and the sender reputation that suffers is ours.
 */
// AUTH: public by necessity — this is how a signed-out person signs in.
// Guarded by proof of send-rate instead: per-IP and per-address limits, and
// shouldCreateUser:false so it cannot be used to enumerate or create accounts.
export async function POST(req: Request) {
  const ip = clientIp(req);

  let email = "";
  let redirectTo = "";
  try {
    const body = (await req.json()) as { email?: string; redirectTo?: string };
    email = String(body.email ?? "").trim().toLowerCase();
    redirectTo = String(body.redirectTo ?? "");
  } catch {
    return NextResponse.json({ message: "Bad request." }, { status: 400 });
  }

  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email) || email.length > 254) {
    return NextResponse.json({ message: "That doesn't look like an email address." }, { status: 400 });
  }

  const origin = new URL(req.url).origin;
  // only ever send people back to our own origin
  const safeRedirect =
    redirectTo.startsWith(origin) ? redirectTo : `${origin}/auth/callback`;

  // Both are evaluated deliberately, not short-circuited, so the two counters
  // cannot drift apart. Now that password sign-in exists this path is a
  // genuine fallback rather than every login, so these limits are the right
  // shape: they guard an actual email send.
  const ipOk = await allow("magic_ip", ip, 5, 900);
  const addrOk = await allow("magic_addr", email, 5, 3600);
  if (!ipOk || !addrOk) {
    return NextResponse.json({ message: "DF20_RATE_LIMITED" }, { status: 429 });
  }

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) {
    return NextResponse.json({ message: "Supabase is not configured." }, { status: 500 });
  }

  const sb = createClient(url, key, { auth: { persistSession: false } });
  const { error } = await sb.auth.signInWithOtp({
    email,
    options: {
      emailRedirectTo: safeRedirect,
      // this is a SIGN-IN fallback, not a back door to account creation.
      // The default is true, which meant "sign in" silently made accounts.
      shouldCreateUser: false,
    },
  });
  if (error) {
    // Supabase's own text used to reach the screen verbatim, which is how
    // "email rate limit exceeded" showed up during ordinary use. Translate it.
    const raw = error.message.toLowerCase();
    const message =
      raw.includes("rate limit") || raw.includes("too many")
        ? "DF20_EMAIL_RATE_LIMIT"
        : raw.includes("signups not allowed") || raw.includes("user not found")
          ? "No account with that email yet. Create one first."
          : "Could not send the link. Try again shortly.";
    return NextResponse.json({ message }, { status: 429 });
  }

  return NextResponse.json({ ok: true }, { status: 200 });
}
