import { ImageResponse } from "next/og";
import { createClient } from "@supabase/supabase-js";
import { buildCardModel, cardMetrics } from "@/lib/results/cardModel";
import { formatCents } from "@/lib/money";
import { SITE_URL } from "@/lib/site";
import type { RoomState } from "@/lib/game/types";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * The results card, as a real PNG.
 *
 * next/og runs Satori to lay the tree out as SVG and resvg to rasterise it,
 * so what comes back is image/png bytes — a file that saves, uploads and
 * posts. Nothing here depends on the browser having rendered anything.
 *
 * THE WATERMARK IS RESOLVED SERVER-SIDE AND THERE IS NO PARAMETER FOR IT.
 * df20_export_style() looks up the room's host account, checks whether their
 * premium is active RIGHT NOW, and only then reads their preference. A free
 * account, a lapsed account, a premium account that never touched the setting
 * and anyone editing this URL all get the same watermarked card.
 */

const W = 1080;
const H = 1920;
const BOARD = "#14161C";
const BONE = "#E8E6E1";
const SAGE = "#9C978E";
const BULB = "#F5B942";
const KLAXON = "#FF5A36";
const GOLD = "#F5B942";
const TEAL = "#2DD4BF";

/** Google serves static TTF to an old UA, which is what Satori can parse. */
async function googleFont(family: string, weight: number, text: string) {
  try {
    const url =
      `https://fonts.googleapis.com/css2?family=${encodeURIComponent(family)}:wght@${weight}` +
      `&text=${encodeURIComponent(text)}`;
    const css = await fetch(url, {
      headers: { "User-Agent": "Mozilla/5.0 (Windows NT 6.1; WOW64)" },
      cache: "force-cache",
    }).then((r) => r.text());
    const match = css.match(/src: url\((.+?)\) format\('(?:opentype|truetype)'\)/);
    if (!match) return null;
    return await fetch(match[1], { cache: "force-cache" }).then((r) => r.arrayBuffer());
  } catch {
    return null;
  }
}

interface ExportStyle {
  watermark: boolean;
  logo_url: string | null;
  accent: string | null;
  handle: string | null;
}

/**
 * Satori fetches remote <img> itself and fails the WHOLE render if the URL is
 * gone, which would turn a deleted logo into a broken results card. Fetching
 * it here means a bad logo costs the logo and nothing else.
 */
async function loadLogo(url: string | null): Promise<string | null> {
  if (!url || !/^https:\/\/[A-Za-z0-9.-]+\.supabase\.co\/storage\/v1\/object\/public\/brand\//.test(url)) {
    return null;
  }
  try {
    const res = await fetch(url, { cache: "force-cache" });
    if (!res.ok) return null;
    const type = res.headers.get("content-type") ?? "";
    if (!/^image\/(png|jpeg|webp)$/.test(type)) return null;
    const buf = await res.arrayBuffer();
    if (buf.byteLength > 524288) return null;
    return `data:${type};base64,${Buffer.from(buf).toString("base64")}`;
  } catch {
    return null;
  }
}

