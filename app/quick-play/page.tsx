import type { Metadata } from "next";
import { QuickPlayClient } from "./QuickPlayClient";
import { SITE_URL } from "@/lib/site";

export const metadata: Metadata = {
  alternates: { canonical: "/quick-play" },
  title: "Quick Play — draft against DraftFor20Bot",
  description:
    "Play the $20 draft solo against a computer opponent. No second player, no account, no download — one draft takes about ten minutes.",
  openGraph: {
    title: "Quick Play — the $20 draft, solo",
    description: "One draft against DraftFor20Bot. No second player needed.",
    url: `${SITE_URL}/quick-play`,
  },
};

export default function QuickPlayPage() {
  return <QuickPlayClient />;
}
