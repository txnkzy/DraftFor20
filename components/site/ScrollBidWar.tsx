"use client";

import { motion, useMotionValueEvent, useScroll } from "framer-motion";
import { useRef, useState } from "react";
import { BidBoard } from "@/components/board/BidBoard";
import { PlayerStrip } from "@/components/board/PlayerStrip";
import { frameAt } from "@/lib/demo/replay";

/**
 * The one animated sequence on the site: a real hand of DraftFor20 that you
 * scrub with the scroll wheel. Card deals, the opener takes at the minimum,
 * the price gets pushed to $7, the clock drains, it locks, then the next card
 * gets handed over for free.
 *
 * It drives the same BidBoard the live room renders, so this is the product
 * running at quarter speed rather than a picture of it. Nothing else on the
 * page moves.
 *
 * The scroll-to-progress mapping is Framer's useScroll. What progress MEANS is
 * frameAt() in lib/demo/replay.ts, which is a pure function and is unit tested,
 * so the only untested link is one documented Framer call.
 */
export function ScrollBidWar() {
  const ref = useRef<HTMLDivElement>(null);
  const { scrollYProgress } = useScroll({ target: ref, offset: ["start start", "end end"] });
  const [progress, setProgress] = useState(0);

  useMotionValueEvent(scrollYProgress, "change", (v) => {
    // ~1% granularity: smoother than the eye, far cheaper than a render on
    // every scrolled pixel
    const q = Math.round(v * 120) / 120;
    setProgress((p) => (p === q ? p : q));
  });

  const { view, lock, caption } = frameAt(progress);
  const p1 = view.players[0];
  const p2 = view.players[1];
  const live = view.phase === "bidding" || view.phase === "offering";

  return (
    // 760vh track against a 100vh sticky panel gives ~660vh of scrub for nine
    // beats, roughly 2.75x what it had. Stretching distance rather than
    // transition duration means it slows down without fighting the wheel.
    <div ref={ref} style={{ height: "760vh" }} className="relative">
      <div className="sticky top-0 flex min-h-dvh items-center py-10">
        <div className="mx-auto grid w-full max-w-5xl gap-8 px-4 lg:grid-cols-[1fr_1.05fr] lg:items-center">
          <div>
            <p className="type-label text-coral">keep scrolling</p>
            <h2 className="type-display mt-3 text-balance text-[2rem] leading-[0.96] sm:text-[2.5rem]">
              One hand, at quarter speed
            </h2>
            <motion.p
              key={caption}
              initial={{ opacity: 0, y: 6 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ duration: 0.25, ease: [0.2, 0.9, 0.3, 1] }}
              className="mt-4 min-h-[4.5rem] max-w-md text-[1rem] leading-relaxed text-muted"
            >
              {caption}
            </motion.p>

            <div className="mt-4 h-[3px] w-full max-w-md bg-surface" aria-hidden>
              <motion.div
                className="h-full bg-coral"
                style={{ scaleX: scrollYProgress, transformOrigin: "left" }}
              />
            </div>
          </div>

          <div className="flex flex-col">
            <div className="panel px-4" style={{ borderRadius: "var(--radius-card)" }}>
              <PlayerStrip
                p={p1} startingCents={view.startingCents}
                markerCents={live ? view.currentBidCents : null}
                onClock={view.onClockSeat === 1 || view.openerSeat === 1}
                isHigh={view.highBidderSeat === 1} givesLeft={p1.givesLeft}
              />
              <div className="h-px w-full border-t rule" />
              <PlayerStrip
                p={p2} startingCents={view.startingCents}
                markerCents={live ? view.currentBidCents : null}
                onClock={view.onClockSeat === 2 || view.openerSeat === 2}
                isHigh={view.highBidderSeat === 2} givesLeft={p2.givesLeft}
              />
            </div>
            <div className="mt-3">
              <BidBoard view={view} lock={lock} />
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
