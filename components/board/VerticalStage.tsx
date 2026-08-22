"use client";

import { useEffect, useRef, useState, type CSSProperties } from "react";
import { FlipDigits } from "./FlipDigits";
import { TensionBar } from "./TensionBar";
import { digitsOf, formatCents } from "@/lib/money";
import { seatAccent, type BoardView } from "@/lib/game/view";
import { rosterOf, type RoomState } from "@/lib/game/types";

/* ── the frame this is composed for ────────────────────────────────────────
   A 1080x1920 stage, rendered at true size and scaled to fit whatever box it
   is put in — the same trick ShareCard uses, so what you record is what you
   laid out, and OBS at 1080x1920 gets scale 1.

   TikTok's own furniture sits on top of the right edge (like / comment /
   share / sound) and along the bottom (handle, caption). Nothing meaningful
   is allowed into either, so the two reserves below are hard margins rather
   than padding somebody can eat into.                                       */
const W = 1080;
const H = 1920;
const SAFE_RIGHT = 200;   // the action rail
const SAFE_BOTTOM = 150;  // handle and caption
const PAD_X = 56;

function stageMetrics(rosterSize: number) {
  const t = rosterSize <= 5 ? 0 : rosterSize <= 8 ? 1 : 2;
  const pick = (a: number, b: number, c: number) => [a, b, c][t];
  return {
    name: pick(44, 38, 32),
    row: pick(34, 29, 23),
    rowPad: pick(11, 8, 5),
    price: pick(32, 27, 22),
    card: pick(78, 70, 62),
    bid: pick(140, 128, 118),
    clock: pick(104, 96, 88),
  };
}

export interface StageChrome {
  /** OBS composites this over video, so the page itself paints nothing */
  transparent?: boolean;
  /** translucent plates behind text. Off = nothing but glyphs. */
  plates?: boolean;
  /** the ground when not transparent. Record mode uses pure black, which is
      a real contrast gain over the app's charcoal once it is on camera. */
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

  const p1 = state.players.find((p) => p.seat === 1) ?? null;
  const p2 = state.players.find((p) => p.seat === 2) ?? null;
  const m = stageMetrics(state.room.roster_size);
  const plate: CSSProperties = plates
    ? { background: transparent ? "rgba(20,22,28,0.62)" : "var(--color-surface)" }
    : {};

  return (
    <div
      ref={box}
      className="h-full w-full"
      style={{
        position: "relative",
        // the stage is laid out at true size and scaled down, so it must not
        // be allowed to size its own parent: that is what makes the
        // measurement circular and lets the frame overflow the viewport
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
          display: "flex",
          flexDirection: "column",
          color: "var(--color-ink)",
          paddingLeft: PAD_X,
          paddingRight: SAFE_RIGHT,
          paddingTop: 40,
          paddingBottom: SAFE_BOTTOM,
          gap: 22,
        }}
      >
        {/* ── top third: seat 1 ─────────────────────────────────────────── */}
        <StageRoster
          state={state}
          seat={1}
          name={p1?.display_name ?? "seat 1"}
          bankrollCents={p1?.bankroll_cents ?? 0}
          align="start"
          metrics={m}
          plate={plate}
          landedEntryId={landedEntryId}
        />

        {/* ── the middle third. Card, money, clock, dead centre. ────────── */}
        <div
          className="flex flex-col items-center justify-center text-center"
          style={{ ...plate, flex: "0 0 620px", padding: "26px 30px", gap: 14 }}
        >
          <span
            className="type-label"
            style={{ fontSize: 26, letterSpacing: "0.2em", color: "var(--color-muted)" }}
          >
            {view.phase === "complete"
              ? "final board"
              : view.phase === "offering"
                ? `${view.players.find((p) => p.seat === view.openerSeat)?.name ?? ""} decides`
                : "on the block"}
          </span>

          <p
            key={view.lotId ?? "none"}
            className="type-display anim-deal"
            style={{ fontSize: m.card, lineHeight: 1.02, maxWidth: "100%" }}
          >
            {view.itemName ?? (view.phase === "complete" ? state.room.title : "Dealing")}
          </p>

          {view.phase === "offering" || view.phase === "bidding" ? (
            <>
              <div className="flex items-baseline justify-center" style={{ gap: 40 }}>
                <span
                  className="type-num"
                  style={{ fontSize: m.bid, lineHeight: 0.9, color: "var(--color-gold)" }}
                >
                  <span>$</span>
                  <FlipDigits text={digitsOf(view.currentBidCents)} />
                </span>
                <span
                  className={`type-num ${view.critical ? "anim-clock-critical" : ""}`}
                  style={{
                    fontSize: m.clock,
                    lineHeight: 0.9,
                    color: view.urgent ? "var(--color-coral)" : "var(--color-ink)",
                    transition: "color 160ms linear",
                  }}
                >
                  {view.noClock ? "\u221e" : (view.seconds ?? view.timerSeconds)}
                </span>
              </div>
              {view.noClock ? null : (
                <div style={{ width: "100%" }}>
                  <TensionBar
                    fraction={view.fraction}
                    urgent={view.urgent}
                    critical={view.critical}
                    height={8}
                  />
                </div>
              )}
              <span className="type-label" style={{ fontSize: 24, color: "var(--color-muted)" }}>
                {view.phase === "bidding"
                  ? `${view.players.find((p) => p.seat === view.onClockSeat)?.name ?? ""} is up`
                  : `${formatCents(view.minBidCents)} minimum · ${view.deckRemaining} left in the deck`}
              </span>
            </>
          ) : null}
        </div>

        {/* ── bottom third: seat 2 ──────────────────────────────────────── */}
        <StageRoster
          state={state}
          seat={2}
          name={p2?.display_name ?? "seat 2"}
          bankrollCents={p2?.bankroll_cents ?? 0}
          align="end"
          metrics={m}
          plate={plate}
          landedEntryId={landedEntryId}
        />
      </div>
    </div>
  );
}

