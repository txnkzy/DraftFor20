"use client";

import { useEffect, useState } from "react";
import { ResultsBoard } from "@/components/results/ResultsBoard";
import { Footer, Header, SetupNotice } from "@/components/site/Chrome";
import { useSeat } from "@/lib/game/session";
import type { RoomState } from "@/lib/game/types";
import { supabaseBrowser, supabaseConfigured } from "@/lib/supabase/client";

export function ResultsClient({ code }: { code: string }) {
  if (!supabaseConfigured()) return <SetupNotice />;
  return <Results code={code} />;
}

function Results({ code }: { code: string }) {
  const seat = useSeat(code);
  const [state, setState] = useState<RoomState | null>(null);
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      const { data } = await supabaseBrowser().rpc("get_room_state", { p_code: code });
      if (cancelled) return;
      setState((data as RoomState) ?? null);
      setLoaded(true);
    })();
    return () => {
      cancelled = true;
    };
  }, [code]);

  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-3xl px-4 py-8">
        {!loaded ? (
          <>
            <h1 className="type-display text-[1.75rem]">Final board</h1>
            <p className="type-label mt-2 text-muted">loading</p>
          </>
        ) : !state ? (
          <>
            <h1 className="type-display text-[1.75rem]">No room {code}</h1>
            <p className="type-label mt-2 text-muted">that code doesn&apos;t match a draft</p>
          </>
        ) : state.room.status !== "complete" ? (
          <>
            <h1 className="type-display text-[1.75rem]">{state.room.title}</h1>
            <p className="type-label mt-2 text-muted">this draft isn&apos;t finished yet</p>
          </>
        ) : (
          <ResultsBoard
            state={state}
            me={state.players.find((p) => p.id === seat?.playerId) ?? null}
          />
        )}
      </main>
      <Footer />
    </>
  );
}
