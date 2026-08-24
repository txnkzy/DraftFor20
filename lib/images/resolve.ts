/**
 * Server-only. The image cascade.
 *
 * GUARANTEE: the returned array is the same length as the input, in the same
 * order, and every entry has a usable `url`. No item is ever dropped for
 * lacking a picture, because the last tier constructs one. Callers can treat
 * an image as always present.
 *
 * Tiers, most recognisable first:
 *
 *   1  Cover Art Archive       exact by MBID, IS the cover    (albums)
 *   2  Open Library            exact by ISBN, IS the jacket   (books)
 *   -  TMDB / IGDB             NOT WIRED — both want a key    (films, TV, games)
 *   3  Wikipedia pageimages    the infobox lead, often NON-FREE
 *   4  Wikidata P18/P154/P41   free-licensed, but uncurated
 *   5  Generated card          cannot miss
 *
 * ORDERING IS DELIBERATE AND WAS WRONG ONCE. Putting the free-licensed tier
 * first looks safer and produces a deck nobody can play: P18 for Captain
 * America is a photograph of a science museum in Valencia, for Cardiff City
 * it is the stadium exterior, for Dr. No a Russian title-card screengrab.
 * `pageimages` returns the article's infobox lead — the image editors picked
 * precisely BECAUSE it is the recognisable one — so it goes first and P18
 * becomes the free fallback behind it.
 *
 * Licensing is therefore a policy flag rather than an ordering: `freeOnly`
 * drops every fair-use result and takes the free-or-generated path instead.
 * That is the conservative setting for a product that charges money, and it
 * knowingly trades away recognisability to get there.
 *
 * LEAK RULE: this resolves a whole deck at once and must only ever run
 * server-side, at deck build time. An image URL is as much of a tell as a
 * name — prefetching the next card's picture in the browser would leak an
 * undealt item just as surely as naming it.
 */

import type { WikiItem } from "../wikipedia";
import { cardDataUri } from "./card";
import { coverArt, mapLimit, openLibrary, pageImages, type License } from "./sources";
import { commonsUrl, entitiesFor, qidsFor, type Entity } from "./wikidata";

export type { License };

export interface ResolvedImage {
  name: string;
  url: string;
  license: License;
  /** which tier produced it, for debugging a deck that looks wrong */
  source: "wikidata" | "coverart" | "openlibrary" | "pageimages" | "generated";
}

export interface ResolveOptions {
  /**
   * Reject fair-use images. Items that only had a non-free option get a
   * generated card instead. Defaults to false, which serves them.
   */
  freeOnly?: boolean;
  /** Concurrent outbound requests for the per-item tiers. */
  concurrency?: number;
}

export async function resolveImages(
  items: WikiItem[],
  opts: ResolveOptions = {},
): Promise<ResolvedImage[]> {
  const { freeOnly = false, concurrency = 6 } = opts;
  const out = new Array<ResolvedImage | null>(items.length).fill(null);

  // The article title is the lookup key. When the list rendered an item as
  // plain text we fall back to its display name, which MediaWiki will
  // normalise and follow redirects for — a guess, but a cheap and usually
  // correct one.
  const keys = items.map((it) => (it.title ?? it.name).trim());

  const unique = [...new Set(keys)];

  // Wikidata and pageimages are INDEPENDENT, so they overlap. The Wikidata
  // leg is itself two sequential calls (titles -> QIDs -> claims); running
  // the generalist lookup beside it rather than after removes a whole
  // round-trip from every category, in the dev browser and in production.
  const loadEntities = async () => {
    const out = new Map<number, Entity>();
    try {
      const qids = await qidsFor(unique);
      const byQid = await entitiesFor([...new Set([...qids.values()])]);
      keys.forEach((k, i) => {
        const q = qids.get(k);
        const e = q ? byQid.get(q) : undefined;
        if (e) out.set(i, e);
      });
    } catch {
      /* no router; everything falls through to the generalist tier */
    }
    return out;
  };

  const [entities, pageHits] = await Promise.all([
    loadEntities(),
    pageImages(unique).catch(() => new Map<string, { url: string; license: License }>()),
  ]);

  // ── tiers 1–2: specialists, dispatched by the kind Wikidata reported ────
  const specialists = [...entities.entries()].filter(
    ([, e]) =>
      (e.kind === "album" && e.musicbrainzReleaseGroup) || (e.kind === "book" && e.isbn13),
  );

  await mapLimit(specialists, concurrency, async ([i, e]) => {
    if (e.kind === "album" && e.musicbrainzReleaseGroup) {
      const url = await coverArt(e.musicbrainzReleaseGroup);
      if (url) out[i] = { name: items[i].name, url, license: "free", source: "coverart" };
      return;
    }
    if (e.kind === "book" && e.isbn13) {
      // Open Library jackets are publisher artwork, not freely licensed, so
      // freeOnly has to skip them even though serving them is unremarkable.
      if (freeOnly) return;
      const url = await openLibrary(e.isbn13);
      if (url) out[i] = { name: items[i].name, url, license: "nonfree", source: "openlibrary" };
    }
  });

  // ── tier 3: the infobox lead — the most recognisable image available ────
  // Already fetched above, in parallel with Wikidata. It is applied here, in
  // priority order, so overlapping the requests did not reorder the tiers.
  keys.forEach((k, i) => {
    if (out[i]) return;
    const hit = pageHits.get(k);
    if (!hit) return;
    if (freeOnly && hit.license === "nonfree") return;
    out[i] = { name: items[i].name, url: hit.url, license: hit.license, source: "pageimages" };
  });

  // ── tier 4: Wikidata's free image, as a fallback rather than a first
  //    choice. It is frequently oblique — a club's stadium, a character's
  //    convention statue — so it earns a slot only where nothing better
  //    survived, and it is the ONLY visual tier left when freeOnly is on.
  for (const [i, e] of entities) {
    if (out[i] || !e.freeImage) continue;
    out[i] = {
      name: items[i].name,
      url: commonsUrl(e.freeImage),
      license: "free",
      source: "wikidata",
    };
  }

  // ── tier 5: the floor. This is what makes the return value total. ───────
  return out.map((r, i) =>
    r ?? {
      name: items[i].name,
      url: cardDataUri(items[i].name),
      license: "generated" as const,
      source: "generated" as const,
    },
  );
}
