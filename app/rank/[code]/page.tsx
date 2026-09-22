import type { Metadata } from "next";
import { LineupClient } from "./LineupClient";
import { SITE_URL } from "@/lib/site";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ code: string }>;
}): Promise<Metadata> {
  const { code } = await params;
  const c = code.toUpperCase();
  return {
    title: `Rate this lineup — DraftFor20 ${c}`,
    description: "Five picked one at a time, no takebacks. Would you have done better?",
    alternates: { canonical: `${SITE_URL}/rank/${c}` },
    // a live run must not be indexed; the finished board is the shareable thing
    robots: { index: false, follow: true },
  };
}

export default async function LineupPage({
  params,
}: {
  params: Promise<{ code: string }>;
}) {
  const { code } = await params;
  return <LineupClient code={code.toUpperCase()} />;
}
