import type { Metadata } from "next";
import { PricingClient } from "./PricingClient";
import { SITE_URL } from "@/lib/site";

export const metadata: Metadata = {
  title: "Pricing — DraftFor20",
  description:
    "Free to play, always. Premium unlocks the Content Creator board, the OBS source and your full scouting report — $5 a month, or $1 for a single game night.",
  alternates: { canonical: `${SITE_URL}/pricing` },
};

/**
 * No Suspense boundary around the whole page any more.
 *
 * It used to wrap PricingClient with `fallback={null}` because that component
 * called useSearchParams(), which opts its subtree out of prerendering. The
 * effect was that the server rendered the fallback — nothing — and every
 * crawler was served a document with a title and an empty body, on the one
 * page a reviewer is most likely to open. The hook now sits in its own small
 * boundary inside PricingClient, so the prose, the plan list and the footer
 * all render on the server where they can be read.
 */
export default function PricingPage() {
  return <PricingClient />;
}
