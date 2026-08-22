import type { Metadata } from "next";
import { Suspense } from "react";
import { CallbackClient } from "./CallbackClient";

export const metadata: Metadata = {
  title: "Signing you in — DraftFor20",
  robots: { index: false, follow: false },
};

export default function CallbackPage() {
  return (
    <Suspense fallback={null}>
      <CallbackClient />
    </Suspense>
  );
}
