"use client";

import { useEffect, useState, type ReactNode } from "react";
import { VerticalStage } from "@/components/board/VerticalStage";
import type { BoardView } from "@/lib/game/view";
import type { RoomState } from "@/lib/game/types";

/**
 * RECORD MODE. A layout state and nothing more.
 *
 * No recording happens here and none is claimed to: this puts the board in a
 * 9:16 frame on pure black with every piece of navigation gone, so the host
 * can point their own screen recorder at it. Pure black rather than the app's
 * charcoal because the difference is invisible on a monitor and obvious once
 * it has been through a phone camera and a codec.
 *
 * The host is also a player, so their controls have to survive. They live in
 * the letterbox beside the 9:16 stage, which on any screen wider than 9:16 is
 * outside the frame being recorded.
 */
export function RecordSurface({
  state,
  view,
  landedEntryId,
  onExit,
  children,
}: {
  state: RoomState;
  view: BoardView;
  landedEntryId: string | null;
  onExit: () => void;
  children?: ReactNode;
}) {
  const [hint, setHint] = useState(true);

  useEffect(() => {
    const t = setTimeout(() => setHint(false), 4200);
    return () => clearTimeout(t);
  }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onExit();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onExit]);

  return (
    <div className="fixed inset-0 z-50" style={{ background: "#000" }}>
      <VerticalStage
        state={state}
        view={view}
        landedEntryId={landedEntryId}
        ground="#000"
        plates
      />

      {/* the host's own controls, in the letterbox rather than in the frame */}
      {children ? (
        <div
          className="pointer-events-auto fixed bottom-4 left-1/2 w-[min(24rem,92vw)] -translate-x-1/2 lg:left-6 lg:bottom-6 lg:translate-x-0"
          style={{ zIndex: 60 }}
        >
          <div
            className="panel px-3 py-3"
            style={{ borderRadius: "var(--radius-card)", background: "rgba(29,32,41,0.94)" }}
          >
            {children}
          </div>
        </div>
      ) : null}

      <button
        onClick={onExit}
        className="type-label fixed right-4 top-4 px-2 py-1 text-muted hover:text-ink"
        style={{ zIndex: 60, background: "rgba(0,0,0,0.72)" }}
      >
        exit record mode
      </button>

      {/* both of these hug the edges of the viewport, which on anything wider
          than 9:16 is letterbox rather than frame. The hint leaves on its own
          before anybody has started recording. */}
      {hint ? (
        <p
          className="type-label fixed left-4 top-4 max-w-[14rem] px-3 py-1.5 text-muted"
          style={{ zIndex: 60, background: "rgba(0,0,0,0.72)" }}
        >
          9:16 frame &middot; right edge kept clear for TikTok&apos;s buttons &middot; esc to leave
        </p>
      ) : null}
    </div>
  );
}
