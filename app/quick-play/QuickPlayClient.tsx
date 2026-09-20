"use client";

import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Field, TextInput } from "@/components/ui/Field";
import { Footer, Header, SetupNotice } from "@/components/site/Chrome";
import { readableError } from "@/lib/game/errors";
import { saveSeat } from "@/lib/game/session";
import { supabaseBrowser, supabaseConfigured } from "@/lib/supabase/client";

export function QuickPlayClient() {
  if (!supabaseConfigured()) return <SetupNotice />;
  return <QuickPlay />;
}

interface Shelf { id: string; name: string; item_count: number }

function QuickPlay() {
  const router = useRouter();
  const [name, setName] = useState("");
  const [nameError, setNameError] = useState<string | null>(null);
  const [shelf, setShelf] = useState<Shelf[]>([]);
  const [picked, setPicked] = useState<string | null>(null);
  const [roster, setRoster] = useState(5);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [quota, setQuota] = useState<
    { used: number; limit: number | null; unlimited: boolean; premium: boolean } | null
  >(null);

  useEffect(() => {
    void (async () => {
      const { data } = await supabaseBrowser().rpc("list_free_categories");
      setShelf((data as Shelf[]) ?? []);
    })();
  }, []);

  /* The device key is issued and stored by the server in an httpOnly cookie;
     this only reads back which one we hold so the quota can be shown before
     the button is pressed. Being told you are out of games after filling in
     the form is worse than being told before. */
  useEffect(() => {
    void (async () => {
      try {
        const res = await fetch("/api/solo/key");
        const d = (await res.json()) as { key?: string };
        if (!d.key) return;
        const { data } = await supabaseBrowser().rpc("df20_solo_quota", { p_key: d.key });
        setQuota(data as typeof quota);
      } catch {
        /* no quota shown is fine: create_solo_room still enforces it */
      }
    })();
  }, []);

  // same PG check the join form runs, so a refused name is refused here too
  useEffect(() => {
    const n = name.trim();
    let cancelled = false;
    const t = setTimeout(() => {
      if (!n) { setNameError(null); return; }
      void (async () => {
        const { data } = await supabaseBrowser().rpc("check_display_name", {
          p_code: "", p_name: n,
        });
        if (cancelled) return;
        const d = data as { ok: boolean; reason?: string } | null;
        setNameError(!d || d.ok ? null : readableError(d.reason ?? ""));
      })();
    }, 400);
    return () => { cancelled = true; clearTimeout(t); };
  }, [name]);

  async function go() {
    if (!name.trim() || nameError) return;
    setBusy(true);
    setError(null);
    /* Through the route, not the RPC: the device key the cap counts against
       has to be stamped server-side, or omitting it is a free bypass. */
    const {
      data: { session },
    } = await supabaseBrowser().auth.getSession();
    const res = await fetch("/api/solo/create", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(session ? { Authorization: `Bearer ${session.access_token}` } : {}),
      },
      body: JSON.stringify({
        hostName: name.trim(),
        poolSource: picked ? "library" : "builtin",
        poolRef: picked,
        rosterSize: roster,
        timerSeconds: 20,
      }),
    });
    const payload = (await res.json()) as Record<string, unknown>;
    setBusy(false);
    if (!res.ok) {
      setError(readableError(String(payload.message ?? "")));
      return;
    }
    const d = payload as unknown as {
      room_id: string; code: string; player_id: string;
      session_token: string; seat: number; bot_name: string;
    };
    saveSeat({
      roomId: d.room_id, code: d.code, playerId: d.player_id,
      sessionToken: d.session_token, seat: d.seat,
    });
    router.push(`/room/${d.code}`);
  }

  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-sm px-4 py-12">
        <h1 className="type-display text-[1.75rem]">Quick Play</h1>
        <p className="mt-2 text-[0.9375rem] leading-relaxed text-muted">
          One draft against DraftFor20Bot. No second player, no waiting, no
          account — about ten minutes.
        </p>

        {quota && !quota.unlimited && quota.limit !== null ? (
          <p className="mt-3 border px-3 py-2 text-[0.8125rem] leading-relaxed text-muted rule">
            {quota.used >= quota.limit ? (
              <>
                <span className="type-label text-coral">that&rsquo;s today&rsquo;s three</span>{" "}
                Solo drafts reset at midnight. Two-player rooms are unlimited and
                always free —{" "}
                <a href="/new" className="text-ink underline">start one</a>. Premium
                removes the cap:{" "}
                <a href="/pricing" className="text-ink underline">see pricing</a>.
              </>
            ) : (
              <>
                <span className="type-label text-gold">
                  {quota.limit - quota.used} of {quota.limit} left today
                </span>{" "}
                Solo drafts are capped on the free tier. Playing someone else is
                unlimited.
              </>
            )}
          </p>
        ) : null}

        <div className="mt-7 flex flex-col gap-5">
          <Field
            label="your name"
            htmlFor="qp-name"
            hint={nameError ? <span className="text-coral">{nameError}</span> : null}
          >
            <TextInput
              id="qp-name"
              value={name}
              maxLength={24}
              aria-invalid={nameError ? true : undefined}
              placeholder="What should it call you?"
              onChange={(e) => setName(e.target.value)}
              onKeyDown={(e) => { if (e.key === "Enter") void go(); }}
            />
          </Field>

          <div className="flex flex-col gap-2">
            <span className="type-label text-muted">roster size</span>
            <div className="flex gap-1.5">
              {[3, 5, 8].map((n) => (
                <button
                  key={n}
                  onClick={() => setRoster(n)}
                  className={`type-label flex-1 border py-2.5 ${
                    roster === n ? "border-coral text-coral" : "text-muted rule hover:text-ink"
                  }`}
                >
                  {n} picks
                </button>
              ))}
            </div>
          </div>

          <div className="flex flex-col gap-2">
            <span className="type-label text-muted">category</span>
            <div className="flex max-h-52 flex-col overflow-y-auto">
              <button
                onClick={() => setPicked(null)}
                className={`border-b py-2 text-left text-[0.875rem] rule ${
                  picked === null ? "text-coral" : "text-muted hover:text-ink"
                }`}
              >
                Surprise me
              </button>
              {shelf.map((c) => (
                <button
                  key={c.id}
                  onClick={() => setPicked(c.id)}
                  className={`flex items-baseline gap-3 border-b py-2 text-left text-[0.875rem] rule ${
                    picked === c.id ? "text-coral" : "text-muted hover:text-ink"
                  }`}
                >
                  <span>{c.name}</span>
                  <span className="type-label ml-auto text-gold">{c.item_count}</span>
                </button>
              ))}
            </div>
          </div>

          {error ? <p className="text-[0.875rem] text-coral">{error}</p> : null}

          <Button
            variant="primary"
            size="lg"
            disabled={
              busy || !name.trim() || !!nameError ||
              Boolean(quota && !quota.unlimited && quota.limit !== null &&
                      quota.used >= quota.limit)
            }
            onClick={() => void go()}
          >
            {busy ? "Dealing…" : "Play DraftFor20Bot"}
          </Button>
        </div>
      </main>
      <Footer />
    </>
  );
}
