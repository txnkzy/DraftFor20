"use client";

import { useSearchParams } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";
import { VerticalStage } from "@/components/board/VerticalStage";
import { useCountdown } from "@/lib/game/useRoom";
import { buildBoardView } from "@/lib/game/view";
import type { RoomState } from "@/lib/game/types";
import { supabaseBrowser, supabaseConfigured } from "@/lib/supabase/client";

/**
 * The OBS Browser Source.
 *
 * READ-ONLY BY CONSTRUCTION. The only thing this page can call is
 * get_obs_state(token). Every mutating RPC in the app authenticates from a
 * player's session token, which this page has never been given and has no way
 * to obtain — so there is no action available here to hide.
 *
 * Realtime is used as a SIGNAL only: a broadcast means "something moved", and
 * this refetches through the token. The broadcast payload itself is the full
 * player-facing snapshot, which carries the room code, and a URL that ends up
 * pasted into OBS should not be a way to learn the code.
 */
export function ObsClient({ token }: { token: string }) {
  const [state, setState] = useState<RoomState | null>(null);
  const [loaded, setLoaded] = useState(false);
  const skew = useRef(0);

  // OBS composites this over the scene, so the document itself paints nothing
  const q = useSearchParams();
  const transparent = q.get("bg") !== "solid";
  const plates = q.get("plate") !== "0";
  useEffect(() => {
    if (!transparent) return;
    const html = document.documentElement;
    const prevHtml = html.style.background;
    const prevBody = document.body.style.background;
    html.style.background = "transparent";
    document.body.style.background = "transparent";
    return () => {
      html.style.background = prevHtml;
      document.body.style.background = prevBody;
    };
  }, [transparent]);

  const read = useCallback(async (): Promise<RoomState | null> => {
    if (!supabaseConfigured()) return null;
    const { data } = await supabaseBrowser().rpc("get_obs_state", { p_obs_token: token });
    return (data as RoomState | null) ?? null;
  }, [token]);

  const apply = useCallback((s: RoomState | null) => {
    if (s?.server_now) skew.current = Date.parse(s.server_now) - Date.now();
    // an out-of-order arrival must not rewind the overlay
    setState((prev) => (prev && s && s.room.version < prev.room.version ? prev : s));
    setLoaded(true);
  }, []);

  const load = useCallback(async () => {
    apply(await read());
  }, [read, apply]);

  useEffect(() => {
    let off = false;
    void (async () => {
      const s = await read();
      if (!off) apply(s);
    })();
    return () => {
      off = true;
    };
  }, [read, apply]);

  /* realtime as a doorbell, then a fresh read through the token */
  const roomId = state?.room.id;
  useEffect(() => {
    if (!roomId || !supabaseConfigured()) return;
    const sb = supabaseBrowser();
    const ch = sb
      .channel(`room:${roomId}`)
      .on("broadcast", { event: "state" }, () => void load())
      .subscribe();
    return () => {
      void sb.removeChannel(ch);
    };
  }, [roomId, load]);

  /* and a poll, because an overlay that silently freezes is worse than one
     that is a second behind */
  useEffect(() => {
    const id = setInterval(() => void load(), 2500);
    return () => clearInterval(id);
  }, [load]);

  const serverNow = useCallback(() => Date.now() + skew.current, []);
  const cd = useCountdown(state?.lot?.turn_expires_at, serverNow, state?.room.timer_seconds ?? 15);

  /* the card that just landed, so the roster row settles instead of appearing.
     Derived from the resolve timestamp rather than held in state: the
     animations are fill-mode both, so a class that lingers a beat longer than
     its 540ms costs nothing. */
  const resolvedAt = state?.lot?.status === "resolved" ? state.lot.resolved_at : null;
  const landed =
    resolvedAt && state && Date.parse(state.server_now) - Date.parse(resolvedAt) < 1600
      ? ([...state.roster].sort((a, b) => b.won_at.localeCompare(a.won_at))[0]?.id ?? null)
      : null;

  if (!loaded) return <div style={{ minHeight: "100dvh" }} />;

  if (!state) {
    return (
      <div className="grid min-h-dvh place-items-center px-6 text-center">
        <p className="type-label text-muted">
          this browser source link is no longer valid
        </p>
      </div>
    );
  }

  const view = buildBoardView(state, cd);

  return (
    <div style={{ height: "100dvh", width: "100vw" }}>
      <VerticalStage
        state={state}
        view={view}
        landedEntryId={landed}
        transparent={transparent}
        plates={plates}
      />
    </div>
  );
}
