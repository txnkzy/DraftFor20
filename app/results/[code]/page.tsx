import type { Metadata } from "next";
import { ResultsClient } from "./ResultsClient";

export async function generateMetadata({
  params,
}: {
  params: Promise<{ code: string }>;
}): Promise<Metadata> {
  const { code } = await params;
  return {
    title: `Final board ${code.toUpperCase()} — DraftFor20`,
    description: `Both rosters, every price paid and the leftover cash from draft ${code.toUpperCase()}.`,
    robots: { index: false, follow: true },
    openGraph: { images: [`/api/share-card/${code.toUpperCase()}`] },
    twitter: { card: "summary_large_image", images: [`/api/share-card/${code.toUpperCase()}`] },
  };
}

export default async function ResultsPage({ params }: { params: Promise<{ code: string }> }) {
  const { code } = await params;
  return <ResultsClient code={code.toUpperCase()} />;
}
