"use client";

import { useEffect, useRef, useState, type CSSProperties } from "react";
import { FlipDigits } from "./FlipDigits";
import { TensionBar } from "./TensionBar";
import { digitsOf, formatCents } from "@/lib/money";
import { seatAccent, type BoardView } from "@/lib/game/view";
import { rosterOf, type RoomState } from "@/lib/game/types";

/* ── the frame this is composed for ────────────────────────────────────────
   1080x1920, rendered at true size and scaled to fit whatever box it is put
   in — the same trick ShareCard uses, so what you lay out is what you record,
   and OBS at 1080x1920 gets scale 1.

   THE CENTRE IS THE POINT. This overlay is composited ON TOP of a live camera
   feed of two people talking, so the middle of the frame is not ours to use.
   The card on the block sits in a band across the top, both rosters sit in a
   band across the bottom, and the faces get everything between.

        110 ┌──────────────────────────────┐
            │        card on the block     │  ← centred, 680 wide
        520 ├──────────────────────────────┤
            │                              │
            │        O P E N   —  camera   │  ← ~630px of clear frame
            │                              │
       1150 ├───────────────┬──────────────┤
            │    P1 roster  │   P2 roster  │  ← centred pair, 360 + 40 + 360
       1770 └──────────────────────────────┘

   Everything is centred on the true frame centre (540). Staying centred AND
   clearing TikTok's right-hand action rail means insetting the content band
   by the rail's width on BOTH sides: symmetry costs 160px on the left that
   nothing was using, and buys a layout that reads as centred on camera
   instead of one that reads as shoved left.                                */
const W = 1080;
const H = 1920;
const SAFE_RIGHT = 160;   // TikTok's action rail: like, comment, share, sound
const SAFE_BOTTOM = 150;  // handle and caption
const SAFE_TOP = 110;

const BAND_W = W - SAFE_RIGHT * 2;   // 760, centred on 540
const BAND_X = SAFE_RIGHT;           // 160 → runs 160..920

const COL_GAP = 40;
const COL = (BAND_W - COL_GAP) / 2;  // 360
const LEFT_X = BAND_X;
const RIGHT_X = BAND_X + COL + COL_GAP;

const CARD_W = 680;
const CARD_X = (W - CARD_W) / 2;     // 200
const BAND_TOP = 1150;               // where the rosters start

function stageMetrics(rosterSize: number) {
  const t = rosterSize <= 5 ? 0 : rosterSize <= 8 ? 1 : 2;
  const pick = (a: number, b: number, c: number) => [a, b, c][t];
  return {
    name: pick(34, 30, 26),
    bank: pick(66, 58, 50),
    row: pick(24, 21, 18),
    rowPad: pick(10, 8, 6),
    card: pick(62, 56, 50),
    bid: pick(112, 102, 92),
    clock: pick(84, 76, 68),
  };
}

export interface StageChrome {
  /** OBS composites this over video, so the page itself paints nothing */
  transparent?: boolean;
  /** translucent plates behind text. Off = nothing but glyphs. */
  plates?: boolean;
  /** the ground when not transparent */
  ground?: string;
}

export function VerticalStage({
  state,
  view,
  landedEntryId = null,
  transparent = false,
  plates = true,
  ground = "var(--color-board)",
}: {
  state: RoomState;
  view: BoardView;
  landedEntryId?: string | null;
} & StageChrome) {
  const box = useRef<HTMLDivElement>(null);
  const [scale, setScale] = useState(1);

  useEffect(() => {
    const el = box.current;
    if (!el) return;
    const fit = () => {
      const s = Math.min(el.clientWidth / W, el.clientHeight / H);
      setScale(s > 0 ? s : 1);
    };
    const ro = new ResizeObserver(fit);
    ro.observe(el);
    fit();
    return () => ro.disconnect();
  }, []);

  const m = stageMetrics(state.room.roster_size);

  /* Tight to the text, never a big block: a panel wide enough to be readable
     and no wider is the difference between an overlay and a wall. */
  const plate: CSSProperties = plates
    ? {
        background: transparent ? "rgba(29,32,41,0.82)" : "var(--color-surface)",
        borderRadius: 4,
      }
    : {};

  const p1 = state.players.find((p) => p.seat === 1) ?? null;
  const p2 = state.players.find((p) => p.seat === 2) ?? null;

  return (
    <div
      ref={box}
      className="h-full w-full"
      style={{
        position: "relative",
        overflow: "hidden",
        background: transparent ? "transparent" : ground,
      }}
    >
      <div
        style={{
          position: "absolute",
          left: "50%",
          top: "50%",
          width: W,
          height: H,
          transform: `translate(-50%, -50%) scale(${scale})`,
        }}
      >
        <AuctionCard state={state} view={view} metrics={m} plate={plate} />
        <StageColumn
          state={state} view={view} seat={1}
          name={p1?.display_name ?? "seat 1"}
          bankrollCents={p1?.bankroll_cents ?? 0}
          x={LEFT_X} metrics={m} plate={plate} landedEntryId={landedEntryId}
        />
        <StageColumn
          state={state} view={view} seat={2}
          name={p2?.display_name ?? "seat 2"}
          bankrollCents={p2?.bankroll_cents ?? 0}
          x={RIGHT_X} metrics={m} plate={plate} landedEntryId={landedEntryId}
        />
      </div>
    </div>
  );
}