export async function GET(req: Request, { params }: { params: Promise<{ code: string }> }) {
  const { code } = await params;
  // ?dl=1 makes the browser save the file rather than display it
  const download = new URL(req.url).searchParams.get("dl") === "1";
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (!url || !key) return new Response("Supabase is not configured.", { status: 500 });

  const sb = createClient(url, key, { auth: { persistSession: false } });
  const { data } = await sb.rpc("get_room_state", { p_code: code.toUpperCase() });
  if (!data) return new Response("No such room.", { status: 404 });

  // fail towards the watermark: any error here leaves style at its default
  let style: ExportStyle = { watermark: true, logo_url: null, accent: null, handle: null };
  try {
    const { data: st } = await sb.rpc("df20_export_style", { p_code: code.toUpperCase() });
    if (st && typeof st === "object") {
      const raw = st as Partial<ExportStyle>;
      style = {
        watermark: raw.watermark !== false,
        logo_url: raw.logo_url ?? null,
        accent: raw.accent ?? null,
        handle: raw.handle ?? null,
      };
    }
  } catch {
    /* keep the default */
  }

  const model = buildCardModel(data as RoomState);
  const logo = await loadLogo(style.logo_url ?? model.logoUrl);
  const brand = style.accent || model.accent || BULB;
  const seatColor = (seat: number) => (seat === 1 ? brand : BONE);
  const m = cardMetrics(model.players[0]?.rows.length ?? 5);

  const source =
    model.title +
    model.code +
    model.players.map((p) => p.name + p.rows.map((r) => r.item).join("")).join("") +
    (model.topLot?.item ?? "") +
    (model.longestWar?.item ?? "") +
    (style.handle ?? "") +
    SITE_URL.replace(/^https?:\/\//, "") +
    "THE $20 AUCTION DRAFTfinished withBUSTEDDISQUALIFIEDfreegivenPriciest buytotookraisesspentofeachplayersDraftFor20 0123456789.,$\u00b7'\u2019-";
  // uppercase headings are produced by text-transform AFTER subsetting, so the
  // subset has to contain both cases or the transformed glyphs fall back
  const glyphs = source + source.toUpperCase() + source.toLowerCase();

  const [display, mono, body] = await Promise.all([
    googleFont("Archivo", 800, glyphs),
    googleFont("Azeret Mono", 600, glyphs),
    googleFont("Karla", 400, glyphs),
  ]);

  const fonts = [
    display && { name: "Archivo", data: display, weight: 800 as const, style: "normal" as const },
    mono && { name: "Azeret Mono", data: mono, weight: 600 as const, style: "normal" as const },
    body && { name: "Karla", data: body, weight: 400 as const, style: "normal" as const },
  ].filter(Boolean) as { name: string; data: ArrayBuffer; weight: 400 | 600 | 800; style: "normal" }[];

  const D = { fontFamily: "Archivo", textTransform: "uppercase" as const };
  const M = { fontFamily: "Azeret Mono" };

  try {
  return new ImageResponse(
    (
      <div
        style={{
          width: W,
          height: H,
          display: "flex",
          flexDirection: "column",
          background: BOARD,
          color: BONE,
          padding: 72,
          fontFamily: "Karla",
        }}
      >
        <div style={{ display: "flex", alignItems: "baseline", justifyContent: "space-between" }}>
          <div style={{ ...D, fontSize: 26, color: SAGE, letterSpacing: 4, display: "flex" }}>
            THE $20 AUCTION DRAFT
          </div>
          <div style={{ ...M, fontSize: 26, color: SAGE, display: "flex" }}>{model.code}</div>
        </div>

        <div style={{ ...D, fontSize: m.titleSize, marginTop: 18, lineHeight: 1, display: "flex" }}>
          {model.title}
        </div>

        <div style={{ display: "flex", height: 4, width: 160, background: brand, marginTop: 26, marginBottom: 40 }} />

        <div style={{ display: "flex", flex: 0.35, minHeight: 0 }} />

        <div style={{ display: "flex", gap: m.columnGap }}>
          {model.players.map((p) => {
            const c = seatColor(p.seat);
            return (
              <div key={p.id} style={{ display: "flex", flexDirection: "column", flex: 1 }}>
                <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
                  <div style={{ width: 18, height: 18, background: c, display: "flex" }} />
                  <div style={{ ...D, fontSize: m.nameSize, display: "flex" }}>{p.name}</div>
                </div>

                <div style={{ display: "flex", flexDirection: "column", marginTop: 22 }}>
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
                      <div
                        style={{
                          ...D,
                          fontSize: m.numSize,
                          color: SAGE,
                          width: 34,
                          flexShrink: 0,
                          display: "flex",
                          overflow: "hidden",
                          lineHeight: 1.1,
                        }}
                      >
                        {r.pick}
                      </div>
                      <div
                        style={{
                          fontSize: m.itemSize,
                          flex: 1,
                          minWidth: 0,
                          color: BONE,
                          display: "flex",
                          overflow: "hidden",
                          textOverflow: "ellipsis",
                          whiteSpace: "nowrap",
                        }}
                      >
                        {r.item}
                      </div>
                      <div
                        style={{ ...M, fontSize: m.priceSize, color: r.gifted ? TEAL : GOLD, flexShrink: 0, display: "flex" }}
                      >
                        {r.gifted ? "free" : formatCents(r.priceCents)}
                      </div>
                    </div>
                  ))}
                </div>

                <div style={{ display: "flex", marginTop: 30, height: m.railH, width: "100%" }}>
                  <div
                    style={{
                      display: "flex",
                      width: `${(p.spentCents / Math.max(model.startingCents, 1)) * 100}%`,
                      background: c,
                    }}
                  />
                  <div
                    style={{
                      display: "flex",
                      flex: 1,
                      background: "rgba(95,123,115,0.22)",
                      borderRight: `2px solid ${c}`,
                    }}
                  />
                </div>
                <div style={{ ...M, fontSize: 24, color: SAGE, marginTop: 12, display: "flex" }}>
                  {`spent ${formatCents(p.spentCents)} of ${formatCents(model.startingCents)}`}
                </div>
              </div>
            );
          })}
        </div>

        <div style={{ display: "flex", flex: 1, minHeight: 30 }} />

        {model.topLot ? (
          <div style={{ display: "flex", gap: 10, marginBottom: 30, fontSize: 28, color: SAGE }}>
            <div style={{ display: "flex" }}>Priciest pick:</div>
            <div style={{ display: "flex", color: BONE }}>{model.topLot.item}</div>
            <div style={{ ...M, display: "flex", color: brand }}>
              {formatCents(model.topLot.priceCents)}
            </div>
            {model.longestWar && model.longestWar.raises > 1 ? (
              <div style={{ display: "flex" }}>
                {`· ${model.longestWar.item} took ${model.longestWar.raises} raises`}
              </div>
            ) : null}
          </div>
        ) : null}

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
              <div key={p.id} style={{ display: "flex", flexDirection: "column", flex: 1 }}>
                <div style={{ ...D, fontSize: 24, color: SAGE, letterSpacing: 2, display: "flex" }}>
                  {`${p.name} finished with`}
                </div>
                <div
                  style={{
                    ...M,
                    fontSize: m.totalSize,
                    lineHeight: 1,
                    color: c,
                    marginTop: 6,
                    display: "flex",
                  }}
                >
                  {formatCents(p.leftoverCents)}
                </div>
                {p.busted ? (
                  <div
                    style={{
                      ...D,
                      display: "flex",
                      justifyContent: "center",
                      marginTop: 14,
                      border: `2px solid ${KLAXON}`,
                      color: KLAXON,
                      padding: "7px 10px",
                      fontSize: 22,
                      letterSpacing: 2,
                    }}
                  >
                    BUSTED · DISQUALIFIED
                  </div>
                ) : null}
              </div>
            );
          })}
        </div>

        {/* ── the footer, which is where the watermark lives ─────────────
            watermark ON  → the DraftFor20 wordmark and the address, whatever
                            tier the host is on. This is the default and the
                            overwhelming majority of cards.
            watermark OFF → only reachable by a premium account that turned it
                            off itself, and replaced by their own logo or
                            handle if they gave us one.                      */}
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: 20,
            marginTop: 34,
            paddingTop: 26,
            borderTop: "1px solid rgba(95,123,115,0.35)",
          }}
        >
          {logo ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={logo} alt="" height={44} style={{ height: 44, objectFit: "contain" }} />
          ) : null}

          {style.watermark ? (
            <div style={{ display: "flex", alignItems: "baseline", gap: 14 }}>
              <div style={{ ...D, fontSize: 34, display: "flex" }}>DraftFor20</div>
              <div style={{ ...M, fontSize: 22, color: SAGE, display: "flex" }}>
                {SITE_URL.replace(/^https?:\/\//, "")}
              </div>
            </div>
          ) : null}

          {style.handle ? (
            <div style={{ ...D, fontSize: 30, color: brand, display: "flex" }}>{style.handle}</div>
          ) : null}

          <div style={{ ...M, fontSize: 26, color: SAGE, marginLeft: "auto", display: "flex" }}>
            {`${formatCents(model.startingCents)} each · ${model.rosterSize} players`}
          </div>
        </div>
      </div>
    ),
    {
      width: W,
      height: H,
      fonts: fonts.length ? fonts : undefined,
      headers: {
        "Content-Disposition":
          `${download ? "attachment" : "inline"}; filename="draftfor20-${model.code}.png"`,
        "Cache-Control": "no-store",
      },
    },
  );
  } catch (err) {
    // Satori is strict about layout and fails the whole render on one bad
    // node. Surface why instead of Next's blank 500 page.
    console.error("share-card render failed", err);
    return new Response(`share card failed: ${(err as Error)?.message ?? err}`, {
      status: 500,
      headers: { "content-type": "text/plain" },
    });
  }
}
