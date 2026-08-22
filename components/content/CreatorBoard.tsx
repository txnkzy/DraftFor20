"use client";

import type { ReactNode } from "react";
import { VerticalStage } from "@/components/board/VerticalStage";
import { ContentPanel } from "./ContentPanel";
import type { BoardView } from "@/lib/game/view";
import type { RoomState } from "@/lib/game/types";
import type { PremiumState } from "@/lib/premium";

/**
 * A Content Creator room, live.
 *
 * This is not the standard board with different colours. The standard board
 * is a three-column desktop grid — roster, card, roster — with a sticky
 * header carrying both Rails and a running bid history underneath. This is a
 * single 9:16 column: seat 1's roster in the top third, the card and the
 * money and the clock dead centre, seat 2's roster in the bottom third, with
 * the right edge and the bottom strip held empty for the buttons TikTok
 * draws over a recording. Different information, different arrangement,
 * different reading distance.
 *
 * Everything that is not the shot lives in the rail beside it, which is
 * outside the 9:16 frame on any screen wider than it — so what gets recorded
 * is the board and nothing else, without hiding the controls from the person
 * playing.
 */
export function CreatorBoard({
  state,
  view,
  landedEntryId,
  code,
  sessionToken,
  isHost,
  premium,
  onRecordMode,
  children,
}: {
  state: RoomState;
  view: BoardView;
  landedEntryId: string | null;
  code: string;
  sessionToken: string | null;
  isHost: boolean;
  premium: PremiumState;
  onRecordMode: () => void;
  children?: ReactNode;
}) {
  return (
    <main className="mx-auto flex min-h-dvh w-full max-w-7xl flex-col lg:flex-row">
      {/* THE SHOT.
          A DEFINITE height, not min-height: the stage inside measures its
          parent to work out its scale, and a percentage height against a
          parent sized by min-height plus flex resolves to zero — which draws
          nothing at all and looks like a broken board. */}
      <div
        className="h-[62dvh] w-full shrink-0 lg:h-dvh lg:w-auto lg:flex-1"
        style={{ background: "#000" }}
      >
        <VerticalStage
          state={state}
          view={view}
          landedEntryId={landedEntryId}
          ground="#000"
          plates
        />
      </div>

      {/* EVERYTHING THAT IS NOT THE SHOT */}
      <aside className="w-full border-t px-4 py-4 rule lg:w-[23rem] lg:shrink-0 lg:overflow-y-auto lg:border-l lg:border-t-0">
        <div className="flex items-baseline justify-between gap-3">
          <h1 className="type-display truncate text-[0.9375rem]">{state.room.title}</h1>
          <span className="type-num shrink-0 text-[0.6875rem] text-muted">{code}</span>
        </div>
        <p className="type-label mt-1 text-teal">content creator room</p>

        {children ? <div className="mt-4">{children}</div> : null}

        {isHost ? (
          <div className="mt-6 border-t pt-4 rule">
            <ContentPanel
              code={code}
              state={state}
              sessionToken={sessionToken}
              premium={premium}
              onRecordMode={onRecordMode}
            />
          </div>
        ) : null}
      </aside>
    </main>
  );
}
