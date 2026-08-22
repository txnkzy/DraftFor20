import type { Metadata } from "next";
import { JoinClient } from "./JoinClient";

export const metadata: Metadata = {
  title: "Join a room — DraftFor20",
  description: "Enter the room code your host sent you. No account needed.",
};

export default function JoinPage() {
  return <JoinClient />;
}
