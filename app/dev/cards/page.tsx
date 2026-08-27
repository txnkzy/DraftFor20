/**
 * DEV ONLY browser for the image cascade. DELETE BEFORE DEPLOY.
 *
 * Pick or type a category, see the whole deck with whatever picture each item
 * resolved to, and flip freeOnly to watch fair-use images fall back to
 * generated cards. The API it calls is itself guarded on NODE_ENV.
 */
"use client";

import { notFound } from "next/navigation";
import { useCallback, useEffect, useRef, useState } from "react";
import { BidBoard } from "@/components/board/BidBoard";
import { CardImage } from "@/components/board/CardImage";
import type { BoardView } from "@/lib/game/view";

const PRESETS = [
  // seeded library categories (0029/0031) — these come back from Postgres as
  // they will actually be dealt, not re-resolved through the live cascade
  "One Piece Characters",
  "Naruto Characters",
  "Demon Slayer Characters",
  "Jujutsu Kaisen Characters",
  "Dragon Ball Z Characters",
  "My Hero Academia Characters",
  // everything below is resolved live from Wikipedia
  "current NFL teams",
  "James Bond films",
  "Marvel Cinematic Universe films",
  "Premier League clubs",
  "national parks of the United States",
  "Pixar films",
  "Pokemon",
  "NFL teams",
];

interface Item {
  name: string;
  url: string | null;
  source: string;
  license: string;
}
interface Deck {
  query: string;
  article: string;
  freeOnly: boolean;
  items: Item[];
}

const players = [
  { id: "a", seat: 1, name: "Ari", bankrollCents: 2000, maxLegalBidCents: 1600,
    openSlots: 5, filled: 0, total: 5, isBroke: false, isHost: true, givesLeft: 2 },
  { id: "b", seat: 2, name: "Bo", bankrollCents: 2000, maxLegalBidCents: 1600,
    openSlots: 5, filled: 0, total: 5, isBroke: false, isHost: false, givesLeft: 2 },
];

function view(deck: Deck, item: Item): BoardView {
  return {
    title: deck.article, phase: "bidding", itemName: item.name, imageUrl: item.url,
    currentBidCents: 700, highBidderSeat: 1, onClockSeat: 2, openerSeat: 1,
    deckRemaining: deck.items.length - 1, startingCents: 2000, minBidCents: 100,
    timerSeconds: 30, noClock: false, fraction: 0.62, seconds: 18,
    urgent: false, critical: false, players, lotId: item.name, lastLock: null,
  };
}

