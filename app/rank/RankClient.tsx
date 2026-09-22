"use client";

import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Footer, Header, SetupNotice } from "@/components/site/Chrome";
import { readableError } from "@/lib/game/errors";
import { saveLineupToken } from "@/lib/lineup/session";
import { supabaseBrowser, supabaseConfigured } from "@/lib/supabase/client";

export function RankClient() {
  if (!supabaseConfigured()) return <SetupNotice />;
  return <Rank />;
}

interface Shelf {
  id: string;
  name: string;
  item_count: number;
}
interface Quota {
  used: number;
  limit: number | null;
  unlimited: boolean;
  premium: boolean;
}

const SLOTS = 5;

function Rank() {
  const router = useRouter();
  const [shelf, setShelf] = useState<Shelf[]>([]);
  const [picked, setPicked] = useState<string | null>(null);
  const [quota, setQuota] = useState<Quota | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    void (async () => {
      const { data } = await supabaseBrowser().rpc("list_free_categories");
      // a lineup needs at least five PICTURED items, and a category with a
      // handful of entries makes a poor five-card run either way
      setShelf(((data as Shelf[]) ?? []).filter((c) => c.item_count >= SLOTS));
    })();
  }, []);

  useEffect(() => {
    void (async () => {
      try {
        const res = await fetch("/api/solo/key");
        const d = (await res.json()) as { key?: string };
        if (!d.key) return;
        const { data } = await supabaseBrowser().rpc("df20_solo_quota", { p_key: d.key });
        setQuota(data as Quota);
      } catch {
        /* the cap is enforced in the RPC; not showing it is cosmetic */
      }
    })();
  }, []);

  async function start() {
    if (!picked) return;
    setBusy(true);
    setError(null);
    try {
      const res = await fetch("/api/solo/key");
      const { key } = (await res.json()) as { key?: string };
      const { data, error: e } = await supabaseBrowser().rpc("create_lineup", {
        p_library_id: picked,
        p_solo_key: key ?? null,
        p_slots: SLOTS,
      });
      if (e) {
        setError(readableError(e.message));
        setBusy(false);
        return;
      }
      const d = data as { code: string; token: string };
      saveLineupToken(d.code, d.token);
      router.push(`/rank/${d.code}`);
    } catch {
      setError("Could not start. Try again.");
      setBusy(false);
    }
  }

  const out = Boolean(quota && !quota.unlimited && quota.limit !== null && quota.used >= quota.limit);

  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-2xl px-4 py-10">
        <h1 className="type-display text-[2rem]">Build the Lineup</h1>
        <p className="mt-2 max-w-lg text-[0.9375rem] leading-relaxed text-muted">
          Five cards, one at a time. Put each one in a slot &mdash; 1 is the best, 5 is the worst
          &mdash; before you are shown the next. Slots do not reopen, so every placement is a bet
          on what is still in the deck.
        </p>

        {quota && !quota.unlimited && quota.limit !== null ? (
          <p className="type-label mt-4 text-muted">
            {out ? (
              <span className="text-coral">
                that&apos;s your {quota.limit} for today &middot;{" "}
                <a className="text-gold" href="/pricing">
                  premium plays as much as it likes
                </a>
              </span>
            ) : (
              <>
                <span className="type-num text-ink">{quota.limit - quota.used}</span> of{" "}
                <span className="type-num">{quota.limit}</span> single-player games left today
              </>
            )}
          </p>
        ) : null}

        <h2 className="type-label mt-8 text-muted">pick a category</h2>
        <div className="mt-3 grid gap-2 sm:grid-cols-2">
          {shelf.length === 0 ? (
            <p className="type-label text-muted">loading the shelf</p>
          ) : (
            shelf.map((c) => (
              <button
                key={c.id}
                onClick={() => setPicked(c.id)}
                aria-pressed={picked === c.id}
                className={`flex items-baseline justify-between border px-4 py-3 text-left rule ${
                  picked === c.id ? "border-coral" : ""
                }`}
              >
                <span className="text-[0.9375rem] text-ink">{c.name}</span>
                <span className="type-num text-[0.75rem] text-muted">{c.item_count}</span>
              </button>
            ))
          )}
        </div>

        {error ? <p className="mt-4 text-[0.8125rem] text-coral">{error}</p> : null}

        <div className="mt-6">
          <Button
            variant="primary"
            size="lg"
            disabled={!picked || busy || out}
            onClick={() => void start()}
          >
            {busy ? "Dealing" : "Deal the first card"}
          </Button>
        </div>
      </main>
      <Footer />
    </>
  );
}
