/**
 * Server-only. Resolves a typed category to a list of item names by finding a
 * "List of …" article and parsing it.
 *
 * Never imported by a client component. The parsed names go straight into the
 * database and are only ever seen one card at a time, after being dealt.
 *
 * Regex rather than a DOM library on purpose: this runs on one narrow, known
 * shape of HTML, everything it produces is aggressively filtered afterwards,
 * and a parser dependency would be carried for one route.
 */

const API = "https://en.wikipedia.org/w/api.php";
const UA = "DraftFor20/1.0 (https://www.draftfor20.com; support@draftfor20.com)";

export interface WikiItem {
  /** display text, exactly as it was played before images existed */
  name: string;
  /**
   * The canonical article the list linked to, e.g. "Dr. No (film)".
   *
   * This is the only reliable key for looking an item up anywhere else: the
   * display text alone is ambiguous ("Dr. No" is a disambiguation page) and
   * often shorter than the real title. Null when the list rendered the item
   * as plain text, which is common inside table cells.
   */
  title: string | null;
}

export interface WikiResult {
  title: string;
  items: WikiItem[];
}

const JUNK = new RegExp(
  "^(references?|see also|external links?|further reading|notes?|bibliography|" +
    "sources?|citations?|contents|edit|v ?· ?t ?· ?e|category|portal|" +
    "this article|retrieved|isbn)\\b",
  "i",
);

function decode(s: string): string {
  return s
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;|&apos;|&#x27;/g, "'")
    .replace(/&ndash;/g, "-")
    .replace(/&mdash;/g, "-")
    .replace(/&#(\d+);/g, (_, d) => String.fromCharCode(Number(d)));
}

function clean(raw: string): string {
  return decode(
    raw
      .replace(/<sup\b[^>]*>[\s\S]*?<\/sup>/gi, "") // citation markers
      .replace(/<ref\b[\s\S]*?(?:\/>|<\/ref>)/gi, "")
      .replace(/<[^>]+>/g, " "),
  )
    .replace(/\[\d+\]/g, "") // leftover [1] footnotes
    .replace(/[†‡*]+\s*$/, "") // table footnote daggers
    .replace(/\([^)]*\)\s*$/, "") // trailing parenthetical qualifier
    .replace(/\s+/g, " ")
    .trim();
}

/**
 * The article a list entry points at, or null.
 *
 * Colons are NOT excluded from the match: "Star Trek: The Next Generation" is
 * a real title and dropping every href with a colon would silently lose a
 * large slice of exactly the lists people want to draft. Namespaces are
 * filtered by name afterwards instead, which is the thing the colon was a
 * proxy for. Red links point at /w/index.php rather than /wiki/, so they
 * never match in the first place.
 */
const NAMESPACE = /^(file|image|template|category|portal|help|wikipedia|special|talk|module|draft)\s*:/i;

export function linkTitle(rawHtml: string): string | null {
  const m = /<a\b[^>]*href="\/wiki\/([^"]+)"[^>]*>/i.exec(rawHtml);
  if (!m) return null;
  let t: string;
  try {
    t = decodeURIComponent(m[1].split("#")[0]);
  } catch {
    return null; // malformed percent-encoding
  }
  t = t.replace(/_/g, " ").trim();
  if (!t || NAMESPACE.test(t)) return null;
  if (/^list of\b/i.test(t)) return null;
  return t;
}

function usable(s: string): boolean {
  if (s.length < 2 || s.length > 60) return false;
  if (JUNK.test(s)) return false;
  if (/^[\d\s.,%$–-]+$/.test(s)) return false; // pure numbers / dates
  if (!/[A-Za-z]/.test(s)) return false;
  return true;
}

/**
 * Tables first, then bullets.
 *
 * A "List of X" article usually keeps the real content in a wikitable and
 * fills its bullets with navigation. Mixing both sources is what turns "List
 * of James Bond films" into a list of see-also links, so when a table carries
 * enough rows it wins outright and the bullets are ignored.
 */
export function parseArticleHtml(html: string, minItems = 1): WikiItem[] {
  let body = html
    .replace(/<table\b[^>]*class="[^"]*(infobox|navbox|metadata|sidebar|vertical-navbox)[^"]*"[\s\S]*?<\/table>/gi, "")
    .replace(/<style\b[\s\S]*?<\/style>/gi, "")
    .replace(/<ol\b[^>]*class="[^"]*references[^"]*"[\s\S]*?<\/ol>/gi, "")
    .replace(/<div\b[^>]*(role="navigation"|class="[^"]*(reflist|navbox|hatnote|thumb|toc)[^"]*")[\s\S]*?<\/div>/gi, "");

  // everything from the first appendix heading onward is not the list
  const tail = /<h2\b[^>]*>(?:(?!<\/h2>)[\s\S])*?(see also|references|external links|notes|further reading|bibliography)[\s\S]*/i;
  body = body.replace(tail, "");

  const collect = (raw: string[]) => {
    const seen = new Set<string>();
    const items: WikiItem[] = [];
    for (const r of raw) {
      // "Dr. No – the first Bond film" is a nav gloss; keep the name only
      const s = clean(r).split(/\s+[–—]\s+/)[0].trim();
      if (!usable(s)) continue;
      if (/^list of\b/i.test(s)) continue;
      const k = s.toLowerCase();
      if (seen.has(k)) continue;
      seen.add(k);
      // read the link off the ORIGINAL fragment: clean() has already thrown
      // every tag away by the time we have the display text
      items.push({ name: s, title: linkTitle(r) });
      if (items.length >= 300) break;
    }
    return items;
  };

  const fromTables: string[] = []; // raw cell HTML, so the link survives
  for (const table of body.matchAll(/<table\b[^>]*class="[^"]*wikitable[^"]*"[\s\S]*?<\/table>/gi)) {
    for (const row of table[0].matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)) {
      // a row of nothing but <th> is the header; "Title" and "Name" are not
      // items and they poison every list that has a table
      if (!/<td\b/i.test(row[1])) continue;
      const first = /<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/i.exec(row[1]);
      if (first) fromTables.push(first[1]);
    }
  }
  const tableItems = collect(fromTables);
  if (tableItems.length >= Math.max(minItems, 8)) return tableItems;

  const fromList: string[] = [];
  for (const m of body.matchAll(/<li\b[^>]*>([\s\S]*?)<\/li>/gi)) fromList.push(m[1]);
  const listItems = collect(fromList);

  return listItems.length >= tableItems.length ? listItems : tableItems;
}

