import { createClient } from "@supabase/supabase-js";
import { NextResponse } from "next/server";
import { decide, type BotTurn } from "@/lib/bot/decide";
import { allow } from "@/lib/rateLimit";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

// AUTH: public by design — a solo room has one human in it and the only thing
// this endpoint can do is make that room's bot take a turn that is already
// the bot's. bot_act refuses if it is not, and every move it dispatches is
// re-validated by the same RPCs a human goes through. There is no second
// player to defraud and nothing here reads private state. The rate limit
// below is about protecting the LLM budget, not the game.
export async function POST(req: Request) {
  let code = "";
  try {
    const body = (await req.json()) as { code?: string };
    code = String(body.code ?? "").trim().toUpperCase();
  } catch {
    return NextResponse.json({ message: "Bad request." }, { status: 400 });
  }
  if (!/^[A-Z0-9]{4,8}$/.test(code)) {
    return NextResponse.json({ message: "Bad request." }, { status: 400 });
  }

  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) {
    return NextResponse.json({ message: "Supabase is not configured." }, { status: 500 });
  }
  const sb = createClient(url, key, { auth: { persistSession: false } });

  const { data: turn, error: e1 } = await sb.rpc("df20_bot_turn", { p_code: code });
  if (e1) return NextResponse.json({ message: e1.message }, { status: 400 });

  const t = turn as BotTurn | null;
  // not the bot's turn is the normal case, not an error: the client polls
  if (!t?.turn) return NextResponse.json({ acted: false }, { status: 200 });

  // One LLM call per turn per room. Without this a client that retries in a
  // loop burns the whole day's free quota on a single draft — and the quota
  // is ~1,000 requests against ~665 rooms a day, so there is nothing to
  // spare. Exceeding it costs the LLM, never the move: the heuristic still
  // plays, so the draft is unaffected.
  const budget = await allow(`bot_llm:${code}`, String(t.turn_seq ?? 0), 1, 120);

  const choice = budget
    ? await decide(t)
    : {
        action: t.fallback.action,
        amount_cents: t.fallback.amount_cents,
        why: t.fallback.why,
        source: "heuristic" as const,
      };

  const { data, error: e2 } = await sb.rpc("bot_act", {
    p_code: code,
    p_choice: choice.action,
    p_amount_cents: choice.amount_cents ?? null,
  });

  if (e2) {
    // The move was refused — a stale turn_seq, or a model choice the money
    // rules will not have. Try the database's own suggestion before giving
    // up, so a bad LLM turn never costs the player a stalled draft.
    const { data: retry, error: e3 } = await sb.rpc("bot_act", {
      p_code: code,
      p_choice: t.fallback.action,
      p_amount_cents: t.fallback.amount_cents ?? null,
    });
    if (e3) return NextResponse.json({ acted: false, message: e3.message }, { status: 200 });
    return NextResponse.json(
      { acted: true, action: t.fallback.action, why: t.fallback.why,
        source: "heuristic", recovered: true, state: retry },
      { status: 200 },
    );
  }

  return NextResponse.json(
    { acted: true, action: choice.action, amount_cents: choice.amount_cents ?? null,
      why: choice.why, source: choice.source, state: data },
    { status: 200 },
  );
}
