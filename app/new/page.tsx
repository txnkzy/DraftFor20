import type { Metadata } from "next";
import { NewRoomClient } from "./NewRoomClient";

export const metadata: Metadata = {
  title: "Start a room — DraftFor20",
  description:
    "Set the roster size, the bankroll and the clock, then send the code. No signup needed.",
};

export default function NewRoomPage() {
  return <NewRoomClient />;
}
