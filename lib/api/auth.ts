import "server-only";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { NextResponse } from "next/server";

/**
 * ONE authentication gate for every route handler.
 *
 * Before this, five routes each hand-rolled
 *
 *     req.headers.get("authorization")?.replace(/^Bearer /i, "") ?? ""
 *
 * and then each decided for itself what to do about it. Four of them got it
 * right. That is not a bug report, it is an odds problem: the fifth route
 * anyone adds is the one that forgets, and nothing in the codebase would have
 * told them. So the parsing, the verification and the 401 all live here, and
 * a route's auth posture becomes one legible line at the top of the handler.
 *
 * WHAT THIS IS NOT: a replacement for the checks in Postgres. Every RPC still
 * re-authenticates from the token and re-validates its own preconditions,
 * because the anon key is public and PostgREST is reachable with curl whether
 * or not this file exists. This decides who gets to reach the RPC; the RPC
 * decides what they may do. Both, always — never one instead of the other.
 */

export interface AuthedUser {
  id: string;
  email: string | null;
}

export interface Authed {
  user: AuthedUser;
  /** the caller's own JWT, to be forwarded so auth.uid() resolves in Postgres */
  token: string;
  /** a client already acting AS the caller */
  sb: SupabaseClient;
}

/** Every 401 from every route says the same thing, so clients need one branch. */
export const SIGNIN_REQUIRED = "DF20_SIGNIN_REQUIRED";

export function bearer(req: Request): string {
  const raw = req.headers.get("authorization") ?? "";
  const m = /^Bearer\s+(.+)$/i.exec(raw.trim());
  return m ? m[1].trim() : "";
}

function env(): { url: string; key: string } | null {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  return url && key ? { url, key } : null;
}

/**
 * An anon-key client, optionally speaking as the caller.
 *
 * Passing the token matters: without it PostgREST sees the anon role and
 * auth.uid() is null inside the RPC, which is exactly the bug that made
 * create_pending_room refuse people who were plainly signed in.
 */
export function anonClient(token?: string): SupabaseClient | null {
  const e = env();
  if (!e) return null;
  return createClient(e.url, e.key, {
    auth: { persistSession: false },
    ...(token ? { global: { headers: { Authorization: `Bearer ${token}` } } } : {}),
  });
}

export function unauthorized(): NextResponse {
  return NextResponse.json({ message: SIGNIN_REQUIRED }, { status: 401 });
}

export function unconfigured(): NextResponse {
  return NextResponse.json({ message: "Supabase is not configured." }, { status: 500 });
}

/**
 * Require a signed-in caller. Returns either the caller or the response to
 * send back — never throws, so a handler reads:
 *
 *     const auth = await requireUser(req);
 *     if (auth instanceof NextResponse) return auth;
 *     // auth.user.id is now a verified identity
 *
 * The identity comes from Supabase verifying the JWT signature, never from
 * anything the request body claims about who it is.
 */
export async function requireUser(req: Request): Promise<Authed | NextResponse> {
  const token = bearer(req);
  if (!token) return unauthorized();

  const sb = anonClient(token);
  if (!sb) return unconfigured();

  const { data, error } = await sb.auth.getUser(token);
  if (error || !data?.user) return unauthorized();

  return {
    user: { id: data.user.id, email: data.user.email ?? null },
    token,
    sb,
  };
}

/**
 * Identify the caller if they are signed in, without requiring it.
 *
 * For routes that serve everyone but behave differently for an account —
 * room creation is the case: anonymous play is the product, but a signed-in
 * host gets their room attributed to their profile.
 */
export async function optionalUser(req: Request): Promise<Authed | null> {
  const token = bearer(req);
  if (!token) return null;
  const result = await requireUser(req);
  return result instanceof NextResponse ? null : result;
}
