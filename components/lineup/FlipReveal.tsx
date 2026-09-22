"use client";

import { useEffect, useRef, useState } from "react";
import { CardImage } from "@/components/board/CardImage";

/**
 * The riffle. Cycles fast through the category's pictures, slows, and lands
 * on the card actually dealt.
 *
 * WHAT IT SHOWS IS NOT THE DECK. The images are every picture in the
 * CATEGORY, which is public the moment you pick it, so the flicker leaks
 * nothing about which five you will get — the real card arrives from the
 * server and is simply the frame the animation stops on.
 *
 * It eases out rather than cutting: a constant-rate flicker that stops dead
 * reads as a spinner that finished, and the whole point is the beat before
 * you see what you have been handed.
 *
 * SPINNING IS DERIVED, not stored. Setting it synchronously in the effect
 * cascaded a render for a value that is a pure function of "which card, and
 * has its riffle finished" — and only the second half needs state, written
 * from a timeout rather than the effect body.
 */
const FRAMES = 18;

export function FlipReveal({
  card,
  pool,
  height = 260,
  onSettled,
}: {
  card: { name: string; image_url: string | null } | null;
  pool: string[];
  height?: number;
  onSettled?: () => void;
}) {
  const [frame, setFrame] = useState<string | null>(null);
  /** the card whose riffle has finished; compared against the current one */
  const [settledFor, setSettledFor] = useState<string | null>(null);
  const timers = useRef<number[]>([]);

  useEffect(() => {
    if (!card) return;
    /* IDEMPOTENT, NOT ONE-SHOT. This was a ref guard that returned early if
       the card had been seen before — which StrictMode turns into a hang:
       it runs the effect, tears it down (clearing every pending timer), and
       runs it again, where the guard schedules nothing and the card riffles
       for ever. Keying the skip on the SETTLED state instead means a
       re-invocation reschedules what the cleanup threw away, and a card that
       has genuinely finished is still left alone. */
    if (settledFor === card.name) return;

    timers.current.forEach(clearTimeout);
    timers.current = [];

    const finish = () => {
      setFrame(null);
      setSettledFor(card.name);
      onSettled?.();
    };

    // Nothing to riffle through: settle on the next tick rather than
    // synchronously, so this never writes state during the effect itself.
    if (pool.length < 2) {
      timers.current.push(window.setTimeout(finish, 0));
      return () => {
        timers.current.forEach(clearTimeout);
        timers.current = [];
      };
    }

    let delay = 0;
    for (let i = 0; i < FRAMES; i++) {
      // ease out: ~45ms at the start, ~190ms by the last frame
      delay += 45 + Math.round((i / FRAMES) ** 2 * 150);
      const src = pool[Math.floor(Math.random() * pool.length)];
      timers.current.push(window.setTimeout(() => setFrame(src), delay));
    }
    timers.current.push(window.setTimeout(finish, delay + 120));

    return () => {
      timers.current.forEach(clearTimeout);
      timers.current = [];
    };
    // onSettled is in the deps rather than behind a ref, so the parent MUST
    // memoise it: an inline arrow would change identity every render, React
    // would run the cleanup, and the early return above would then leave the
    // riffle with its timers cleared and no new ones scheduled.
  }, [card, pool, onSettled, settledFor]);

  useEffect(
    () => () => {
      timers.current.forEach(clearTimeout);
    },
    [],
  );

  if (!card) return null;
  const spinning = settledFor !== card.name;

  return (
    <div className="flex flex-col items-center">
      <div
        className="panel flex w-full items-center justify-center overflow-hidden"
        style={{ height }}
      >
        {spinning && frame ? (
          // eslint-disable-next-line @next/next/no-img-element
          <img
            src={frame}
            alt=""
            aria-hidden
            className="h-full w-full object-contain opacity-70"
          />
        ) : (
          <CardImage name={card.name} url={card.image_url} height={height} className="h-full" />
        )}
      </div>
      <p
        className="type-display mt-3 text-center text-[1.375rem] leading-tight"
        aria-live="polite"
      >
        {spinning ? <span className="text-muted">&hellip;</span> : card.name}
      </p>
    </div>
  );
}
