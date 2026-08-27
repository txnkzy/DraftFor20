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
   Two narrow columns hug the sides, everything else stays out of the way.

                28   258            690   920      1080
                 │    │              │     │        │
                 │ P1 │  ← 432px →   │ P2  │ TikTok │
                 │    │  open centre │     │  rail  │

   The right column CANNOT sit flush to the right edge: TikTok draws like,
   comment, share and sound down that strip, and a roster underneath them is
   a roster nobody can read. So "right edge" means the right edge of the
   usable frame, not of the video.                                          */
const W = 1080;
const H = 1920;
const SAFE_RIGHT = 160;   // TikTok's action rail
const SAFE_BOTTOM = 150;  // handle and caption
const COL = 230;          // column width
const MARGIN = 28;

const LEFT_X = MARGIN;
const RIGHT_X = W - SAFE_RIGHT - COL;
const CENTRE_L = LEFT_X + COL;
const CENTRE_R = RIGHT_X;

function stageMetrics(rosterSize: number) {
  const t = rosterSize <= 5 ? 0 : rosterSize <= 8 ? 1 : 2;
  const pick = (a: number, b: number, c: number) => [a, b, c][t];
  return {
    name: pick(30, 27, 24),
    bank: pick(58, 52, 46),
    row: pick(21, 19, 17),
    rowPad: pick(9, 7, 5),
    card: pick(52, 48, 44),
    bid: pick(104, 96, 88),
    clock: pick(76, 70, 64),
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
        <AuctionCard state={state} view={view} metrics={m} plate={plate} />
      </div>
    </div>
  );
}

/* ── a player's side ─────────────────────────────────────────────────────── */
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
  const empty = Math.max(state.room.roster_size - rows.length, 0);
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
     under TikTok's caption. Clipped to the usable height instead. */
  const COL_TOP = 150;
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: COL_TOP,
        width: COL,
        maxHeight: H - COL_TOP - SAFE_BOTTOM,
        overflow: "hidden",
      }}
    >
      {/* name + bankroll, one tight panel */}
      <div style={{ ...plate, padding: "12px 14px" }}>
        <div className="flex items-baseline" style={{ gap: 8 }}>
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

      {/* roster slots, each its own tight row rather than one long block */}
      <div style={{ marginTop: 10, display: "flex", flexDirection: "column", gap: 5 }}>
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

/* ── what is on the block, floating over the camera ──────────────────────── */
function AuctionCard({
  state, view, metrics, plate,
}: {
  state: RoomState;
  view: BoardView;
  metrics: ReturnType<typeof stageMetrics>;
  plate: CSSProperties;
}) {
  const width = CENTRE_R - CENTRE_L;
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
        left: CENTRE_L,
        width,
        top: 1180,
        ...plate,
        padding: "22px 24px",
        textAlign: "center",
        border: forced ? "2px solid var(--color-coral)" : undefined,
      }}
    >
      {forced ? (
        <div
          className="type-label"
          style={{ fontSize: 22, color: "var(--color-coral)", marginBottom: 8 }}
        >
          {opener!.name} can&apos;t afford this &middot; give or pass
        </div>
      ) : (
        <div
          className="type-label"
          style={{ fontSize: 20, color: "var(--color-muted)", marginBottom: 6 }}
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
