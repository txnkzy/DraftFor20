"use client";

import { useEffect, useRef, useState } from "react";
import type { RoomState } from "./types";

export interface BotMove {
  action: string;
  why: string;
  source: "llm" | "heuristic";
  amount_cents: number | null;
}

/**
 * Drives the Quick Play opponent from whichever browser is watching.
 *
 * SAME SHAPE AS THE EXISTING expire_turn DRIVER in useRoom: the client
 * notices a server-side condition and pokes an endpoint that is idempotent
 * about it. bot_act refuses when it is not the bot's turn, so a double-fire
 * from a re-render or a second tab is harmless.
 *
 * The pause before it moves is deliberate. A bot that answers in 40ms reads
 * as a script, and on a filmed draft the beat before an opponent commits is
 * most of the drama. It also gives the LLM its two seconds without the
 * player watching a spinner.
 */
export function useBotTurn(
  state: RoomState | null,
  code: string,
  /** safety net only — bot_act broadcasts, so the board usually moves first */
  onActed: () => void,
) {
  const [thinking, setThinking] = useState(false);
  const [lastMove, setLastMove] = useState<BotMove | null>(null);
  /** the turn we have already fired for, so a re-render cannot double-fire */
  const firedFor = useRef<string>("");

  const isSolo = state?.room.is_solo ?? false;
  const phase = state?.room.phase;
  const lot = state?.lot;
  const bot = state?.players.find((p) => p.is_bot);
  const botOnClock = !!bot && lot?.on_the_clock_player_id === bot.id;
  const turnKey = `${lot?.id ?? ""}:${lot?.turn_seq ?? ""}`;

  useEffect(() => {
    if (!isSolo || !botOnClock) return;
    if (phase !== "offering" && phase !== "bidding") return;
    if (firedFor.current === turnKey) return;
    firedFor.current = turnKey;

    let cancelled = false;
    setThinking(true);
    // 700-1400ms: long enough to read as a decision, short enough that a
    // 20-second turn clock is never the thing that resolves the lot
    const wait = 700 + Math.random() * 700;

    const t = setTimeout(() => {
      void (async () => {
        try {
          const res = await fetch("/api/bot/act", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ code }),
          });
          const d = (await res.json()) as {
            acted?: boolean; action?: string; why?: string;
            source?: "llm" | "heuristic"; amount_cents?: number | null;
          };
          if (cancelled) return;
          if (d.acted) {
            setLastMove({
              action: d.action ?? "", why: d.why ?? "",
              source: d.source ?? "heuristic", amount_cents: d.amount_cents ?? null,
            });
            onActed();
          } else {
            // nothing happened — let the next poll try again rather than
            // leaving the turn permanently marked as fired
            firedFor.current = "";
          }
        } catch {
          firedFor.current = "";
        } finally {
          if (!cancelled) setThinking(false);
        }
      })();
    }, wait);

    return () => {
      cancelled = true;
      clearTimeout(t);
      setThinking(false);
    };
  }, [isSolo, botOnClock, phase, turnKey, code, onActed]);

  return { thinking, lastMove, botName: bot?.display_name ?? "DraftFor20Bot" };
}
