"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { supabaseBrowser } from "@/lib/supabase/client";
import { readableError } from "./errors";
import type { RoomState } from "./types";
import type { Seat } from "./session";

type Rpc = Record<string, unknown>;

/**
 * One live room. Realtime broadcast is the fast path; a poll runs alongside it
 * so a realtime misconfiguration costs latency and never correctness. Any
 * snapshot older than the one we hold is dropped, so out-of-order delivery
 * can't rewind the board.
 */
export function useRoom(code: string, seat: Seat | null) {
  const sb = useMemo(() => supabaseBrowser(), []);
  const [state, setState] = useState<RoomState | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [rawError, setRawError] = useState<string | null>(null);
  /** bumped every time an error lands, so a flash can be keyed off it */
  const [errorNonce, setErrorNonce] = useState(0);
  const [pending, setPending] = useState(false);
  const [loaded, setLoaded] = useState(false);

  const skewRef = useRef(0);
  const stateRef = useRef<RoomState | null>(null);

  const apply = useCallback((next: unknown) => {
    const s = next as RoomState | null;
    if (!s || !s.room) return;
    skewRef.current = Date.parse(s.server_now) - Date.now();
    setState((prev) => {
      if (prev && s.room.version < prev.room.version) return prev;
      stateRef.current = s;
      return s;
    });
  }, []);

  /** Server time, corrected for this client's clock offset. */
  const serverNow = useCallback(() => Date.now() + skewRef.current, []);

  const refresh = useCallback(async () => {
    const { data, error: e } = await sb.rpc("get_room_state", { p_code: code });
    if (e) {
      setRawError(e.message);
      setError(readableError(e.message));
      setErrorNonce((n) => n + 1);
    } else {
      apply(data);
      setError(null);
      setRawError(null);
    }
    setLoaded(true);
  }, [sb, code, apply]);

  const call = useCallback(
    async (fn: string, args: Rpc) => {
      setPending(true);
      const { data, error: e } = await sb.rpc(fn, { p_code: code, ...args });
      setPending(false);
      if (e) {
        setRawError(e.message);
        setError(readableError(e.message));
        setErrorNonce((n) => n + 1);
        void refresh();
        return null;
      }
      setError(null);
      setRawError(null);
      apply(data);
      return data as RoomState;
    },
    [sb, code, apply, refresh],
  );

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const { data, error: e } = await sb.rpc("get_room_state", { p_code: code });
      if (cancelled) return;
      if (e) {
        setRawError(e.message);
        setError(readableError(e.message));
      } else {
        apply(data);
      }
      setLoaded(true);
    })();
    return () => {
      cancelled = true;
    };
  }, [sb, code, apply]);

  /* ── realtime fast path ─────────────────────────────────────────────── */
  const roomId = state?.room.id;
  useEffect(() => {
    if (!roomId) return;
    const channel = sb
      .channel(`room:${roomId}`)
      .on("broadcast", { event: "state" }, (msg) => apply(msg.payload))
      .subscribe();
    return () => {
      void sb.removeChannel(channel);
    };
  }, [sb, roomId, apply]);

  /* ── poll fallback. Tight while a lot is live, lazy otherwise. ──────── */
  const phase = state?.room.phase;
  useEffect(() => {
    const live = phase === "offering" || phase === "bidding";
    const id = setInterval(() => void refresh(), live ? 2500 : 7000);
    return () => clearInterval(id);
  }, [phase, refresh]);

  /* ── timer expiry driver ────────────────────────────────────────────────
     Whichever client's countdown hits zero calls expire_turn. It is
     idempotent and no-ops unless the deadline genuinely passed, so both
     clients racing is harmless. The 350ms pad avoids a pointless round trip
     from clock jitter. */
  const lotId = state?.lot?.id;
  const turnSeq = state?.lot?.turn_seq;
  const expiresAt = state?.lot?.turn_expires_at;
  useEffect(() => {
    if ((phase !== "bidding" && phase !== "offering") || !expiresAt || !lotId) return;
    const delay = Math.max(Date.parse(expiresAt) - serverNow() + 350, 0);
    const t = setTimeout(() => {
      void sb.rpc("expire_turn", { p_code: code }).then(({ data }) => apply(data));
    }, delay);
    return () => clearTimeout(t);
  }, [sb, code, phase, expiresAt, lotId, turnSeq, serverNow, apply]);

  /* ── actions ────────────────────────────────────────────────────────── */
  const token = seat?.sessionToken ?? null;

  const actions = useMemo(
    () => ({
      start: () => call("start_draft", { p_token: token }),
      /** the opener's call on a freshly dealt card */
      offerDecide: (choice: "take" | "give" | "discard") =>
        call("offer_decide", { p_token: token, p_choice: choice }),
      placeBid: (amountCents: number) =>
        call("place_bid", {
          p_token: token,
          p_amount_cents: amountCents,
          p_expected_turn_seq: stateRef.current?.lot?.turn_seq ?? 0,
        }),
      pass: () =>
        call("pass_turn", {
          p_token: token,
          p_expected_turn_seq: stateRef.current?.lot?.turn_seq ?? 0,
        }),
      vote: (winnerPlayerId: string) =>
        call("submit_vote", { p_token: token, p_winner_player_id: winnerPlayerId }),
      /** ends the room for both people; see LeaveRoom for the confirmation */
      leave: () => call("leave_room", { p_token: token }),
    }),
    [call, token],
  );

  const clearError = useCallback(() => {
    setError(null);
    setRawError(null);
  }, []);

  return {
    state,
    error,
    rawError,
    errorNonce,
    clearError,
    pending,
    loaded,
    refresh,
    serverNow,
    actions,
  };
}

/**
 * Countdown against the server's deadline, not a local setTimeout. A client
 * that stalls its own JS cannot buy itself time; the server rejects late bids
 * regardless of what this renders.
 */
export function useCountdown(
  expiresAt: string | null | undefined,
  serverNow: () => number,
  totalSeconds: number,
) {
  const [msLeft, setMsLeft] = useState<number | null>(null);

  useEffect(() => {
    if (!expiresAt) return;
    const target = Date.parse(expiresAt);
    let raf = 0;
    let last = -1;
    const tick = () => {
      const left = Math.max(target - serverNow(), 0);
      // repaint at ~15fps: enough for a smooth drain, cheap enough for a phone
      if (last < 0 || Math.abs(left - last) > 60 || left === 0) {
        last = left;
        setMsLeft(left);
      }
      if (left > 0) raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [expiresAt, serverNow]);

  // stale ms from a previous lot must not leak into the next one
  const live = expiresAt ? msLeft : null;
  const total = totalSeconds * 1000;
  const fraction = live === null ? 1 : Math.max(0, Math.min(1, live / total));
  const seconds = live === null ? null : Math.ceil(live / 1000);
  return {
    msLeft: live,
    seconds,
    fraction,
    urgent: seconds !== null && seconds <= 5,
    /* the last three seconds, where the clock stops being information and
       starts being pressure. Drives the pulse, not just the colour. */
    critical: seconds !== null && seconds > 0 && seconds <= 3,
  };
}
