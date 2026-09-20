import "server-only";

/**
 * Who the Quick Play opponent is, decision by decision.
 *
 * TWO DECIDERS, ONE SHAPE. An LLM picks the move when one answers; the
 * database's own df20_bot_heuristic picks it when one does not. They return
 * the same object, so the caller never branches on which ran.
 *
 * THE FALLBACK IS NOT A NICETY. The free tiers are ~1,000 requests a day
 * (Gemini Flash-Lite, Groq) against ~665 rooms a day and climbing, and a
 * draft is ~25 decisions. That budget is gone before lunch on day one. When
 * it goes, a draft with a running countdown cannot simply stop — so every
 * path here ends in a legal move, and the LLM is an enhancement rather than
 * a dependency. Nothing in this file is allowed to throw.
 *
 * WHAT THE MODEL IS NOT TRUSTED WITH: legality. Whatever comes back is
 * executed through bot_act -> offer_decide/place_bid/pass_turn, which
 * re-validate the hard cap, the reserve, turn_seq and Force-or-Take exactly
 * as they do for a human. A hallucinated $900 bid in a $20 room is rejected
 * by Postgres, not by this file.
 */

export type BotAction = "take" | "give" | "force" | "discard" | "bid" | "pass";

export interface BotChoice {
  action: BotAction;
  amount_cents?: number;
  why: string;
  /** which decider produced this, for the UI and for the logs */
  source: "llm" | "heuristic";
}

/** The slice of df20_bot_turn() the decider needs. */
export interface BotTurn {
  turn: boolean;
  /** optimistic-concurrency counter */
  turn_seq: number;
  /** the card being decided. The LLM budget is keyed on this, not turn_seq:
   *  "do I want this card" is asked once, and the raises after it are
   *  arithmetic the heuristic already does correctly. Cuts calls per draft
   *  from ~25 to ~10 without changing who decides the interesting part. */
  lot_id: string;
  phase: "offered" | "bidding";
  category: string | null;
  item: string;
  current_bid_cents: number;
  min_bid_cents: number;
  me: {
    name: string;
    bankroll_cents: number;
    open_slots: number;
    gives_left: number;
    max_legal_bid_cents: number;
    roster: { item: string; price_cents: number }[];
  };
  opponent: {
    name: string;
    bankroll_cents: number;
    open_slots: number;
    roster: { item: string; price_cents: number }[];
  };
  fallback: { action: BotAction; amount_cents?: number; why: string };
}

/**
 * The legal moves, worked out here rather than asked of the model. Giving it
 * a closed list is the difference between "choose one of these" and "guess
 * what the rules are", and it is what stops the obvious failure — a model
 * that has just read the phrase "give it away" offering a give when the
 * opponent's roster is full.
 */
function legalMoves(t: BotTurn): BotAction[] {
  if (t.phase === "bidding") {
    const next = t.current_bid_cents + t.min_bid_cents;
    return next <= t.me.max_legal_bid_cents ? ["bid", "pass"] : ["pass"];
  }
  const canTake =
    t.me.max_legal_bid_cents >= t.min_bid_cents && t.me.open_slots > 0;
  const moves: BotAction[] = [];
  if (canTake) moves.push("take");
  if (!canTake && t.me.open_slots > 0) moves.push("force");
  if (t.opponent.open_slots > 0 && t.me.gives_left > 0) moves.push("give");
  if (moves.length === 0) moves.push("discard");
  return moves;
}

/**
 * The prompt, written for tokens rather than for reading.
 *
 * The prose version cost ~206 input tokens a decision, ~5,200 a draft. This
 * one is ~80, because on a free tier the budget IS the product constraint:
 * Gemini Flash-Lite is 250k tokens/minute and 1,000 requests/day, and the
 * thing that runs out first should be requests, not tokens.
 *
 * WHAT WAS CUT AND WHY:
 *  * the rules. A model that needs "whatever you do not spend is your score"
 *    explained every turn is not the one making the difference; the closed
 *    list of legal moves already prevents anything illegal, and economics is
 *    what the heuristic is for.
 *  * roster history beyond the last three. It grows to eight entries by the
 *    end of a draft and adds tokens every turn to say something the bankroll
 *    already says.
 *  * long keys. "a"/"c"/"w" instead of action/amount_cents/why costs nothing
 *    in comprehension and saves output tokens on every single call.
 *  * dollars as integers. "$12.00" is three tokens; "1200c" is two.
 *
 * WHAT WAS KEPT: the card, both bankrolls, both slot counts, the recent
 * rosters and the legal moves. That is the whole decision.
 */
function prompt(t: BotTurn, legal: BotAction[]): string {
  // last three only: the tail is what a person would actually glance at
  const tail = (r: { item: string; price_cents: number }[]) =>
    r.length === 0
      ? "-"
      : r.slice(-3).map((e) => `${e.item} ${e.price_cents}`).join("; ");

  const line =
    t.phase === "bidding"
      ? `bid ${t.current_bid_cents} raise ${t.current_bid_cents + t.min_bid_cents} max ${t.me.max_legal_bid_cents}`
      : `open ${t.min_bid_cents} gives ${t.me.gives_left} max ${t.me.max_legal_bid_cents}`;

  return [
    `$20 auction draft, cents. Score = cash left. Empty slot = worse.`,
    `card: ${t.item}${t.category ? ` (${t.category})` : ""}`,
    `you ${t.me.bankroll_cents} slots ${t.me.open_slots} | them ${t.opponent.bankroll_cents} slots ${t.opponent.open_slots}`,
    `yours: ${tail(t.me.roster)}`,
    `theirs: ${tail(t.opponent.roster)}`,
    line,
    `pick one: ${legal.join("|")}`,
    `JSON only: {"a":"..."${legal.includes("bid") ? ',"c":<cents if bid>' : ""},"w":"<=8 words"}`,
  ].join("\n");
}