function StageRoster({
  state,
  seat,
  name,
  bankrollCents,
  align,
  metrics,
  plate,
  landedEntryId,
}: {
  state: RoomState;
  seat: number;
  name: string;
  bankrollCents: number;
  align: "start" | "end";
  metrics: ReturnType<typeof stageMetrics>;
  plate: CSSProperties;
  landedEntryId: string | null;
}) {
  const player = state.players.find((p) => p.seat === seat);
  const rows = player ? rosterOf(state, player.id) : [];
  const accent = seatAccent(seat);
  const empty = Math.max(state.room.roster_size - rows.length, 0);

  return (
    <div
      className="flex min-h-0 flex-col"
      style={{ ...plate, flex: 1, padding: "18px 26px", justifyContent: align === "end" ? "flex-end" : "flex-start" }}
    >
      <div className="flex items-baseline" style={{ gap: 14 }}>
        <span style={{ width: 16, height: 16, background: accent }} aria-hidden />
        <span className="type-display" style={{ fontSize: metrics.name }}>
          {name}
        </span>
        <span
          className="type-num"
          style={{ marginLeft: "auto", fontSize: metrics.name, color: "var(--color-gold)" }}
        >
          <span>$</span>
          <FlipDigits text={digitsOf(bankrollCents)} />
        </span>
      </div>

      <ul className="flex flex-col" style={{ marginTop: 10 }}>
        {rows.map((r) => {
          const landed = landedEntryId === r.id;
          return (
            <li
              key={r.id}
              className={`flex items-baseline ${landed ? "anim-land-glow" : ""}`}
              style={{
                gap: 14,
                padding: `${metrics.rowPad}px 6px`,
                borderBottom: "1px solid color-mix(in oklab, var(--color-muted) 24%, transparent)",
              }}
            >
              <span
                className={`min-w-0 flex-1 truncate ${landed ? "anim-land" : ""}`}
                style={{ fontSize: metrics.row }}
              >
                {r.item_name}
              </span>
              <span
                className={`type-num ${landed ? "anim-land" : ""}`}
                style={{
                  fontSize: metrics.price,
                  color: r.gifted ? "var(--color-teal)" : "var(--color-gold)",
                }}
              >
                {r.gifted ? "free" : formatCents(r.price_cents)}
              </span>
            </li>
          );
        })}
        {Array.from({ length: empty }).map((_, i) => (
          <li
            key={`e${i}`}
            style={{
              padding: `${metrics.rowPad}px 6px`,
              borderBottom: "1px solid color-mix(in oklab, var(--color-muted) 14%, transparent)",
              fontSize: metrics.row,
              color: "color-mix(in oklab, var(--color-muted) 55%, transparent)",
            }}
          >
            &mdash;
          </li>
        ))}
      </ul>
    </div>
  );
}
