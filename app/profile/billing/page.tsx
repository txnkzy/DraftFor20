import type { Metadata } from "next";
import { BillingClient } from "./BillingClient";

export const metadata: Metadata = {
  title: "Billing — DraftFor20",
  description: "Your plan, your payment methods, and how to cancel.",
  robots: { index: false, follow: false },
};

export default function BillingPage() {
  return <BillingClient />;
}
