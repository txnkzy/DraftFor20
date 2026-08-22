import type { Metadata } from "next";
import { ObsClient } from "./ObsClient";

/* a live overlay: there is nothing here worth prerendering, and
   useSearchParams() in the client below would need a Suspense boundary if
   there were */
export const dynamic = "force-dynamic";

export const metadata: Metadata = {
  title: "DraftFor20 browser source",
  robots: { index: false, follow: false },
};

export default async function ObsPage({ params }: { params: Promise<{ token: string }> }) {
  const { token } = await params;
  return <ObsClient token={token} />;
}
