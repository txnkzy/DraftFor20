import { createClient } from "@supabase/supabase-js";
import { NextResponse } from "next/server";
import { allow, clientIp } from "@/lib/rateLimit";
import { verifyTurnstile } from "@/lib/turnstile";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Signup, moved server-side so the Turnstile token can actually gate account
 * creation and the request's own signals can be recorded.
 *
 * ON THE PASSWORD: it now passes through this route on its way to Supabase
 * Auth, where it previously went from the browser straight there. It is
 * forwarded and nothing else — never logged, never stored, never written to
 * the database, and not held beyond the call. Supabase still does the
 * hashing; this code has no opinion about the value. The change is the price
 * of verifying Turnstile BEFORE an account exists, which is the whole point
 * of doing it at all — a check that runs after the account is created is not
 * prevention, it is bookkeeping.
 */
export async function POST(req: Request) {
  const ip = clientIp(req);

  let email = "";
  let password = "";
  let next = "/";
  let token: string | null = null;
  try {
    const body = (await req.json()) as Record<string, unknown>;
    email = typeof body.email === "string" ? body.email.trim() : "";
    password = typeof body.password === "string" ? body.password : "";
    if (typeof body.next === "string" && /^\/[^/\\]/.test(body.next)) next = body.next;
    token = typeof body.turnstileToken === "string" ? body.turnstileToken : null;
  } catch {
    return NextResponse.json({ ok: false, message: "Bad request." }, { status: 400 });
  }
  if (!email || !password) {
    return NextResponse.json({ ok: false, message: "Email and password are required." }, { status: 400 });
  }

  // a scripted signup flood should not even reach Cloudflare, let alone Supabase
  if (!(await allow("signup_ip", ip, 10, 3600))) {
    return NextResponse.json({ ok: false, message: "DF20_RATE_LIMITED" }, { status: 429 });
  }

  const outcome = await verifyTurnstile(token, ip);
  if (outcome === "failed") {
    return NextResponse.json(
      { ok: false, message: "That didn't look like a human. Refresh and try again." },
      { status: 400 },
    );
  }

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !anon) {
    return NextResponse.json({ ok: false, message: "Supabase is not configured." }, { status: 500 });
  }
  const sb = createClient(url, anon, { auth: { persistSession: false } });

  const origin = req.headers.get("origin") ?? "";
  const { data, error } = await sb.auth.signUp({
    email,
    password,
    options: {
      emailRedirectTo: `${origin}/auth/callback?next=${encodeURIComponent(next)}`,
    },
  });

  if (error) {
    return NextResponse.json({ ok: false, message: error.message }, { status: 400 });
  }

  /* Supabase does not error on a duplicate address — it returns a lookalike
     user so nobody can probe which emails are registered. An EMPTY identities
     array is the tell. */
  if (data.user && (data.user.identities?.length ?? 0) === 0) {
    return NextResponse.json({ ok: false, alreadyRegistered: true }, { status: 200 });
  }

  // ── the signals, best effort ───────────────────────────────────────────
  // A failure to record evidence must never fail the signup itself.
  if (data.user?.id) {
    /* Best effort, but not SILENT. Swallowing this whole meant a missing
       WIKI_WRITE_SECRET, an unapplied 0038 and a foreign-key failure all
       looked identical from the outside — nothing recorded, no trace — and
       the console then reported the absence as "created before signals were
       recorded", which reads as reassurance rather than a broken pipeline.
       Still never fails the signup. */
    try {
      const { error: sigError } = await sb.rpc("df20_record_signup", {
        p_secret: process.env.WIKI_WRITE_SECRET ?? "",
        p_profile_id: data.user.id,
        p_ip: ip,
        p_user_agent: req.headers.get("user-agent") ?? "",
        p_referrer: req.headers.get("referer") ?? "",
        p_email: email,
        p_turnstile: outcome,
      });
      if (sigError) {
        console.error(
          "[signup] signals not recorded:",
          sigError.message,
          process.env.WIKI_WRITE_SECRET ? "" : "(WIKI_WRITE_SECRET is unset)",
        );
      }
    } catch (e) {
      console.error("[signup] signals not recorded:", e);
    }
  }

  return NextResponse.json({ ok: true, needsConfirmation: !data.session });
}