/* ── a player's side of the bottom band ──────────────────────────────────── */
function StageColumn({
  state, view, seat, name, bankrollCents, x, metrics, plate, landedEntryId,
}: {
  state: RoomState;
  view: BoardView;
  seat: number;
  name: string;
  bankrollCents: number;
  x: number;
  metrics: ReturnType<typeof stageMetrics>;
  plate: CSSProperties;
  landedEntryId: string | null;
}) {
  const player = state.players.find((p) => p.seat === seat);
  const rows = player ? rosterOf(state, player.id) : [];
  const accent = seatAccent(seat);
  const cols = state.room.roster_size > 6 ? 2 : 1;

  /* The bottom band is finite, and at 30 slots a full grid of placeholders
     overruns it and gets sliced mid-plate. Empty slots are the cheapest
     thing on screen, so they are what gets cut: every card actually won is
     rendered, and blanks fill only the room left over. A viewer is counting
     picks, not placeholders. */
  const bandH = H - BAND_TOP - SAFE_BOTTOM;
  const rowH = metrics.row * 1.25 + (metrics.row - 3) * 1.25 + metrics.rowPad * 2 + 5;
  const headH = metrics.name * 1.2 + metrics.bank + 24 + 34;
  const capacity = Math.max(cols * Math.floor((bandH - headH - 10) / rowH), rows.length);
  const empty = Math.max(Math.min(state.room.roster_size - rows.length, capacity - rows.length), 0);
  /* During an offer the OPENER is deciding; during bidding the player ON THE
     CLOCK is. Treating them as interchangeable lit both columns at once. */
  const active =
    view.phase === "offering"
      ? view.openerSeat === seat
      : view.phase === "bidding"
        ? view.onClockSeat === seat
        : false;
  const broke = view.players.find((p) => p.seat === seat)?.isBroke ?? false;

  /* A 30-slot roster would otherwise run off the bottom of the frame and
     under TikTok's caption. Clipped to the usable height instead, which eats
     trailing empty slots before it ever eats a name. */
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: BAND_TOP,
        width: COL,
        maxHeight: H - BAND_TOP - SAFE_BOTTOM,
        overflow: "hidden",
        textAlign: "center",
      }}
    >
      {/* name + bankroll, one tight panel */}
      <div style={{ ...plate, padding: "12px 14px" }}>
        <div className="flex items-baseline justify-center" style={{ gap: 8 }}>
          <span style={{ width: 12, height: 12, background: accent, flexShrink: 0 }} aria-hidden />
          <span
            className="type-display truncate"
            style={{ fontSize: metrics.name, color: "var(--color-ink)" }}
          >
            {name}
          </span>
        </div>
        <div
          className="type-num"
          style={{
            fontSize: metrics.bank,
            lineHeight: 1,
            marginTop: 4,
            color: broke ? "var(--color-coral)" : "var(--color-gold)",
            transition: "color 200ms linear",
          }}
        >
          <span>$</span>
          <FlipDigits text={digitsOf(bankrollCents)} />
        </div>
        {broke ? (
          <div className="type-label" style={{ marginTop: 4, color: "var(--color-coral)" }}>
            broke
          </div>
        ) : active ? (
          <div className="type-label" style={{ marginTop: 4, color: "var(--color-coral)" }}>
            {view.phase === "offering" ? "deciding" : "on the clock"}
          </div>
        ) : null}
      </div>

      {/* Roster slots, each its own tight row rather than one long block.
         The bottom band is 620px tall, so past six slots a single stack runs
         out of frame — those rosters fold into two sub-columns instead,
         which buys back twice the depth without touching the open centre. */}
      <div
        style={{
          marginTop: 10,
          display: "grid",
          gridTemplateColumns: cols === 2 ? "1fr 1fr" : "1fr",
          gap: 5,
        }}
      >
        {rows.map((r) => (
          <div
            key={r.id}
            className={landedEntryId === r.id ? "anim-land" : ""}
            style={{ ...plate, padding: `${metrics.rowPad}px 12px` }}
          >
            <div className="truncate" style={{ fontSize: metrics.row, color: "var(--color-ink)" }}>
              {r.item_name}
            </div>
            <div
              className="type-num"
              style={{
                fontSize: metrics.row - 3,
                color: r.gifted ? "var(--color-teal)" : "var(--color-gold)",
              }}
            >
              {r.gifted ? "free" : formatCents(r.price_cents)}
            </div>
          </div>
        ))}
        {Array.from({ length: empty }).map((_, i) => (
          <div
            key={`e${i}`}
            style={{
              ...plate,
              padding: `${metrics.rowPad}px 12px`,
              opacity: 0.5,
              fontSize: metrics.row,
              color: "var(--color-muted)",
            }}
          >
            &mdash;
          </div>
        ))}
      </div>
    </div>
  );
}

