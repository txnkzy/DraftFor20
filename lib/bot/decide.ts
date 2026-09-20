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
  /** optimistic-concurrency counter; also the per-turn LLM budget key */
  turn_seq: number;
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

const money = (c: number) => `$${(c / 100).toFixed(2)}`;

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

function prompt(t: BotTurn, legal: BotAction[]): string {
  const roster = (r: { item: string; price_cents: number }[]) =>
    r.length ? r.map((e) => `${e.item} (${money(e.price_cents)})`).join(", ") : "empty";

  const rules =
    t.phase === "bidding"
      ? `The current bid is ${money(t.current_bid_cents)}. Raising means bidding ` +
        `${money(t.current_bid_cents + t.min_bid_cents)}. You cannot bid more than ` +
        `${money(t.me.max_legal_bid_cents)}.`
      : `You opened this card. Taking it costs ${money(t.min_bid_cents)}. ` +
        `Giving it away puts it on ${t.opponent.name}'s roster for free and uses ` +
        `one of your ${t.me.gives_left} remaining gives. ` +
        `Forcing means it lands on your roster for $0 because you cannot afford it.`;

  return [
    `You are ${t.me.name}, playing a two-player auction draft against ${t.opponent.name}.`,
    `Category: ${t.category ?? "mixed"}. The card on the table is: ${t.item}.`,
    ``,
    `You: ${money(t.me.bankroll_cents)} left, ${t.me.open_slots} roster slot(s) to fill.`,
    `Your roster: ${roster(t.me.roster)}`,
    `${t.opponent.name}: ${money(t.opponent.bankroll_cents)} left, ${t.opponent.open_slots} slot(s) to fill.`,
    `Their roster: ${roster(t.opponent.roster)}`,
    ``,
    rules,
    ``,
    `Whatever you do not spend is your score at the end, so overpaying loses.`,
    `But a slot you never fill is worse than one filled cheaply.`,
    ``,
    `Choose exactly one of: ${legal.join(", ")}.`,
    `Reply with ONLY a JSON object, no prose, no code fence:`,
    `{"action":"<one of the above>","amount_cents":<integer, only if action is bid>,"why":"<max 12 words>"}`,
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
  const action = String(obj.action ?? "") as BotAction;
  if (!legal.includes(action)) return null;

  let amount: number | undefined;
  if (action === "bid") {
    amount = Math.trunc(Number(obj.amount_cents));
    if (!Number.isFinite(amount)) return null;
    // clamp rather than reject: a model that says "raise" and fumbles the
    // arithmetic still meant to raise, and Postgres would refuse the number
    const floor = t.current_bid_cents + t.min_bid_cents;
    amount = Math.max(floor, Math.min(amount, t.me.max_legal_bid_cents));
  }
  const why = String(obj.why ?? "").slice(0, 80) || "no reason given";
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
              maxOutputTokens: 120,
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
          max_tokens: 120,
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
