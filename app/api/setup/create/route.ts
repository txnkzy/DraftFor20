import { createClient } from "@supabase/supabase-js";
import { NextResponse } from "next/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Mint a setup link.
 *
 * Goes through a route rather than a direct rpc so the caller's token is
 * passed EXPLICITLY and attached to the PostgREST request. Relying on
 * cookie-borne session transport is what made create_pending_room see
 * auth.uid() as null for people who were plainly signed in.
 */
export async function POST(req: Request) {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) {
    return NextResponse.json({ message: "Supabase is not configured." }, { status: 500 });
  }

  const token = req.headers.get("authorization")?.replace(/^Bearer /i, "") ?? "";
  if (!token) {
    return NextResponse.json({ message: "DF20_SIGNIN_REQUIRED" }, { status: 401 });
  }

  // this client speaks to PostgREST AS THE USER, so auth.uid() resolves
  const sb = createClient(url, key, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });

  const { data: who } = await sb.auth.getUser(token);
  if (!who?.user) {
    return NextResponse.json({ message: "DF20_SIGNIN_REQUIRED" }, { status: 401 });
  }

  // the host picks how their own room looks even when somebody else builds
  // the list; premium is checked inside the RPC, not here
  let contentMode = "standard";
  try {
    const body = (await req.json()) as { contentMode?: string };
    if (body?.contentMode === "creator") contentMode = "creator";
  } catch {
    /* no body is fine: standard */
  }

  const { data, error } = await sb.rpc("create_pending_room", { p_content_mode: contentMode });
  if (error) return NextResponse.json({ message: error.message }, { status: 400 });
  return NextResponse.json(data, { status: 200 });
}
