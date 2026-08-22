"use client";

import { useEffect, useRef, useState } from "react";
import { formatCents } from "@/lib/money";
import { cardMetrics, type CardModel } from "@/lib/results/cardModel";
import { SITE_URL } from "@/lib/site";
import type { ExportStyle } from "@/lib/premium";

const W = 1080;
const H = 1920;

/**
 * The actual product. 9:16, real numbers, ready to screen-record. Rendered at
 * true 1080x1920 and scaled to fit, so what you record is what you get. The
 * PNG route draws the same model with the same metrics.
 *
 * `style` is what the SERVER says this card looks like — the same answer the
 * PNG route gets from df20_export_style. It is passed in rather than derived
 * from the signed-in user so the preview cannot promise a card the download
 * will not produce.
 *
 * The leftover totals sit in a band under both rosters rather than inside
 * them, because the comparison between those two numbers is the entire
 * argument the card exists to start.
 */

/** What every card looks like unless a premium account has said otherwise. */
const WATERMARKED: ExportStyle = { watermark: true, logo_url: null, accent: null, handle: null };

export function ShareCard({
  model,
  style = WATERMARKED,
}: {
  model: CardModel;
  style?: ExportStyle;
}) {
  const box = useRef<HTMLDivElement>(null);
  const [scale, setScale] = useState(0.3);

  useEffect(() => {
    const el = box.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setScale(el.clientWidth / W));
    ro.observe(el);
    setScale(el.clientWidth / W);
    return () => ro.disconnect();
  }, []);

  const brand = style.accent || model.accent || "#F5B942";
  const logoUrl = style.logo_url ?? model.logoUrl;
  const seatColor = (seat: number) => (seat === 1 ? brand : "#E8E6E1");
  const m = cardMetrics(model.players[0]?.rows.length ?? 5);

  return (
    <div ref={box} className="w-full overflow-hidden" style={{ aspectRatio: `${W} / ${H}` }}>
      <div
        style={{
          width: W,
          height: H,
          transform: `scale(${scale})`,
          transformOrigin: "top left",
          background: "#14161C",
          color: "#E8E6E1",
          display: "flex",
          flexDirection: "column",
          padding: 72,
        }}
      >
        <div style={{ display: "flex", alignItems: "baseline", justifyContent: "space-between" }}>
          <span className="type-label" style={{ fontSize: 26, color: "#9C978E", letterSpacing: "0.18em" }}>
            THE $20 AUCTION DRAFT
          </span>
          <span className="type-num" style={{ fontSize: 26, color: "#9C978E" }}>
            {model.code}
          </span>
        </div>

        <h2 className="type-display" style={{ fontSize: m.titleSize, marginTop: 18, lineHeight: 0.94 }}>
          {model.title}
        </h2>

        <div style={{ height: 4, background: brand, width: 160, marginTop: 26, marginBottom: 40 }} />

        <div style={{ flex: 0.35, minHeight: 0 }} />

        {/* rosters */}
        <div style={{ display: "flex", gap: m.columnGap }}>
          {model.players.map((p) => {
            const c = seatColor(p.seat);
            return (
              <div key={p.id} style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column" }}>
                <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
                  <span style={{ width: 18, height: 18, background: c }} />
                  <span className="type-display" style={{ fontSize: m.nameSize }}>
                    {p.name}
                  </span>
                </div>

                <div style={{ marginTop: 22, display: "flex", flexDirection: "column" }}>
                  {p.rows.map((r, i) => (
                    <div
                      key={i}
                      style={{
                        display: "flex",
                        alignItems: "baseline",
                        gap: 12,
                        borderBottom: "1px solid rgba(95,123,115,0.3)",
                        padding: `${m.rowPadY}px 0`,
                      }}
                    >
                      <span
                        className="type-label"
                        style={{ fontSize: m.numSize, color: "#9C978E", width: 34, flexShrink: 0 }}
                      >
                        {r.pick}
                      </span>
                      <span
                        style={{
                          fontSize: m.itemSize,
                          flex: 1,
                          minWidth: 0,
                          overflow: "hidden",
                          textOverflow: "ellipsis",
                          whiteSpace: "nowrap",
                          color: "#E8E6E1",
                        }}
                      >
                        {r.item}
                      </span>
                      <span
                        className="type-num"
                        style={{ fontSize: m.priceSize, color: r.gifted ? "#2DD4BF" : "#F5B942", flexShrink: 0 }}
                      >
                        {r.gifted ? "free" : formatCents(r.priceCents)}
                      </span>
                    </div>
                  ))}
                </div>

                {/* the Rail again, at rest: what they spent against what they kept */}
                <div style={{ display: "flex", marginTop: 30, height: m.railH, width: "100%" }}>
                  <div
                    style={{
                      width: `${(p.spentCents / Math.max(model.startingCents, 1)) * 100}%`,
                      background: c,
                    }}
                  />
                  <div
                    style={{
                      flex: 1,
                      background: "rgba(95,123,115,0.22)",
                      borderRight: `2px solid ${c}`,
                    }}
                  />
                </div>
                <span className="type-num" style={{ fontSize: 24, color: "#9C978E", marginTop: 12 }}>
                  spent {formatCents(p.spentCents)} of {formatCents(model.startingCents)}
                </span>
              </div>
            );
          })}
        </div>

        <div style={{ flex: 1, minHeight: 30 }} />

        {model.topLot ? (
          <p style={{ fontSize: 28, color: "#9C978E", marginBottom: 30 }}>
            Priciest pick: <span style={{ color: "#E8E6E1" }}>{model.topLot.item}</span>{" "}
            <span className="type-num" style={{ color: brand }}>
              {formatCents(model.topLot.priceCents)}
            </span>
            {model.longestWar && model.longestWar.raises > 1
              ? ` · ${model.longestWar.item} took ${model.longestWar.raises} raises`
              : ""}
          </p>
        ) : null}

        {/* the payoff: the two numbers people argue about */}
        <div
          style={{
            display: "flex",
            gap: m.columnGap,
            borderTop: `2px solid ${brand}`,
            paddingTop: 30,
          }}
        >
          {model.players.map((p) => {
            const c = seatColor(p.seat);
            return (
              <div key={p.id} style={{ flex: 1, minWidth: 0, display: "flex", flexDirection: "column" }}>
                <span className="type-label" style={{ fontSize: 24, color: "#9C978E" }}>
                  {p.name} finished with
                </span>
                <span
                  className="type-num"
                  style={{ fontSize: m.totalSize, lineHeight: 0.88, color: c, marginTop: 6 }}
                >
                  {formatCents(p.leftoverCents)}
                </span>
                {p.busted ? (
                  <span
                    className="type-label"
                    style={{
                      marginTop: 14,
                      border: "2px solid #FF5A36",
                      color: "#FF5A36",
                      padding: "7px 10px",
                      fontSize: 22,
                      textAlign: "center",
                    }}
                  >
                    BUSTED · DISQUALIFIED
                  </span>
                ) : null}
              </div>
            );
          })}
        </div>

        <div
          style={{
            marginTop: 34,
            paddingTop: 26,
            borderTop: "1px solid rgba(95,123,115,0.35)",
            display: "flex",
            alignItems: "center",
            gap: 20,
          }}
        >
          {logoUrl ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img
              src={logoUrl}
              alt={`${model.title} host logo`}
              style={{ height: 44, width: "auto" }}
            />
          ) : null}
          {style.watermark ? (
            <>
              <span className="type-display" style={{ fontSize: 34 }}>
                Draft<span style={{ color: brand }}>For20</span>
              </span>
              <span className="type-num" style={{ fontSize: 22, color: "#9C978E" }}>
                {SITE_URL.replace(/^https?:\/\//, "")}
              </span>
            </>
          ) : null}
          {style.handle ? (
            <span className="type-display" style={{ fontSize: 30, color: brand }}>
              {style.handle}
            </span>
          ) : null}
          <span className="type-num" style={{ marginLeft: "auto", fontSize: 26, color: "#9C978E" }}>
            {formatCents(model.startingCents)} each &middot; {model.rosterSize} players
          </span>
        </div>
      </div>
    </div>
  );
}
