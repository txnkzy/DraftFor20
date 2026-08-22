import type { Metadata } from "next";
import { SetupClient } from "./SetupClient";

export const metadata: Metadata = {
  title: "Build the list — DraftFor20",
  description: "Name a category and enter the items. The two players never see this page.",
  robots: { index: false, follow: false },
};

export default async function SetupPage({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  return <SetupClient token={token} />;
}
