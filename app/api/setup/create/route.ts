import { NextResponse } from "next/server";
import { requireUser } from "@/lib/api/auth";

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
  // requireUser hands back a client already speaking to PostgREST AS THE
  // USER, which is what makes auth.uid() resolve inside the RPC
  const auth = await requireUser(req);
  if (auth instanceof NextResponse) return auth;
  const sb = auth.sb;

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
