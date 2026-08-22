import type { Metadata } from "next";
import { RoomClient } from "./RoomClient";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ code: string }>;
}): Promise<Metadata> {
  const { code } = await params;
  return {
    title: `Draft ${code.toUpperCase()} — DraftFor20`,
    description: `Live two-player auction, room ${code.toUpperCase()}. The deck deals, you bid, the board settles it.`,
    robots: { index: false, follow: false },
  };
}

export default async function RoomPage({ params }: { params: Promise<{ code: string }> }) {
  const { code } = await params;
  return <RoomClient code={code.toUpperCase()} />;
}
