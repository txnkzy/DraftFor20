"use client";

import dynamic from "next/dynamic";

/**
 * Framer Motion is loaded ONLY here, on the landing page, and only in the
 * browser. The game room never imports this file, so the bundle a player
 * downloads mid-draft carries no animation library at all.
 */
const ScrollBidWar = dynamic(
  () => import("./ScrollBidWar").then((m) => m.ScrollBidWar),
  {
    ssr: false,
    loading: () => (
      <div className="grid min-h-dvh place-items-center px-4">
        <p className="type-label text-muted">loading the board</p>
      </div>
    ),
  },
);

export function ScrollBidWarLoader() {
  return <ScrollBidWar />;
}
