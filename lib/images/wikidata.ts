/**
 * Server-only. Turns an article title into a classified entity.
 *
 * Wikidata is the router for the whole image cascade. One request per batch
 * gives us three things at once:
 *
 *   1. a KIND ("film", "album", "club") from P31, so the item can be sent to
 *      the source that actually specialises in it
 *   2. a free-licensed image from P18/P154/P41, which is the only kind of
 *      image that is unambiguously safe to serve
 *   3. external IDs (TMDB, MusicBrainz, ISBN) so the specialist lookup is an
 *      exact fetch rather than a name search that can land on the wrong thing
 *
 * Point 3 is why this sits in front of the specialist tiers rather than
 * beside them. Searching TMDB for "Iron Man" is a guess; fetching TMDB movie
 * 1726 because Wikidata says so is not.
 */

const WD = "https://www.wikidata.org/w/api.php";
const WP = "https://en.wikipedia.org/w/api.php";
const UA = "DraftFor20/1.0 (https://draftfor20.vercel.app; hello@draftfor20.app)";

/** How many titles the MediaWiki API accepts in one titles= / ids= call. */
export const BATCH = 50;

export type Kind =
  | "film"
  | "tv"
  | "game"
  | "album"
  | "book"
  | "club"
  | "person"
  | "place"
  | "other";

/**
 * P31 → kind. Only the entries that change routing are listed; anything
 * unrecognised falls to "other" and takes the generalist path, which is the
 * correct outcome rather than a gap.
 */
const KIND_BY_P31: Record<string, Kind> = {
  Q11424: "film",
  Q24869: "film", // feature film
  Q506240: "film", // television film
  Q5398426: "tv",
  Q117467246: "tv",
  Q7889: "game",
  Q7058673: "game", // video game series
  Q482994: "album",
  Q208569: "album", // studio album
  Q134556: "album", // single — same artwork source
  Q571: "book",
  Q7725634: "book", // literary work
  Q47461344: "book", // written work
  Q476028: "club", // association football club
  Q17156793: "club", // sports team
  Q5: "person",
  Q3624078: "place", // sovereign state
  Q515: "place", // city
  Q46169: "place", // national park (US)
  Q34918903: "place",
};

export interface Entity {
  qid: string;
  kind: Kind;
  /** Commons filename from P18/P154/P41/P94, already URL-ready. */
  freeImage: string | null;
  tmdbMovie: string | null;
  musicbrainzReleaseGroup: string | null;
  isbn13: string | null;
}

async function get(url: string): Promise<unknown> {
  const res = await fetch(url, { headers: { "User-Agent": UA }, cache: "no-store" });
  if (!res.ok) throw new Error(`wikidata ${res.status}`);
  return res.json();
}

/**
 * Commons filename to a served URL.
 *
 * Special:FilePath redirects to the current file, so we never have to
 * reproduce Commons' md5 bucket layout — which is derived from the filename
 * and silently wrong the moment a file is renamed.
 */
export function commonsUrl(filename: string, width = 800): string {
  return `https://commons.wikimedia.org/wiki/Special:FilePath/${encodeURIComponent(
    filename,
  )}?width=${width}`;
}

/** Article titles → QIDs, in batches. Titles with no Wikidata item are absent. */
export async function qidsFor(titles: string[]): Promise<Map<string, string>> {
  const out = new Map<string, string>();
  for (let i = 0; i < titles.length; i += BATCH) {
    const slice = titles.slice(i, i + BATCH);
    const params = new URLSearchParams({
      action: "query",
      prop: "pageprops",
      ppprop: "wikibase_item",
      titles: slice.join("|"),
      redirects: "1",
      format: "json",
    });
    let json: {
      query?: {
        pages?: Record<string, { title?: string; pageprops?: { wikibase_item?: string } }>;
        // a redirect means the title we asked for is not the title we got back
        normalized?: { from: string; to: string }[];
        redirects?: { from: string; to: string }[];
      };
    };
    try {
      json = (await get(`${WP}?${params}`)) as typeof json;
    } catch {
      continue; // a failed batch is missing images, never a failed draft
    }

    // Rebuild the asked-for → returned mapping so callers can look up by the
    // title they supplied. Without this every redirected item silently
    // detaches from its own image.
    const alias = new Map<string, string>();
    for (const r of json.query?.normalized ?? []) alias.set(r.to, r.from);
    for (const r of json.query?.redirects ?? []) alias.set(r.to, alias.get(r.from) ?? r.from);

    for (const p of Object.values(json.query?.pages ?? {})) {
      const qid = p.pageprops?.wikibase_item;
      if (!p.title || !qid) continue;
      out.set(alias.get(p.title) ?? p.title, qid);
    }
  }
  return out;
}

function claimString(claims: Record<string, unknown[]> | undefined, prop: string): string | null {
  const c = claims?.[prop]?.[0] as
    | { mainsnak?: { datavalue?: { value?: unknown } } }
    | undefined;
  const v = c?.mainsnak?.datavalue?.value;
  return typeof v === "string" ? v : null;
}

function claimIds(claims: Record<string, unknown[]> | undefined, prop: string): string[] {
  const list = (claims?.[prop] ?? []) as { mainsnak?: { datavalue?: { value?: { id?: string } } } }[];
  return list.map((c) => c.mainsnak?.datavalue?.value?.id).filter((x): x is string => !!x);
}

/** QIDs → entities. Unknown QIDs are simply absent from the result. */
export async function entitiesFor(qids: string[]): Promise<Map<string, Entity>> {
  const out = new Map<string, Entity>();
  for (let i = 0; i < qids.length; i += BATCH) {
    const params = new URLSearchParams({
      action: "wbgetentities",
      ids: qids.slice(i, i + BATCH).join("|"),
      props: "claims",
      format: "json",
    });
    let json: { entities?: Record<string, { claims?: Record<string, unknown[]> }> };
    try {
      json = (await get(`${WD}?${params}`)) as typeof json;
    } catch {
      continue;
    }
    for (const [qid, ent] of Object.entries(json.entities ?? {})) {
      const claims = ent.claims;
      // first recognised P31 wins; an item is often several things at once
      // ("Iron Man" is a comics character AND a fictional human) and the
      // ordering in Wikidata puts the most specific first
      let kind: Kind = "other";
      for (const id of claimIds(claims, "P31")) {
        if (KIND_BY_P31[id]) {
          kind = KIND_BY_P31[id];
          break;
        }
      }
      const free =
        claimString(claims, "P18") ?? // image
        claimString(claims, "P154") ?? // logo
        claimString(claims, "P41") ?? // flag
        claimString(claims, "P94"); // coat of arms

      out.set(qid, {
        qid,
        kind,
        freeImage: free,
        tmdbMovie: claimString(claims, "P4947"),
        musicbrainzReleaseGroup: claimString(claims, "P436"),
        isbn13: claimString(claims, "P212"),
      });
    }
  }
  return out;
}