/** Pull the first JSON object out of whatever the model wrapped it in. */
function parseChoice(raw: string, legal: BotAction[], t: BotTurn): BotChoice | null {
  const m = raw.match(/\{[\s\S]*\}/);
  if (!m) return null;
  let obj: Record<string, unknown>;
  try {
    obj = JSON.parse(m[0]) as Record<string, unknown>;
  } catch {
    return null;
  }
  const action = String(obj.a ?? obj.action ?? "") as BotAction;
  if (!legal.includes(action)) return null;

  let amount: number | undefined;
  if (action === "bid") {
    amount = Math.trunc(Number(obj.c ?? obj.amount_cents));
    if (!Number.isFinite(amount)) return null;
    // clamp rather than reject: a model that says "raise" and fumbles the
    // arithmetic still meant to raise, and Postgres would refuse the number
    const floor = t.current_bid_cents + t.min_bid_cents;
    amount = Math.max(floor, Math.min(amount, t.me.max_legal_bid_cents));
  }
  const why = String(obj.w ?? obj.why ?? "").slice(0, 60) || "no reason given";
  return { action, amount_cents: amount, why, source: "llm" };
}

/* ── providers ────────────────────────────────────────────────────────────
   Two free tiers, tried in order, because neither is big enough on its own
   and both fail in the same way (429). Adding a third is one entry in this
   array. Rotating providers does NOT make the free tier sufficient — see the
   note at the top of this file — it just moves the wall.

   No SDKs: both are one POST with a JSON body, and a dependency per provider
   for that is not worth the install size or the supply-chain surface. */

interface Provider {
  name: string;
  key: () => string | undefined;
  call: (key: string, text: string, signal: AbortSignal) => Promise<string>;
}

const PROVIDERS: Provider[] = [
  {
    name: "gemini",
    key: () => process.env.GEMINI_API_KEY,
    async call(key, text, signal) {
      const model = process.env.GEMINI_MODEL || "gemini-2.5-flash-lite";
      const res = await fetch(
        `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`,
        {
          method: "POST",
          signal,
          headers: { "Content-Type": "application/json", "x-goog-api-key": key },
          body: JSON.stringify({
            contents: [{ parts: [{ text }] }],
            generationConfig: {
              temperature: 0.8,          // a predictable opponent is a boring one
              maxOutputTokens: 60,
              responseMimeType: "application/json",
            },
          }),
        },
      );
      if (!res.ok) throw new Error(`gemini ${res.status}`);
      const d = (await res.json()) as {
        candidates?: { content?: { parts?: { text?: string }[] } }[];
      };
      return d.candidates?.[0]?.content?.parts?.[0]?.text ?? "";
    },
  },
  {
    name: "groq",
    key: () => process.env.GROQ_API_KEY,
    async call(key, text, signal) {
      const model = process.env.GROQ_MODEL || "llama-3.3-70b-versatile";
      const res = await fetch("https://api.groq.com/openai/v1/chat/completions", {
        method: "POST",
        signal,
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${key}`,
        },
        body: JSON.stringify({
          model,
          temperature: 0.8,
          max_tokens: 60,
          response_format: { type: "json_object" },
          messages: [{ role: "user", content: text }],
        }),
      });
      if (!res.ok) throw new Error(`groq ${res.status}`);
      const d = (await res.json()) as { choices?: { message?: { content?: string } }[] };
      return d.choices?.[0]?.message?.content ?? "";
    },
  },
];

/**
 * A hard ceiling on how long the opponent is allowed to think.
 *
 * The room has a countdown. If every provider is slow AND the clock runs out,
 * expire_turn resolves the lot without the bot — a worse outcome than a
 * heuristic move made in time. Two seconds is longer than either provider's
 * median and short enough to leave the fallback room to act.
 */
const THINK_MS = 2000;

export async function decide(t: BotTurn): Promise<BotChoice> {
  const legal = legalMoves(t);
  const fb: BotChoice = {
    action: t.fallback.action,
    amount_cents: t.fallback.amount_cents,
    why: t.fallback.why,
    source: "heuristic",
  };
  // a fallback the database says is illegal should never be executed either
  if (!legal.includes(fb.action)) {
    return { ...fb, action: legal[0], why: `${fb.why} (corrected to ${legal[0]})` };
  }
  if (legal.length === 1 && legal[0] !== "bid") {
    // only one legal move: asking a model to pick from a list of one is a
    // request spent for nothing, and the free budget is the scarce thing
    return { ...fb, action: legal[0], why: fb.why };
  }

  const text = prompt(t, legal);
  for (const p of PROVIDERS) {
    const key = p.key();
    if (!key) continue;
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), THINK_MS);
    try {
      const raw = await p.call(key, text, ac.signal);
      const choice = parseChoice(raw, legal, t);
      if (choice) return choice;
      // parsed but unusable: try the next provider rather than the fallback,
      // the budget for this request is already spent
    } catch {
      // 429, 5xx, timeout, network — all the same to us: next provider
    } finally {
      clearTimeout(timer);
    }
  }
  return fb;
}
