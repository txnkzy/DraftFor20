import type { Metadata } from "next";
import { LoginClient } from "./LoginClient";

export const metadata: Metadata = {
  title: "Host sign in — DraftFor20",
  description:
    "Optional. Sign in to keep your room setups and card branding between drafts. Never needed to play.",
};

export default function LoginPage() {
  return <LoginClient />;
}
