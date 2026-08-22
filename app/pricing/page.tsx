import type { Metadata } from "next";
import { Suspense } from "react";
import { PricingClient } from "./PricingClient";

export const metadata: Metadata = {
  title: "Pricing — DraftFor20",
  description:
    "Free to play, always. Premium unlocks the Content Creator board, the OBS source and your full scouting report — $5 a month, or $1 for a single game night.",
};

export default function PricingPage() {
  // useSearchParams() opts a client component out of prerendering unless it
  // sits behind a boundary. Pricing is the page most worth serving statically,
  // so it gets the boundary rather than force-dynamic.
  return (
    <Suspense fallback={null}>
      <PricingClient />
    </Suspense>
  );
}
