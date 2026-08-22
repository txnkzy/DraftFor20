"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import { Button } from "@/components/ui/Button";

/**
 * The way out of a room.
 *
 * There was none: no link, no button, nothing but the browser's back button
 * or closing the tab — and closing the tab left the other player on a clock
 * that kept ticking, because expire_turn cheerfully resolves lots on behalf
 * of somebody who is no longer there.
 *
 * Leaving mid-draft ends the room for both people, so it asks first. A player
 * with no seat is only a spectator and just navigates.
 */
export function LeaveRoom({
  seated,
  live,
  opponent = null,
  onLeave,
}: {
  /** does this browser hold a seat in this room */
  seated: boolean;
  /** is there a room in progress worth warning about */
  live: boolean;
  /** the other player's name, when somebody is actually sitting there */
  opponent?: string | null;
  onLeave: () => Promise<unknown>;
}) {
  const router = useRouter();
  const [asking, setAsking] = useState(false);
  const [busy, setBusy] = useState(false);

  async function go() {
    setBusy(true);
    try {
      if (seated && live) await onLeave();
    } catch {
      // the room state is the server's problem; leaving is not blocked by it
    }
    router.push("/");
  }

  return (
    <>
      <button
        className="type-label text-muted hover:text-ink"
        aria-label="Leave this room and go home"
        onClick={() => (seated && live ? setAsking(true) : void go())}
      >
        &larr; home
      </button>

      {asking ? (
        <div
          className="fixed inset-0 z-50 grid place-items-center px-4"
          style={{ background: "rgba(20,22,28,0.86)" }}
          role="dialog"
          aria-modal="true"
          aria-labelledby="leave-title"
          onClick={() => setAsking(false)}
        >
          <div
            className="panel w-full max-w-sm p-5"
            style={{ borderRadius: "var(--radius-card)" }}
            onClick={(e) => e.stopPropagation()}
          >
            <h2 id="leave-title" className="type-display text-[1.25rem]">
              Leave this game?
            </h2>
            <p className="mt-2 text-[0.9375rem] leading-relaxed text-muted">
              {opponent
                ? `${opponent} will be told you left, and the draft ends here for both of you.`
                : "This closes the room, so the code stops working for anybody you sent it to."}{" "}
              The picks already made stay on the board; there is no winner and nothing to come
              back to.
            </p>
            <div className="mt-5 flex flex-col gap-2 sm:flex-row">
              <Button
                variant="ghost"
                className="flex-1"
                disabled={busy}
                onClick={() => setAsking(false)}
              >
                Stay
              </Button>
              {/* teal is the settled / step-away action; coral stays with the
                  bidding controls, where the tension belongs */}
              <Button variant="calm" className="flex-1" disabled={busy} onClick={() => void go()}>
                {busy ? "Leaving" : "Leave the game"}
              </Button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  );
}
