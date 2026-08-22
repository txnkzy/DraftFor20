"use client";

import { useEffect, useState } from "react";
import { supabaseBrowser, supabaseConfigured } from "@/lib/supabase/client";

export interface AudienceTally {
  total: number;
  by_player: Record<string, number>;
}

/**
 * The audience vote, pushed.
 *
 * cast_audience_vote() calls realtime.send() inside the same transaction that
 * records the vote, on the room's channel with the tally as the payload — so
 * this is a websocket message carrying the numbers, not a poll and not even a
 * refetch. Every open tally moves on the same push.
 *
 * `enabled` is the blind rule, not an optimisation. A viewer who has not
 * voted must not be subscribed, because the payload IS the answer they have
 * not earned yet.
 *
 * The slow interval underneath is a safety net for a websocket that never
 * connected — a stalled tally is a worse failure than a request every twelve
 * seconds — and it is why realtime being misconfigured costs latency rather
 * than correctness, the same trade the board makes.
 */
export function useAudienceTally(
  roomId: string | null | undefined,
  enabled: boolean,
  refetch?: () => void,
): AudienceTally | null {
  const [tally, setTally] = useState<AudienceTally | null>(null);

  useEffect(() => {
    if (!roomId || !enabled || !supabaseConfigured()) return;
    const sb = supabaseBrowser();
    const channel = sb
      .channel(`room:${roomId}`)
      .on("broadcast", { event: "audience" }, (msg) => {
        const t = msg.payload as AudienceTally | null;
        if (t && typeof t.total === "number") setTally(t);
      })
      .subscribe();

    const id = refetch ? setInterval(refetch, 12000) : null;
    return () => {
      if (id) clearInterval(id);
      void sb.removeChannel(channel);
    };
  }, [roomId, enabled, refetch]);

  return tally;
}