export default function DevCards() {
  // An internal preview tool, and it was answering 200 in production. The
  // API behind it was already NODE_ENV-guarded; the page was not.
  if (process.env.NODE_ENV === "production") notFound();

  const [query, setQuery] = useState(PRESETS[0]);
  const [freeOnly, setFreeOnly] = useState(false);
  const [deck, setDeck] = useState<Deck | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [focus, setFocus] = useState<Item | null>(null);

  // client-side memo as well as the server's: switching back to a category
  // already on screen should not touch the network at all
  const cache = useRef(new Map<string, Deck>());
  const inflight = useRef(new Map<string, Promise<Deck>>());

  const get = useCallback((q: string, free: boolean): Promise<Deck> => {
    const key = `${free ? "free:" : "any:"}${q.toLowerCase()}`;
    const hit = cache.current.get(key);
    if (hit) return Promise.resolve(hit);
    const running = inflight.current.get(key);
    if (running) return running;

    const job = (async () => {
      const res = await fetch(`/api/dev/category?q=${encodeURIComponent(q)}&free=${free ? 1 : 0}`);
      const body = await res.json();
      if (!res.ok) throw new Error(body.message ?? `HTTP ${res.status}`);
      cache.current.set(key, body as Deck);
      return body as Deck;
    })();
    inflight.current.set(key, job);
    void job.catch(() => {}).finally(() => inflight.current.delete(key));
    return job;
  }, []);

  /** warm the cache without disturbing what is on screen */
  const prefetch = useCallback((q: string, free: boolean) => {
    void get(q, free).catch(() => {});
  }, [get]);

  const load = useCallback(
    async (q: string, free: boolean) => {
      setError(null);
      setFocus(null);
      const key = `${free ? "free:" : "any:"}${q.toLowerCase()}`;
      const cached = cache.current.get(key);
      if (cached) {
        setDeck(cached); // no spinner: this is synchronous from the user's side
        return;
      }
      setBusy(true);
      try {
        setDeck(await get(q, free));
      } catch (e) {
        setDeck(null);
        setError(e instanceof Error ? e.message : "failed");
      } finally {
        setBusy(false);
      }
    },
    [get],
  );

  useEffect(() => {
    void load(PRESETS[0], false);
  }, [load]);

  const stats = deck
    ? {
        n: deck.items.length,
        pic: deck.items.filter((i) => i.url).length,
        free: deck.items.filter((i) => i.license === "free").length,
        nonfree: deck.items.filter((i) => i.license === "nonfree").length,
        gen: deck.items.filter((i) => !i.url).length,
      }
    : null;

  return (
    <main style={{ padding: 24, maxWidth: 1500, margin: "0 auto" }}>
      <p className="type-label text-muted">image cascade browser &middot; dev only</p>

      {/* ── category picker ─────────────────────────────────────────────── */}
      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", margin: "14px 0" }}>
        {PRESETS.map((p) => (
          <button
            key={p}
            onClick={() => { setQuery(p); void load(p, freeOnly); }}
            onMouseEnter={() => prefetch(p, freeOnly)}
            onFocus={() => prefetch(p, freeOnly)}
            className="type-label"
            style={{
              padding: "7px 12px", borderRadius: 999, cursor: "pointer",
              border: `1px solid ${p === query ? "var(--color-coral)" : "var(--color-surface)"}`,
              background: p === query ? "var(--color-coral)" : "var(--color-surface)",
              color: p === query ? "#14161C" : "var(--color-ink)",
            }}
          >
            {p}
          </button>
        ))}
      </div>

      <form
        onSubmit={(e) => { e.preventDefault(); void load(query, freeOnly); }}
        style={{ display: "flex", gap: 8, alignItems: "center", marginBottom: 6 }}
      >
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="any category…"
          style={{
            flex: "0 1 380px", padding: "9px 12px", borderRadius: 8,
            border: "1px solid var(--color-surface)", background: "var(--color-surface)",
            color: "var(--color-ink)", fontSize: 14,
          }}
        />
        <button type="submit" className="type-label"
          style={{ padding: "9px 14px", borderRadius: 8, cursor: "pointer",
                   border: "1px solid var(--color-teal)", background: "transparent",
                   color: "var(--color-teal)" }}>
          resolve
        </button>
        <label className="type-label text-muted" style={{ display: "flex", gap: 6, cursor: "pointer" }}>
          <input type="checkbox" checked={freeOnly}
            onChange={(e) => { setFreeOnly(e.target.checked); void load(query, e.target.checked); }} />
          free licences only
        </label>
      </form>

      {busy ? <p className="text-muted" style={{ fontSize: 14 }}>resolving…</p> : null}
      {error ? <p style={{ color: "var(--color-coral)", fontSize: 14 }}>{error}</p> : null}

      {deck && stats ? (
        <>
          <h1 className="type-display" style={{ fontSize: 26, margin: "10px 0 2px" }}>
            {stats.n} options &middot; {stats.pic} with a picture (
            {Math.round((100 * stats.pic) / stats.n)}%)
          </h1>
          <p className="type-label text-muted" style={{ marginBottom: 18 }}>
            {deck.article} &nbsp;·&nbsp; free {stats.free} &nbsp;·&nbsp; non-free {stats.nonfree}
            &nbsp;·&nbsp; generated {stats.gen}
          </p>

          {/* ── click an item to see it on the real board ─────────────────── */}
          {focus ? (
            <div style={{ display: "flex", gap: 18, alignItems: "flex-start", marginBottom: 24 }}>
              <div style={{ width: 340 }}>
                <BidBoard view={view(deck, focus)} />
              </div>
              <div>
                <p className="type-label text-muted">selected</p>
                <p style={{ fontSize: 20, fontWeight: 700, margin: "4px 0" }}>{focus.name}</p>
                <p className="type-label text-muted">
                  {focus.source} &middot; {focus.license}
                </p>
                {focus.url ? (
                  <a href={focus.url} target="_blank" rel="noreferrer"
                     style={{ fontSize: 11, color: "var(--color-teal)", wordBreak: "break-all" }}>
                    {focus.url}
                  </a>
                ) : (
                  <p className="text-muted" style={{ fontSize: 12 }}>generated from the name</p>
                )}
                <button onClick={() => setFocus(null)} className="type-label"
                  style={{ marginTop: 10, padding: "6px 10px", borderRadius: 8, cursor: "pointer",
                           border: "1px solid var(--color-surface)", background: "transparent",
                           color: "var(--color-muted)" }}>
                  clear
                </button>
              </div>
            </div>
          ) : (
            <p className="type-label text-muted" style={{ marginBottom: 14 }}>
              click any card to see it on the board
            </p>
          )}

          <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(126px, 1fr))", gap: 14 }}>
            {deck.items.map((i) => (
              <button
                key={i.name}
                onClick={() => setFocus(i)}
                style={{
                  background: "none", border: "none", padding: 0, cursor: "pointer",
                  textAlign: "left", color: "inherit",
                  outline: focus?.name === i.name ? "2px solid var(--color-teal)" : "none",
                  outlineOffset: 3, borderRadius: 10,
                }}
              >
                <CardImage name={i.name} url={i.url} height={100} />
                <p style={{ fontSize: 12.5, fontWeight: 600, marginTop: 6, lineHeight: 1.15 }}>
                  {i.name}
                </p>
                <span className="type-label" style={{
                  fontSize: 9,
                  color: i.license === "nonfree" ? "var(--color-gold)"
                       : i.license === "free" ? "var(--color-teal)" : "var(--color-muted)",
                }}>
                  {i.license}
                </span>
              </button>
            ))}
          </div>
        </>
      ) : null}
    </main>
  );
}
