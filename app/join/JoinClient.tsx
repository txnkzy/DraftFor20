"use client";

import { useRouter } from "next/navigation";
import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { Field, TextInput } from "@/components/ui/Field";
import { Footer, Header, SetupNotice } from "@/components/site/Chrome";
import { readableError } from "@/lib/game/errors";
import { saveSeat } from "@/lib/game/session";
import { supabaseBrowser, supabaseConfigured } from "@/lib/supabase/client";

export function JoinClient() {
  if (!supabaseConfigured()) return <SetupNotice />;
  return <Join />;
}

function Join() {
  const router = useRouter();
  const [code, setCode] = useState("");
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function go() {
    const c = code.trim().toUpperCase();
    if (c.length < 4 || !name.trim()) return;
    setBusy(true);
    setError(null);
    const { data, error: e } = await supabaseBrowser().rpc("join_room", {
      p_code: c,
      p_display_name: name.trim(),
    });
    setBusy(false);
    if (e) {
      // already started or full: still let them open the room and watch
      if (e.message.includes("DF20_ALREADY_STARTED") || e.message.includes("DF20_ROOM_FULL")) {
        router.push(`/room/${c}`);
        return;
      }
      setError(readableError(e.message));
      return;
    }
    const d = data as { room_id: string; code: string; player_id: string; session_token: string; seat: number };
    saveSeat({ roomId: d.room_id, code: d.code, playerId: d.player_id, sessionToken: d.session_token, seat: d.seat });
    router.push(`/room/${d.code}`);
  }

  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-sm px-4 py-14">
        <h1 className="type-display text-[1.75rem]">Join a room</h1>
        <p className="mt-2 text-[0.9375rem] text-muted">
          Type the code your host sent. No account, no email.
        </p>

        <div className="mt-7 flex flex-col gap-5">
          <Field label="room code" htmlFor="code">
            <TextInput
              id="code"
              value={code}
              maxLength={6}
              autoCapitalize="characters"
              autoComplete="off"
              placeholder="XXXXXX"
              className="type-num text-center text-[1.75rem] tracking-[0.2em]"
              onChange={(e) => setCode(e.target.value.toUpperCase())}
            />
          </Field>

          <Field label="your name" htmlFor="name">
            <TextInput
              id="name"
              value={name}
              maxLength={24}
              placeholder="What should they call you?"
              onChange={(e) => setName(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") void go();
              }}
            />
          </Field>

          {error ? <p className="text-[0.875rem] text-coral">{error}</p> : null}

          <Button
            variant="primary"
            size="lg"
            disabled={busy || code.trim().length < 4 || !name.trim()}
            onClick={() => void go()}
          >
            {busy ? "Joining…" : "Take my seat"}
          </Button>
        </div>
      </main>
      <Footer />
    </>
  );
}
