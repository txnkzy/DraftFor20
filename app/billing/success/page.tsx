import type { Metadata } from "next";
import { SuccessClient } from "./SuccessClient";

export const metadata: Metadata = {
  title: "Payment received — DraftFor20",
  robots: { index: false, follow: false },
};

/* the customer arrives here from Stripe; there is nothing to prerender */
export const dynamic = "force-dynamic";

export default function BillingSuccessPage() {
  return <SuccessClient />;
}