/* ── what is on the block, across the top ────────────────────────────────── */
function AuctionCard({
  state, view, metrics, plate,
}: {
  state: RoomState;
  view: BoardView;
  metrics: ReturnType<typeof stageMetrics>;
  plate: CSSProperties;
}) {
  const resolved = state.lot?.status === "resolved" ? state.lot : null;
  const wonSeat = resolved?.winner_player_id
    ? (state.players.find((p) => p.id === resolved.winner_player_id)?.seat ?? null)
    : null;

  /* FORCE-OR-TAKE. The opener cannot afford this card, so their only moves
     are to hand it over or let it go. In a filmed room this is the loudest
     moment in the game and it used to render as an ordinary offer. */
  const opener = view.players.find((p) => p.seat === view.openerSeat);
  const forced =
    view.phase === "offering" &&
    Boolean(opener) &&
    opener!.maxLegalBidCents < view.minBidCents;

  const slam = wonSeat === 1 ? "anim-slam-left" : wonSeat === 2 ? "anim-slam-right" : "";

  return (
    <div
      key={resolved ? `won-${resolved.id}` : (view.lotId ?? "none")}
      className={slam}
      style={{
        position: "absolute",
        left: CARD_X,
        width: CARD_W,
        top: SAFE_TOP,
        ...plate,
        padding: "22px 24px",
        textAlign: "center",
        border: forced ? "2px solid var(--color-coral)" : undefined,
      }}
    >
      {forced ? (
        <div
          className="type-label"
          style={{ fontSize: 24, color: "var(--color-coral)", marginBottom: 8 }}
        >
          {opener!.name} can&apos;t afford this &middot; give or pass
        </div>
      ) : (
        <div
          className="type-label"
          style={{ fontSize: 22, color: "var(--color-muted)", marginBottom: 6 }}
        >
          {view.phase === "complete"
            ? "final board"
            : view.phase === "offering"
              ? `${view.players.find((p) => p.seat === view.openerSeat)?.name ?? ""} decides`
              : "on the block"}
        </div>
      )}

      <div
        className="type-display anim-deal"
        style={{ fontSize: metrics.card, lineHeight: 1.04, color: "var(--color-ink)" }}
      >
        {view.itemName ?? (view.phase === "complete" ? state.room.title : "Dealing")}
      </div>

      {view.phase === "offering" || view.phase === "bidding" ? (
        <>
          <div
            className="flex items-baseline justify-center"
            style={{ gap: 28, marginTop: 10 }}
          >
            <span
              className="type-num"
              style={{ fontSize: metrics.bid, lineHeight: 0.92, color: "var(--color-gold)" }}
            >
              <span>$</span>
              <FlipDigits text={digitsOf(view.currentBidCents)} />
            </span>
            {view.noClock ? null : (
              <span
                className={`type-num ${view.critical ? "anim-clock-critical" : ""}`}
                style={{
                  fontSize: metrics.clock,
                  lineHeight: 0.92,
                  color: view.urgent ? "var(--color-coral)" : "var(--color-ink)",
                  transition: "color 160ms linear",
                }}
              >
                {view.seconds ?? view.timerSeconds}
              </span>
            )}
          </div>
          {view.noClock ? null : (
            <div style={{ marginTop: 10 }}>
              <TensionBar
                fraction={view.fraction}
                urgent={view.urgent}
                critical={view.critical}
                height={6}
              />
            </div>
          )}
        </>
      ) : null}
    </div>
  );
}
