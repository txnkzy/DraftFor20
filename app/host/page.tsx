import type { Metadata } from "next";
import { HostClient } from "./HostClient";

export const metadata: Metadata = {
  title: "Host settings — DraftFor20",
  description: "Saved room setups and the branding that goes on your shareable results card.",
  robots: { index: false, follow: false },
};

export default function HostPage() {
  return <HostClient />;
}
