"use client";

import { useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Field, TextInput } from "@/components/ui/Field";
import { Footer, Header, SetupNotice } from "@/components/site/Chrome";
import { readableError } from "@/lib/game/errors";
import { centsToInput, formatCents, parseDollarsToCents } from "@/lib/money";
import { supabaseBrowser, supabaseConfigured } from "@/lib/supabase/client";

const RESULT_KEY = (code: string) => `df20:setupresult:${code}`;

export function SetupClient({ token }: { token: string }) {
  if (!supabaseConfigured()) return <SetupNotice />;
  return <Setup token={token} />;
}

interface Locked {
  code: string;
  itemCount: number;
}

function Setup({ token }: { token: string }) {
  const sb = supabaseBrowser();
  const [status, setStatus] = useState<"loading" | "open" | "gone" | "expired">("loading");
  const [category, setCategory] = useState("");
  const [raw, setRaw] = useState("");
  const [rosterSize, setRosterSize] = useState(5);
  const [bankroll, setBankroll] = useState("20");
  const [minBid, setMinBid] = useState("1");
  const [timer, setTimer] = useState(15);
  const [gives, setGives] = useState(2);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [locked, setLocked] = useState<Locked | null>(null);

  useEffect(() => {
    let off = false;
    void (async () => {
      const { data } = await sb.rpc("get_setup_state", { p_setup_token: token });
      if (off) return;
      const s = (data as { status?: string } | null)?.status;
      if (s === "open") {
        const d = data as Record<string, number>;
        setRosterSize(d.roster_size ?? 5);
        setBankroll(centsToInput(d.bankroll_cents ?? 2000));
        setMinBid(centsToInput(d.min_bid_cents ?? 100));
        setTimer(d.timer_seconds ?? 15);
        setGives(d.gives_per_player ?? 2);
        setStatus("open");
      } else if (s === "expired") setStatus("expired");
      else setStatus("gone");
    })();
    return () => {
      off = true;
    };
  }, [sb, token]);

  // parsed here in the browser and sent once. The server never sends it back.
  const items = raw
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean);
  const dupes = items.length - new Set(items.map((i) => i.toLowerCase())).size;
  const need = rosterSize * 2;
  const ready =
    category.trim().length > 0 && items.length >= need && dupes === 0 && !busy;

  const lock = useCallback(async () => {
    setBusy(true);
    setError(null);
    const { data, error: e } = await sb.rpc("setup_lock_items", {
      p_setup_token: token,
      p_category: category.trim(),
      p_items: items,
      p_roster_size: rosterSize,
      p_bankroll_cents: parseDollarsToCents(bankroll) ?? 2000,
      p_min_bid_cents: parseDollarsToCents(minBid) ?? 100,
      p_timer_seconds: timer,
      p_gives_per_player: gives,
    });
    setBusy(false);
    if (e) {
      setError(readableError(e.message));
      return;
    }
    const d = data as { code: string; item_count: number; setup_result_token: string };
    try {
      localStorage.setItem(RESULT_KEY(d.code), d.setup_result_token);
    } catch {
      /* private browsing: they just will not get the opt-in prompt later */
    }
    setLocked({ code: d.code, itemCount: d.item_count });
  }, [sb, token, category, items, rosterSize, bankroll, minBid, timer, gives]);

  if (status === "loading") {
    return (
      <>
        <Header thin />
        <main className="mx-auto w-full max-w-xl px-4 py-14">
          <h1 className="type-display text-[1.75rem]">Build the list</h1>
          <p className="type-label mt-2 text-muted">loading</p>
        </main>
      </>
    );
  }

  if (status !== "open" && !locked) {
    return (
      <>
        <Header thin />
        <main className="mx-auto w-full max-w-xl px-4 py-14">
          <h1 className="type-display text-[1.75rem]">
            {status === "expired" ? "This link expired" : "This link is used up"}
          </h1>
          <p className="mt-3 text-[0.9375rem] leading-relaxed text-muted">
            {status === "expired"
              ? "Setup links last 24 hours. Ask whoever sent it to start a new one."
              : "The list for this room is already locked in. Setup links only work once, on purpose, so nobody can reopen one to read the list before the draft."}
          </p>
        </main>
        <Footer />
      </>
    );
  }

  if (locked) {
    return (
      <>
        <Header thin />
        <main className="mx-auto w-full max-w-xl px-4 py-14">
          <p className="type-label text-teal">locked in</p>
          <h1 className="type-display mt-2 text-[1.75rem]">{category}</h1>
          <p className="mt-3 text-[0.9375rem] leading-relaxed text-muted">
            {locked.itemCount} items are sealed in. You can&apos;t see them again and neither can
            the players until they&apos;re dealt one at a time.
          </p>
          <div className="mt-7 border p-5 rule">
            <p className="type-label text-muted">send this to the two players</p>
            <p className="type-num mt-2 text-[2.25rem] leading-none text-gold">{locked.code}</p>
            <CopyButton code={locked.code} />
          </div>
          <p className="mt-6 text-[0.8125rem] leading-relaxed text-muted">
            Keep this tab. When the draft finishes you&apos;ll be asked, once, whether to share
            this category with other hosts. It&apos;s off by default.
          </p>
        </main>
        <Footer />
      </>
    );
  }

  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-xl px-4 py-10">
        <h1 className="type-display text-[1.75rem]">Build the list</h1>
        <p className="mt-2 text-[0.9375rem] leading-relaxed text-muted">
          You&apos;re setting up someone else&apos;s draft. Neither player sees this page or the
          list. Once you lock it in, this link stops working, including for you.
        </p>

        <div className="mt-8 flex flex-col gap-6">
          <Field label="category name" htmlFor="cat">
            <TextInput
              id="cat"
              value={category}
              maxLength={60}
              placeholder="Cereal brands"
              onChange={(e) => setCategory(e.target.value)}
            />
          </Field>

          <div className="flex flex-col gap-1.5">
            <label htmlFor="items" className="type-label text-muted">
              items &middot; one per line
            </label>
            <textarea
              id="items"
              value={raw}
              rows={12}
              spellCheck={false}
              placeholder={"Lucky Charms\nCheerios\nFrosted Flakes"}
              onChange={(e) => setRaw(e.target.value)}
              className="field font-mono text-[0.875rem]"
            />
            <p className="type-num text-[0.75rem] text-muted">
              {items.length} items &middot; need at least {need} for a {rosterSize}-player roster
              {dupes > 0 ? (
                <span className="text-coral"> &middot; {dupes} duplicate{dupes > 1 ? "s" : ""}</span>
              ) : null}
            </p>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <Field label="roster size each">
              <TextInput
                inputMode="numeric"
                className="type-num"
                value={String(rosterSize)}
                onChange={(e) => setRosterSize(Math.max(1, Math.min(30, Number(e.target.value) || 1)))}
              />
            </Field>
            <Field label="bankroll each">
              <TextInput
                inputMode="decimal"
                className="type-num"
                value={bankroll}
                onChange={(e) => setBankroll(e.target.value)}
              />
            </Field>
            <Field label="minimum bid">
              <TextInput
                inputMode="decimal"
                className="type-num"
                value={minBid}
                onChange={(e) => setMinBid(e.target.value)}
              />
            </Field>
            <Field label="free gives each" hint="handing a card to the other player">
              <TextInput
                inputMode="numeric"
                className="type-num"
                value={String(gives)}
                onChange={(e) => setGives(Math.max(0, Math.min(30, Number(e.target.value) || 0)))}
              />
            </Field>
          </div>

          <div className="flex flex-col gap-2">
            <span className="type-label text-muted">counter-bid clock</span>
            <div className="flex gap-1.5">
              {[10, 15, 20, 30].map((t) => (
                <button
                  key={t}
                  className={`type-num flex-1 border py-2.5 text-[0.9375rem] ${
                    timer === t ? "border-coral text-coral" : "text-muted rule hover:text-ink"
                  }`}
                  onClick={() => setTimer(t)}
                >
                  {t}s
                </button>
              ))}
            </div>
          </div>

          {error ? <p className="text-[0.875rem] text-coral">{error}</p> : null}

          <Button variant="primary" size="lg" disabled={!ready} onClick={() => void lock()}>
            {busy ? "Locking in…" : `Lock in ${items.length} items`}
          </Button>
          <p className="text-[0.75rem] leading-relaxed text-muted">
            Locking in is final. The list is sealed, this link dies, and you get a room code to
            send to the players. Minimum bid is {formatCents(parseDollarsToCents(minBid) ?? 100)}.
          </p>
        </div>
      </main>
      <Footer />
    </>
  );
}

function CopyButton({ code }: { code: string }) {
  const [done, setDone] = useState(false);
  return (
    <button
      className="type-label mt-3 text-muted hover:text-ink"
      onClick={() => {
        void navigator.clipboard
          .writeText(`${window.location.origin}/room/${code}`)
          .then(() => {
            setDone(true);
            setTimeout(() => setDone(false), 1600);
          })
          .catch(() => undefined);
      }}
    >
      {done ? "link copied" : "copy the player link"}
    </button>
  );
}
