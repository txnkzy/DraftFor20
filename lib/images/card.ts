/**
 * Tier 7 — the floor of the image cascade, and the only tier that cannot miss.
 *
 * Every other source is a lookup that can come back empty. This one is
 * constructed from the item name, so coverage is 100% by definition. That is
 * the whole reason it exists: "every card renders" is a reachable goal in a
 * way that "every item has a photograph" is not.
 *
 * SVG rather than a raster: no image dependency in the tree, deterministic
 * output, a few hundred bytes, and it scales to the 1080×1920 stage without
 * resampling.
 *
 * COLOUR RULE: coral and gold are load-bearing elsewhere in the app — coral
 * is tension (live bid, running timer), gold is money. An item card that
 * picked them out of a hash would quietly drain both of their meaning, so the
 * generated hue is confined to 170–265° (teal through indigo), which cannot
 * collide with coral (~14°) or gold (~43°).
 */

const GROUND = "#1D2029"; // --color-surface
const INK = "#E8E6E1";
const MUTED = "#9C978E";

const W = 600;
const H = 800;

/** FNV-1a. Deterministic across processes, which a hashed colour has to be. */
function hash(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

function escapeXml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

/** Up to two initials: "Iron Man" → IM, "Groot" → G. */
export function initials(name: string): string {
  const words = name
    .replace(/[^\p{L}\p{N}\s]/gu, " ")
    .split(/\s+/)
    .filter(Boolean);
  const letters = words.slice(0, 2).map((w) => [...w][0] ?? "");
  const out = letters.join("").toUpperCase();
  return out || "?";
}

/**
 * A card for `name`. Same name always yields byte-identical output, so this
 * can be cached by name and compared in a test.
 *
 * A MONOGRAM, NOT A MINIATURE POSTER. The first version set the item name
 * inside the card and captioned it — at the size a card actually renders
 * (~150px tall) that text was about six pixels and unreadable, and the board
 * already prints the name directly underneath it. Everything that competed
 * with the initials is gone: no name, no footer, no caption. What is left is
 * legible at thumbnail size, which is the only size that matters.
 */
export function cardSvg(name: string): string {
  const h = hash(name);
  const hue = 170 + (h % 96); // 170–265: teal → indigo, never coral or gold
  const accent = `hsl(${hue} 45% 52%)`;
  const wash = `hsl(${hue} 40% 17%)`;

  const tag = escapeXml(initials(name));
  // two letters need to sit smaller than one or they run past the edges
  const size = tag.length > 1 ? 250 : 340;
  // deterministic tilt, so a wall of generated cards reads as a set rather
  // than a grid of identical rectangles
  const tilt = -24 + (((h >> 8) % 48) | 0);

  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="${escapeXml(name)}">` +
    `<rect width="${W}" height="${H}" fill="${GROUND}"/>` +
    `<g transform="rotate(${tilt} ${W / 2} ${H / 2})">` +
    `<rect x="-260" y="250" width="1120" height="300" fill="${wash}"/>` +
    `</g>` +
    `<text x="${W / 2}" y="${H / 2 - 30}" fill="${INK}" font-size="${size}" ` +
    `font-family="'Bricolage Grotesque','Instrument Sans',system-ui,sans-serif" ` +
    `font-weight="700" letter-spacing="-6" text-anchor="middle" ` +
    `dominant-baseline="central">${tag}</text>` +
    `<rect x="${W / 2 - 70}" y="${H / 2 + 150}" width="140" height="8" rx="4" fill="${accent}"/>` +
    `</svg>`
  );
}

/**
 * Inline form. URL-encoded rather than base64: an SVG is mostly ASCII already,
 * so base64 would inflate it by a third for no benefit.
 */
export function cardDataUri(name: string): string {
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(cardSvg(name))}`;
}
