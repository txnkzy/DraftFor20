import type { Metadata } from "next";
import { SignUpClient } from "./SignUpClient";

export const metadata: Metadata = {
  title: "Create a host account — DraftFor20",
  description:
    "Free account for hosting custom categories. Playing and the ready-made shelf never need one.",
};

export default function SignUpPage() {
  return <SignUpClient />;
}
