"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useMemo, useState } from "react";
import { Button } from "@/components/ui/Button";
import { Field, TextInput } from "@/components/ui/Field";
import { Footer, Header, SetupNotice } from "@/components/site/Chrome";
import { readableError } from "@/lib/game/errors";
import { isUnderfunded } from "@/lib/game/rules";
import { saveSeat } from "@/lib/game/session";
import { solvePow } from "@/lib/pow";
import { accessToken, signInHref, signUpHref, useHost } from "@/lib/auth";
import { usePremium } from "@/lib/premium";
import { Padlock } from "@/components/premium/Padlock";
import { UpgradeCard } from "@/components/premium/UpgradeCard";
import { UpgradeDialog, useUpgradeDialog } from "@/components/premium/UpgradeDialog";
import { centsToInput, formatCents, parseDollarsToCents } from "@/lib/money";
import { supabaseBrowser, supabaseConfigured } from "@/lib/supabase/client";

interface Saved {
  id: string;
  name: string;
  default_roster_size: number;
  default_bankroll_cents: number;
  default_min_bid_cents: number;
  default_timer_seconds: number;
  default_gives_per_player: number;
}

/** A shelf category. `genre` comes from list_free_categories (0032). */
interface Cat {
  id: string;
  name: string;
  item_count: number;
  genre?: string;
}

/**
 * Genres in the order a person would look for them, not alphabetically —
 * sports and the screen categories first because that is what most people
 * come for. Anything the server reports that is not listed here still shows,
 * appended after these, so a new genre needs no UI change.
 */
const GENRE_ORDER = ["sports", "movies", "tv", "anime", "comics", "games", "music", "food", "other"];

const GENRE_LABEL: Record<string, string> = {
  sports: "Sports",
  movies: "Movies",
  tv: "TV",
  anime: "Anime",
  comics: "Comics",
  games: "Games",
  music: "Music",
  food: "Food",
  other: "Other",
};

export function NewRoomClient() {
  if (!supabaseConfigured()) return <SetupNotice />;
  return <NewRoom />;
}

