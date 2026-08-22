import type { Metadata } from "next";
import { VoteClient } from "./VoteClient";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ id: string }>;
}): Promise<Metadata> {
  const { id } = await params;
  // the share card is addressed by room code; a uuid link simply gets no
  // preview image rather than a broken one
  const c = /^[0-9a-f-]{36}$/i.test(id) ? null : id.toUpperCase();
  return {
    title: c ? `Who drafted it better? — DraftFor20 ${c}` : "Who drafted it better? — DraftFor20",
    description:
      "Two rosters, one bankroll each, no algorithm. Look at both and call it.",
    robots: { index: false, follow: true },
    ...(c
      ? {
          openGraph: { images: [`/api/share-card/${c}`] },
          twitter: { card: "summary_large_image" as const, images: [`/api/share-card/${c}`] },
        }
      : {}),
  };
}

export default async function VotePage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  // a room code is upper case; a uuid is not, and must not be mangled
  const ref = /^[0-9a-f-]{36}$/i.test(id) ? id : id.toUpperCase();
  return <VoteClient roomRef={ref} />;
}