/**
 * Retries on 429 and 5xx, because every caller here batches and every caller
 * swallows a failed batch. rankByPageviews scores 50 titles per request; a
 * single rate-limited batch leaves all fifty unscored, and since it sorts
 * unscored items last-but-stable the list silently degrades to the order it
 * came in. That is how an NFL category came back alphabetical, with Bailey
 * Zappe in it and Patrick Mahomes not.
 *
 * A 4xx that is not 429 is a real error and is not retried.
 */
async function api(params: Record<string, string>): Promise<unknown> {
  const url = `${API}?${new URLSearchParams({ ...params, format: "json", origin: "*" })}`;
  let last = 0;
  for (let attempt = 0; attempt < 4; attempt++) {
    const res = await fetch(url, { headers: { "User-Agent": UA }, cache: "no-store" });
    if (res.ok) return res.json();
    last = res.status;
    if (res.status !== 429 && res.status < 500) break;
    const retryAfter = Number(res.headers.get("retry-after")) || 0;
    await new Promise((r) => setTimeout(r, Math.max(retryAfter * 1000, 800 * (attempt + 1))));
  }
  throw new Error(`wikipedia ${last}`);
}

/** null whenever anything is missing, malformed, or too thin to play with. */
export async function fetchCategory(query: string, minItems: number): Promise<WikiResult | null> {
  try {
    const search = (await api({
      action: "query",
      list: "search",
      srsearch: `List of ${query}`,
      srlimit: "3",
    })) as { query?: { search?: { title: string }[] } };

    const hits = (search.query?.search ?? []).slice().sort((a, b) => {
      // an article actually titled "List of …" beats an incidental match
      const la = /^list of/i.test(a.title) ? 0 : 1;
      const lb = /^list of/i.test(b.title) ? 0 : 1;
      return la - lb;
    });
    for (const hit of hits) {
      // a disambiguation page has no list to parse; skip rather than mangle
      if (/\(disambiguation\)/i.test(hit.title)) continue;

      const page = (await api({ action: "parse", page: hit.title, prop: "text" })) as {
        parse?: { text?: { "*"?: string } };
      };
      const html = page.parse?.text?.["*"];
      if (!html) continue;

      const items = parseArticleHtml(html, minItems);
      if (items.length >= minItems) return { title: hit.title, items };
    }
    return null;
  } catch {
    // fetch failed, JSON was not what we expected, article vanished: all the
    // same answer to the caller, which is "no result"
    return null;
  }
}

/* ── popularity, batched ───────────────────────────────────────────────────
   A parsed "List of X" article is in article order, which has nothing to do
   with whether anybody recognises the entries. This ranks them by how much
   the English Wikipedia article for each is actually read.

   action=query&prop=pageviews takes FIFTY titles per request and answers with
   60 days of dailies for each, so a 200-item list costs four calls rather
   than two hundred. It also marks a title `missing` when there is no article
   at all, which is the same signal as "nobody can look this up" — those sink
   below anything with a real number instead of being dropped, so a list of
   otherwise unmeasurable items still produces a playable pool.            */

export interface RankedItems {
  items: string[];
  /** false when pageviews could not be consulted and length order was used */
  filtered: boolean;
}

const PV_BATCH = 50;

export async function rankByPageviews(items: string[], keep: number): Promise<RankedItems> {
  if (items.length <= keep) return { items, filtered: false };

  const views = new Map<string, number>();
  let answered = false;

  for (let i = 0; i < items.length; i += PV_BATCH) {
    const batch = items.slice(i, i + PV_BATCH);
    try {
      const data = (await api({
        action: "query",
        prop: "pageviews",
        titles: batch.join("|"),
        formatversion: "2",
      })) as {
        query?: {
          pages?: { title?: string; missing?: boolean; pageviews?: Record<string, number | null> }[];
          normalized?: { from: string; to: string }[];
        };
      };

      // the API normalises titles ("tom brady" -> "Tom Brady"), so the answer
      // has to be mapped back to the string we asked about
      const back = new Map<string, string>();
      for (const n of data.query?.normalized ?? []) back.set(n.to, n.from);

      for (const p of data.query?.pages ?? []) {
        const title = p.title ?? "";
        const asked = back.get(title) ?? title;
        if (p.missing) continue; // no article: leave it unscored
        const total = Object.values(p.pageviews ?? {}).reduce<number>(
          (t, v) => t + (v ?? 0),
          0,
        );
        views.set(asked, total);
        answered = true;
      }
    } catch {
      // one bad batch does not sink the list; carry on with what we have
    }
  }

  // Nothing came back at all — API down, rate limited, or a list of things
  // Wikipedia has no articles for. Fall back to the parsed order, capped, and
  // say so, because a silent fallback-of-a-fallback is one nobody ever fixes.
  if (!answered) return { items: items.slice(0, keep), filtered: false };

  const ranked = [...items].sort((a, b) => (views.get(b) ?? -1) - (views.get(a) ?? -1));
  return { items: ranked.slice(0, keep), filtered: true };
}