function NewRoom() {
  const router = useRouter();
  const sb = supabaseBrowser();

  const [title, setTitle] = useState("NFL Players");
  const [hostName, setHostName] = useState("");
  const [rosterSize, setRosterSize] = useState(5);
  const [bankroll, setBankroll] = useState("20");
  const [minBid, setMinBid] = useState("1");
  const [timer, setTimer] = useState(15);
  const [customClock, setCustomClock] = useState(false);
  const [contentMode, setContentMode] = useState<"standard" | "creator">("standard");
  const [gives, setGives] = useState(2);
  const [isPrivate, setIsPrivate] = useState(true);
  const [accent, setAccent] = useState("");
  const [logo, setLogo] = useState("");

  // which route to a pool the host is taking
  const [mode, setMode] = useState<"free" | "auto" | "handoff" | "deck">("free");
  const [decks, setDecks] = useState<{ id: string; name: string; item_count: number }[]>([]);
  const [deck, setDeck] = useState<string | null>(null);
  const [shelf, setShelf] = useState<Cat[]>([]);
  const [picked, setPicked] = useState<Cat | null>(null);
  // "all" is a real value, not a null: the shelf must have a way back to
  // unfiltered without special-casing every read of it
  const [genre, setGenre] = useState<string>("all");
  const [query, setQuery] = useState("");
  const [match, setMatch] = useState<{
    source: string; sourceId: string; matchedName: string; itemCount: number;
  } | null>(null);
  const [looking, setLooking] = useState(false);
  const [noMatch, setNoMatch] = useState(false);
  const [setupLink, setSetupLink] = useState<string | null>(null);

  const { user } = useHost();
  const signedIn = Boolean(user);
  const premium = usePremium();
  const premiumActive = premium.active;
  const upgrade = useUpgradeDialog();
  const [saved, setSaved] = useState<Saved[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    void (async () => {
      const { data } = await sb.auth.getUser();
      if (!data.user) return;
      const { data: rows } = await sb
        .from("templates")
        .select("id,name,default_roster_size,default_bankroll_cents,default_min_bid_cents,default_timer_seconds,default_gives_per_player")
        .order("created_at", { ascending: false });
      setSaved((rows as Saved[]) ?? []);
      const { data: myDecks } = await sb.rpc("my_decks");
      const list = (myDecks as { id: string; name: string; item_count: number }[]) ?? [];
      setDecks(list);
      // arriving from "deal from this" on the profile page
      const wanted = new URLSearchParams(window.location.search).get("deck");
      const hit = wanted ? list.find((d) => d.id === wanted) : null;
      if (hit) {
        setMode("deck");
        setDeck(hit.id);
        setTitle(hit.name);
      }
      const { data: profile } = await sb
        .from("profiles")
        .select("display_name,brand_accent,brand_logo_url")
        .eq("id", data.user.id)
        .maybeSingle();
      if (profile) {
        if (profile.display_name) setHostName(profile.display_name);
        if (profile.brand_accent) setAccent(profile.brand_accent);
        if (profile.brand_logo_url) setLogo(profile.brand_logo_url);
      }
    })();
  }, [sb]);

  useEffect(() => {
    let off = false;
    void (async () => {
      const { data } = await sb.rpc("list_free_categories");
      if (off) return;
      const list = (data as Cat[]) ?? [];
      setShelf(list);
      const want = new URLSearchParams(window.location.search).get("mode");
      if (want === "auto" || want === "handoff" || want === "deck") setMode(want);
      // NFL Players is the landing default rather than Football Draft: it is
      // current, curated to players people actually recognise, and every card
      // carries a photograph. Football Draft is 268 text-only names and stays
      // on the shelf. The chain still degrades if a category is ever renamed.
      const fb =
        list.find((c) => c.name === "NFL Players") ??
        list.find((c) => c.name === "Football Draft") ??
        list[0] ??
        null;
      setPicked(fb);
      if (fb) setTitle(fb.name);
    })();
    return () => { off = true; };
  }, [sb]);

  /** genres actually present on the shelf, with counts, in reading order */
  const genres = useMemo(() => {
    const counts = new Map<string, number>();
    for (const c of shelf) {
      const g = c.genre ?? "other";
      counts.set(g, (counts.get(g) ?? 0) + 1);
    }
    const known = GENRE_ORDER.filter((g) => counts.has(g));
    // a genre the server knows about but this build does not still appears
    const extra = [...counts.keys()].filter((g) => !GENRE_ORDER.includes(g)).sort();
    return [...known, ...extra].map((g) => ({ g, n: counts.get(g) ?? 0 }));
  }, [shelf]);

  const visible = useMemo(
    () => (genre === "all" ? shelf : shelf.filter((c) => (c.genre ?? "other") === genre)),
    [shelf, genre],
  );

  // Rolls within what is on screen. Rolling into a category the filter is
  // hiding would look like a bug, not a surprise.
  function rollRandom() {
    const pool = visible.length > 0 ? visible : shelf;
    if (pool.length === 0) return;
    let next = pool[Math.floor(Math.random() * pool.length)];
    // don't hand back the same one twice running
    if (pool.length > 1 && picked && next.id === picked.id) {
      next = pool[(pool.indexOf(next) + 1 + Math.floor(Math.random() * (pool.length - 1))) % pool.length];
    }
    setPicked(next);
    setTitle(next.name);
  }

  const bankrollCents = parseDollarsToCents(bankroll) ?? 0;
  const minBidCents = parseDollarsToCents(minBid) ?? 0;
  const underfunded = isUnderfunded(bankrollCents, minBidCents, rosterSize);
  const clockOk = timer === 0 || (timer >= 3 && timer <= 300);
  // the server refuses this too; the button just says so first
  const modeOk = contentMode === "standard" || premium.active;
  const ready =
    hostName.trim().length > 0 && !busy && clockOk && modeOk &&
    (mode === "free"
      ? picked !== null
      : mode === "deck"
        ? deck !== null
        : mode !== "auto" || match !== null);

  async function lookUp() {
    setLooking(true);
    setMatch(null);
    setNoMatch(false);
    setError(null);
    try {
      const token = await accessToken();
      const res = await fetch("/api/category/resolve", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          ...(token ? { authorization: `Bearer ${token}` } : {}),
        },
        body: JSON.stringify({ query: query.trim(), rosterSize }),
      });
      const d = await res.json();
      if (!res.ok) {
        setError(
          d?.message === "DF20_RATE_LIMITED"
            ? "That's a lot of lookups. Try again in a bit, or build the list by hand."
            : (d?.message ?? "Lookup failed."),
        );
      } else if (!d.source) {
        setNoMatch(true);
      } else {
        setMatch(d);
        setTitle(d.matchedName);
      }
    } catch {
      setError("Lookup failed.");
    }
    setLooking(false);
  }

  async function startHandoff() {
    setBusy(true);
    setError(null);
    // token sent explicitly; see app/api/setup/create/route.ts for why
    const token = await accessToken();
    const res = await fetch("/api/setup/create", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify({ contentMode }),
    });
    const data = await res.json().catch(() => ({}));
    setBusy(false);
    if (!res.ok) {
      setError(readableError(data?.message));
      return;
    }
    const d = data as { setup_token: string };
    setSetupLink(`${window.location.origin}/setup/${d.setup_token}`);
  }

  async function create() {
    setBusy(true);
    setError(null);
    // one quick proof of work so a script cannot flood rooms; ~100ms here
    const { challenge, nonce } = await solvePow();
    const authToken = await accessToken();
    const res = await fetch("/api/rooms", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(authToken ? { authorization: `Bearer ${authToken}` } : {}),
      },
      body: JSON.stringify({
        challenge, nonce,
        title: title.trim() || "Football Draft",
        rosterSize, bankrollCents, minBidCents,
        timerSeconds: timer, hostName: hostName.trim(),
        isPrivate, givesPerPlayer: gives,
        contentMode,
        poolSource:
          mode === "auto" && match ? match.source : mode === "deck" ? "saved" : "library",
        poolRef:
          mode === "auto" && match ? match.sourceId : mode === "deck" ? deck : (picked?.id ?? null),
        brandAccent: accent.trim() || null,
        brandLogoUrl: logo.trim() || null,
      }),
    });
    const data = await res.json();
    setBusy(false);
    if (!res.ok) {
      setError(
        data?.message === "DF20_RATE_LIMITED"
          ? "That's a lot of rooms in a short time. Give it a few minutes."
          : readableError(data?.message),
      );
      return;
    }
    const d = data as { room_id: string; code: string; player_id: string; session_token: string; seat: number };
    saveSeat({ roomId: d.room_id, code: d.code, playerId: d.player_id, sessionToken: d.session_token, seat: d.seat });
    router.push(`/room/${d.code}`);
  }

  return (
    <>
      <Header thin />
      <main className="mx-auto w-full max-w-xl px-4 py-8">
        <h1 className="type-display text-[1.875rem]">Start a room</h1>
        <p className="mt-2 text-[0.9375rem] text-muted">
          You get a code to send. The deck deals the picks, so neither player ever sees what is
          coming.
        </p>

        <div className="mt-7 flex flex-col gap-3">
          <span className="type-label text-muted">where do the picks come from</span>
          {(
            [
              ["free", "Pick a category", `${shelf.length} ready to play. Free.`, false],
              ["auto", "Type your own", "Any category you can name. We find the list; you never see it.", true],
              ["handoff", "Someone else builds it", "Send a setup link to a third person. Neither player sees the list.", true],
              ["deck", "One of your saved decks", "A category you kept from an earlier draft. Reshuffled, still hidden.", true],
            ] as const
          ).map(([m, label, blurb, premium_]) => (
            <button
              key={m}
              onClick={() => {
                // free is the shelf; the other three are premium and say so
                if (m !== "free" && !premium.active) {
                  upgrade.ask(
                    m === "auto"
                      ? "Type your own category"
                      : m === "handoff"
                        ? "Have someone else build the list"
                        : "Reuse a saved deck",
                    m === "auto"
                      ? "Name any category and we find the list for you — neither player ever sees it."
                      : m === "handoff"
                        ? "Send a setup link to a third person so neither player knows what is coming."
                        : "Deal again from a category you kept, reshuffled and still hidden.",
                  );
                  return;
                }
                setMode(m); setMatch(null); setNoMatch(false);
              }}
              className={`border p-3 text-left ${mode === m ? "border-coral" : "rule hover:border-ink"}`}
            >
              <span className="flex items-baseline gap-2">
                <span className={`type-label ${mode === m ? "text-coral" : "text-ink"}`}>{label}</span>
                {premium_ && !premiumActive ? (
                  <span className="type-label flex items-center gap-1 text-muted">
                    <Padlock size={11} /> premium
                  </span>
                ) : null}
              </span>
              <span className="mt-1 block text-[0.8125rem] leading-snug text-muted">{blurb}</span>
            </button>
          ))}
        </div>

        {mode === "free" ? (
          <div className="mt-6 flex flex-col gap-3">
            <div className="flex items-center justify-between gap-3">
              <span className="type-label text-muted">the shelf</span>
              <Button variant="ghost" size="sm" disabled={shelf.length === 0} onClick={rollRandom}>
                Random
              </Button>
            </div>
            {/* genre filter. Only worth drawing once there is more than one
                genre to choose between. */}
            {genres.length > 1 ? (
              <div className="mb-2.5 flex flex-wrap items-center gap-1.5">
                <button
                  onClick={() => setGenre("all")}
                  className={`type-label border px-2.5 py-1 ${
                    genre === "all" ? "border-teal text-teal" : "text-muted rule hover:text-ink"
                  }`}
                >
                  All {shelf.length}
                </button>
                {genres.map(({ g, n }) => (
                  <button
                    key={g}
                    onClick={() => setGenre(g)}
                    className={`type-label border px-2.5 py-1 ${
                      genre === g ? "border-teal text-teal" : "text-muted rule hover:text-ink"
                    }`}
                  >
                    {GENRE_LABEL[g] ?? g} {n}
                  </button>
                ))}
              </div>
            ) : null}

            <div className="flex flex-wrap gap-1.5">
              {visible.map((c) => (
                <button
                  key={c.id}
                  onClick={() => { setPicked(c); setTitle(c.name); }}
                  className={`type-label border px-2.5 py-1.5 ${
                    picked?.id === c.id ? "border-coral text-coral" : "text-muted rule hover:text-ink"
                  }`}
                >
                  {c.name}
                </button>
              ))}
              {shelf.length === 0 ? (
                <span className="text-[0.8125rem] text-muted">loading categories…</span>
              ) : null}
            </div>

            {/* the pick survives a filter that hides it, so say so rather than
                leaving the summary line below referring to nothing on screen */}
            {picked && genre !== "all" && !visible.some((c) => c.id === picked.id) ? (
              <p className="type-label mt-2 text-muted">
                still picked: <span className="text-coral">{picked.name}</span> (in{" "}
                {GENRE_LABEL[picked.genre ?? "other"] ?? picked.genre})
              </p>
            ) : null}
            {picked ? (
              <p className="type-num text-[0.75rem] text-muted">
                {picked.name} &middot; {picked.item_count} possible picks &middot; you won&apos;t see
                them until they&apos;re dealt
              </p>
            ) : null}
          </div>
        ) : null}

        {(mode === "auto" || mode === "handoff" || mode === "deck") && !signedIn ? (
          <div className="mt-6 border border-teal p-4">
            <p className="type-label text-teal">custom categories need an account</p>
            <p className="mt-2 text-[0.875rem] leading-relaxed text-muted">
              Free to make, and it keeps your saved setups and card branding between drafts.
              Football Draft and the {shelf.length} categories on the shelf stay free without one.
            </p>
            <div className="mt-4 flex flex-wrap gap-2">
              <Link
                href={signUpHref(`/new?mode=${mode}`)}
                className="btn btn-primary h-11 px-4 text-[0.8125rem]"
              >
                Create an account
              </Link>
              <Link
                href={signInHref(`/new?mode=${mode}`)}
                className="btn btn-ghost h-11 px-4 text-[0.8125rem]"
              >
                I already have one
              </Link>
            </div>
          </div>
        ) : null}

        {mode === "handoff" && signedIn ? (
          <div className="mt-6 flex flex-col gap-3">
            {setupLink ? (
              <div className="border p-4 rule">
                <p className="type-label text-teal">setup link ready</p>
                <p className="mt-2 break-all font-mono text-[0.8125rem] text-ink">{setupLink}</p>
                <button
                  className="type-label mt-3 text-muted hover:text-ink"
                  onClick={() => void navigator.clipboard.writeText(setupLink).catch(() => undefined)}
                >
                  copy it
                </button>
                <p className="mt-3 text-[0.8125rem] leading-relaxed text-muted">
                  Send this to whoever is building the list. They set the category, the items and
                  the numbers, and get a room code back for the two of you. Don&apos;t open it
                  yourself if you&apos;re playing. It expires in 24 hours and works once.
                </p>
              </div>
            ) : (
              <>
                <p className="text-[0.875rem] leading-relaxed text-muted">
                  This makes a room with no list yet. You&apos;ll get a link to hand to a third
                  person, who builds the category and sends you back a room code.
                </p>
                <Button variant="primary" size="lg" disabled={busy} onClick={() => void startHandoff()}>
                  {busy ? "Creating…" : "Get a setup link"}
                </Button>
                {error ? <p className="text-[0.875rem] text-coral">{error}</p> : null}
              </>
            )}
          </div>
        ) : null}

        {mode === "deck" && signedIn ? (
          <div className="mt-6 flex flex-col gap-3">
            <span className="type-label text-muted">your decks</span>
            {decks.length === 0 ? (
              <p className="text-[0.875rem] leading-relaxed text-muted">
                Nothing saved yet. At the end of a draft you host, choose &ldquo;save this
                deck&rdquo; and the category comes back here for next time.
              </p>
            ) : (
              <div className="flex flex-wrap gap-1.5">
                {decks.map((d) => (
                  <button
                    key={d.id}
                    onClick={() => { setDeck(d.id); setTitle(d.name); }}
                    className={`type-label border px-2.5 py-1.5 ${
                      deck === d.id ? "border-coral text-coral" : "text-muted rule hover:text-ink"
                    }`}
                  >
                    {d.name}
                    <span className="type-num ml-2 text-muted">{d.item_count}</span>
                  </button>
                ))}
              </div>
            )}
            {deck ? (
              <p className="type-num text-[0.75rem] text-muted">
                dealt fresh from your saved list &middot; you still won&apos;t see it until the
                cards come up
              </p>
            ) : null}
          </div>
        ) : null}

        {mode === "auto" && signedIn ? (
          <div className="mt-6 flex flex-col gap-3">
            <Field label="category" hint="e.g. cereal brands, James Bond films, national parks">
              <div className="flex gap-2">
                <TextInput
                  value={query}
                  maxLength={80}
                  placeholder="Type a category"
                  onChange={(e) => { setQuery(e.target.value); setMatch(null); setNoMatch(false); }}
                  onKeyDown={(e) => { if (e.key === "Enter") void lookUp(); }}
                />
                <Button
                  variant="ghost"
                  className="shrink-0"
                  disabled={looking || query.trim().length < 2}
                  onClick={() => void lookUp()}
                >
                  {looking ? "Looking…" : "Look up"}
                </Button>
              </div>
            </Field>

            {match ? (
              <div className="border border-teal p-4">
                <p className="type-label text-teal">
                  matched &middot; {match.source === "library" ? "shared library" : "wikipedia"}
                </p>
                <p className="type-display mt-1 text-[1.0625rem]">{match.matchedName}</p>
                <p className="type-num mt-1 text-[0.8125rem] text-muted">
                  {match.itemCount} items &middot; you won&apos;t see them
                </p>
                <button
                  className="type-label mt-3 text-muted hover:text-ink"
                  onClick={() => { setMatch(null); setNoMatch(false); }}
                >
                  try different wording
                </button>
              </div>
            ) : null}

            {noMatch ? (
              <div className="border border-coral p-4">
                <p className="type-label text-coral">no automatic match</p>
                <p className="mt-1 text-[0.875rem] leading-relaxed text-muted">
                  Nothing in the library and nothing usable on Wikipedia for that. Try different
                  wording, or switch to &ldquo;someone else builds it&rdquo; and have a third
                  person type the list.
                </p>
              </div>
            ) : null}
          </div>
        ) : null}

        {/* ── how the board looks ───────────────────────────────────────
            Placed after the pool choice and before the numbers on purpose:
            what you draft, then how it looks, then the settings. This is not
            a toggle you flip later — it decides the room's entire layout, and
            a layout that can change mid-draft is one that changes while
            somebody is live. */}
        <div className="mt-8 flex flex-col gap-3">
          <span className="type-label text-muted">how the board looks</span>
          <div className="grid gap-2 sm:grid-cols-2">
            {(
              [
                [
                  "standard",
                  "Standard",
                  "Rosters either side of the card, the Rail under each name, the full bid history. Built for a desktop and for playing.",
                  false,
                ],
                [
                  "creator",
                  "Content Creator",
                  "A 9:16 frame built to be filmed: rosters stacked top and bottom, the card and the clock dead centre, the right edge kept clear of TikTok's buttons. Record mode and the OBS browser source from the first card.",
                  true,
                ],
              ] as const
            ).map(([id, label, blurb, premiumOnly]) => {
              const locked = premiumOnly && !premium.active;
              const picked = contentMode === id;
              return (
                <button
                  key={id}
                  onClick={() => setContentMode(id)}
                  className={`border p-3 text-left ${
                    picked ? "border-coral" : "rule hover:border-ink"
                  }`}
                  style={locked && !picked ? { opacity: 0.65 } : undefined}
                  aria-pressed={picked}
                >
                  <span className="flex items-baseline gap-2">
                    {locked ? <Padlock size={12} /> : null}
                    <span className={`type-label ${picked ? "text-coral" : "text-ink"}`}>
                      {label}
                    </span>
                    {premiumOnly && premium.active ? (
                      <span className="type-label text-teal">unlocked</span>
                    ) : null}
                  </span>
                  <span className="mt-1 block text-[0.8125rem] leading-snug text-muted">
                    {blurb}
                  </span>
                </button>
              );
            })}
          </div>

          {contentMode === "creator" && !premium.active ? (
            <UpgradeCard feature="Content Creator rooms" signedIn={premium.signedIn} compact />
          ) : null}
        </div>

        <div
          className={`mt-8 flex-col gap-6 ${
            mode === "handoff" || ((mode === "auto" || mode === "deck") && !signedIn)
              ? "hidden"
              : "flex"
          }`}
        >
          <Field label="your name" htmlFor="host">
            <TextInput id="host" value={hostName} maxLength={24} placeholder="Who's hosting?"
              onChange={(e) => setHostName(e.target.value)} />
          </Field>

          <Field label="what to call this draft" htmlFor="title">
            <TextInput id="title" value={title} maxLength={60}
              onChange={(e) => setTitle(e.target.value)} />
          </Field>

          {signedIn && saved.length > 0 ? (
            <div className="flex flex-col gap-2">
              <span className="type-label text-muted">your saved setups</span>
              <div className="flex flex-wrap gap-1.5">
                {saved.map((t) => (
                  <button key={t.id}
                    className="type-label border border-teal px-2.5 py-1.5 text-teal hover:text-ink"
                    onClick={() => {
                      setRosterSize(t.default_roster_size);
                      setBankroll(centsToInput(t.default_bankroll_cents));
                      setMinBid(centsToInput(t.default_min_bid_cents));
                      setTimer(t.default_timer_seconds);
                      setGives(t.default_gives_per_player);
                    }}>
                    {t.name}
                  </button>
                ))}
              </div>
            </div>
          ) : null}

          <div className="flex flex-col gap-2">
            <span className="type-label text-muted">players per team</span>
            <div className="flex items-stretch gap-2">
              <Button variant="quiet" className="w-14 shrink-0 text-lg"
                aria-label="Fewer players" disabled={rosterSize <= 1}
                onClick={() => setRosterSize((n) => Math.max(1, n - 1))}>&minus;</Button>
              <div className="panel flex flex-1 items-center justify-center py-3">
                <span className="type-num text-[1.75rem]">{rosterSize}</span>
              </div>
              <Button variant="quiet" className="w-14 shrink-0 text-lg"
                aria-label="More players" disabled={rosterSize >= 30}
                onClick={() => setRosterSize((n) => Math.min(30, n + 1))}>+</Button>
            </div>
            <p className="text-[0.75rem] text-muted">
              A team is a flat list of {rosterSize}. No positions, nothing to fill.
            </p>
          </div>

          <div className="grid grid-cols-2 gap-4">
            <Field label="bankroll each" htmlFor="bank">
              <TextInput id="bank" value={bankroll} inputMode="decimal" className="type-num"
                onChange={(e) => setBankroll(e.target.value)} />
            </Field>
            <Field label="minimum bid" htmlFor="min">
              <TextInput id="min" value={minBid} inputMode="decimal" className="type-num"
                onChange={(e) => setMinBid(e.target.value)} />
            </Field>
          </div>

          <div className="flex flex-col gap-2">
            <span className="type-label text-muted">counter-bid clock</span>
            <div className="flex gap-1.5">
              {[10, 15, 20, 30].map((t) => (
                <button key={t}
                  className={`type-num flex-1 border py-2.5 text-[0.9375rem] ${
                    timer === t && !customClock
                      ? "border-coral text-coral"
                      : "text-muted rule hover:text-ink"}`}
                  onClick={() => { setTimer(t); setCustomClock(false); }}>{t}s</button>
              ))}
              <button
                className={`type-label flex-1 border py-2.5 ${
                  customClock ? "border-coral text-coral" : "text-muted rule hover:text-ink"}`}
                onClick={() => { setCustomClock(true); if (timer === 0) setTimer(45); }}>
                Custom
              </button>
              <button
                title="no time limit"
                className={`type-num flex-1 border py-2.5 text-[0.9375rem] ${
                  timer === 0 ? "border-teal text-teal" : "text-muted rule hover:text-ink"}`}
                onClick={() => { setTimer(0); setCustomClock(false); }}>
                &infin;
              </button>
            </div>

            {customClock ? (
              <div className="flex items-center gap-2">
                <TextInput
                  value={String(timer)}
                  inputMode="numeric"
                  aria-label="seconds per counter-bid"
                  className="type-num"
                  onChange={(e) => setTimer(Math.max(0, Math.min(300, Number(e.target.value) || 0)))}
                />
                <span className="type-label shrink-0 text-muted">seconds</span>
              </div>
            ) : null}

            {timer === 0 ? (
              <p className="text-[0.75rem] leading-snug text-muted">
                No countdown at all. The card stays open until somebody raises or passes, so
                nobody loses a card to a bad connection — and nobody is forced to decide.
                Bring your own sense of urgency.
              </p>
            ) : timer < 3 ? (
              <p className="text-[0.75rem] leading-snug text-coral">
                Three seconds is the shortest real clock. Use &infin; if you want none at all.
              </p>
            ) : null}
          </div>

          <div className="flex flex-col gap-2">
            <span className="type-label text-muted">gives each</span>
            <div className="flex gap-1.5">
              {[0, 1, 2, 3, 99].map((g) => (
                <button key={g}
                  className={`type-num flex-1 border py-2.5 text-[0.9375rem] ${
                    gives === g ? "border-teal text-teal" : "text-muted rule hover:text-ink"}`}
                  onClick={() => setGives(g)}>{g === 99 ? "∞" : g}</button>
              ))}
            </div>
            <p className="text-[0.75rem] leading-snug text-muted">
              How many times each of you can hand a card to the other for free, burning a spot on
              their roster. Unlimited is a real option, but with no cap the cheapest way to play
              is for both of you to dump everything and never bid at all.
            </p>
          </div>

          {underfunded ? (
            <p className="border border-coral px-3 py-2.5 text-[0.875rem] text-ink">
              <span className="type-label text-coral">heads up</span>{" "}
              {formatCents(bankrollCents)} across {rosterSize} players at {formatCents(minBidCents)}{" "}
              minimum. Somebody runs out of money before their roster is full and finishes busted.
              That is a real game mode, just know you picked it.
            </p>
          ) : null}

          <label className="flex items-center gap-2.5">
            <input type="checkbox" checked={isPrivate}
              onChange={(e) => setIsPrivate(e.target.checked)}
              className="size-4 accent-[var(--color-coral)]" />
            <span className="text-[0.875rem]">Unlisted. Only people with the code get in.</span>
          </label>

          <details className="border-t pt-4 rule">
            <summary className="type-label cursor-pointer text-muted">
              branding on the results card
            </summary>
            <div className="mt-3 grid grid-cols-1 gap-4 sm:grid-cols-2">
              <Field label="accent colour" hint="Hex, e.g. #FF5A36">
                <TextInput value={accent} placeholder="#FF5A36" className="type-num"
                  onChange={(e) => setAccent(e.target.value)} />
              </Field>
              <Field label="logo" hint="Uploaded once in host settings, then used on every card">
                {logo ? (
                  <div className="flex items-center gap-3">
                    {/* eslint-disable-next-line @next/next/no-img-element */}
                    <img src={logo} alt="Your card logo" className="h-9 w-auto max-w-[7rem] object-contain" />
                    <span className="type-label text-teal">in use</span>
                  </div>
                ) : (
                  <p className="text-[0.8125rem] text-muted">
                    {signedIn
                      ? "No logo uploaded yet. Add one in host settings."
                      : "Sign in to upload a logo."}
                  </p>
                )}
              </Field>
            </div>
            {!signedIn ? (
              <p className="mt-3 text-[0.8125rem] text-muted">
                Sign in to keep branding and setups between sessions. Not required to play.
              </p>
            ) : null}
          </details>

          {error ? <p className="text-[0.875rem] text-coral">{error}</p> : null}

          <Button variant="primary" size="lg" disabled={!ready} onClick={() => void create()}>
            {busy ? "Creating…" : "Create the room"}
          </Button>
        </div>
      </main>
      {upgrade.open ? (
        <UpgradeDialog
          feature={upgrade.open.feature}
          why={upgrade.open.why}
          signedIn={premium.signedIn}
          returnTo="/new"
          onClose={upgrade.close}
        />
      ) : null}
      <Footer />
    </>
  );
}
