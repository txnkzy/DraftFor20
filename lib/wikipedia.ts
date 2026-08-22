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
const UA = "DraftFor20/1.0 (https://draftfor20.vercel.app; hello@draftfor20.app)";

export interface WikiResult {
  title: string;
  items: string[];
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
export function parseArticleHtml(html: string, minItems = 1): string[] {
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
    const items: string[] = [];
    for (const r of raw) {
      // "Dr. No – the first Bond film" is a nav gloss; keep the name only
      const s = clean(r).split(/\s+[–—]\s+/)[0].trim();
      if (!usable(s)) continue;
      if (/^list of\b/i.test(s)) continue;
      const k = s.toLowerCase();
      if (seen.has(k)) continue;
      seen.add(k);
      items.push(s);
      if (items.length >= 300) break;
    }
    return items;
  };

  const fromTables: string[] = [];
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

async function api(params: Record<string, string>): Promise<unknown> {
  const url = `${API}?${new URLSearchParams({ ...params, format: "json", origin: "*" })}`;
  const res = await fetch(url, { headers: { "User-Agent": UA }, cache: "no-store" });
  if (!res.ok) throw new Error(`wikipedia ${res.status}`);
  return res.json();
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
