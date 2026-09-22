import type { Metadata } from "next";
import { RankClient } from "./RankClient";
import { SITE_URL } from "@/lib/site";

export const metadata: Metadata = {
  title: "Build the Lineup — DraftFor20",
  description:
    "Five cards, five slots, one at a time. Place each one before you see the next — and live with it when someone better turns up.",
  alternates: { canonical: `${SITE_URL}/rank` },
};

export default function RankPage() {
  return <RankClient />;
}
