/**
 * Server-only. Step 2 of the category chain: resolve a typed name to a
 * Wikidata class, then take its best-known instances.
 *
 * Sitelink count — how many language editions have an article on the thing —
 * is the popularity signal. It is already on every entity, so ranking by it
 * costs nothing extra, and it is what turns "dog breed" into German Shepherd,
 * Labrador, Beagle instead of thirty breeds nobody has heard of.
 *
 * EVERY failure path returns null, and null means "fall through to
 * Wikipedia". Not found, ambiguous, too few instances, malformed response,
 * timeout, service outage: all the same answer to the caller, because the
 * caller's only useful question is whether it has a list.
 */

const SEARCH = "https://www.wikidata.org/w/api.php";
const SPARQL = "https://query.wikidata.org/sparql";
const UA = "DraftFor20/1.0 (https://draftfor20.vercel.app; hello@draftfor20.app)";

/** one candidate query is allowed to be slow; the whole step is not */
const QUERY_TIMEOUT_MS = 12_000;
const STEP_BUDGET_MS = 25_000;
const MAX_CANDIDATES = 5;

export interface WikidataResult {
  /** the label of the class we matched, e.g. "dog breed" */
  title: string;
  /** the Q-id, kept so the cache can record exactly what answered */
  entityId: string;
  /** instance labels, most-sitelinked first */
  items: string[];
}

/**
 * wbsearchentities is literal: "dog breeds" finds nothing while "dog breed"
 * finds the class. Plural is how people type a category, so the plural has to
 * be undone before asking.
 */
export function singularize(s: string): string[] {
  const q = s.trim().replace(/\s+/g, " ");
  const forms = new Set<string>();
  const last = q.split(" ").pop() ?? "";

  const swap = (word: string) => {
    const parts = q.split(" ");
    parts[parts.length - 1] = word;
    return parts.join(" ");
  };

  if (/ies$/i.test(last)) forms.add(swap(last.replace(/ies$/i, "y")));
  if (/(ses|xes|zes|ches|shes)$/i.test(last)) forms.add(swap(last.replace(/es$/i, "")));
  if (/[^s]s$/i.test(last)) forms.add(swap(last.replace(/s$/i, "")));
  forms.add(q); // the typed form last: singular is the better guess
  return [...forms].filter((f) => f.length > 1);
}

async function withTimeout(url: string, headers: Record<string, string>, ms: number) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), ms);
  try {
    return await fetch(url, { headers, cache: "no-store", signal: ctl.signal });
  } finally {
    clearTimeout(t);
  }
}

/** Candidate Q-ids for what the host typed, best guess first. */
async function candidates(query: string): Promise<{ id: string; label: string }[]> {
  const out: { id: string; label: string }[] = [];
  const seen = new Set<string>();

  for (const form of singularize(query)) {
    const url =
      `${SEARCH}?${new URLSearchParams({
        action: "wbsearchentities",
        search: form,
        language: "en",
        uselang: "en",
        type: "item",
        limit: "5",
        format: "json",
        origin: "*",
      })}`;
    try {
      const res = await withTimeout(url, { "User-Agent": UA }, QUERY_TIMEOUT_MS);
      if (!res.ok) continue;
      const json = (await res.json()) as {
        search?: { id: string; label?: string; description?: string }[];
      };
      for (const hit of json.search ?? []) {
        if (seen.has(hit.id)) continue;
        // a list article or a paper is not a class you can take instances of.
        // This is a cheap pre-filter; the SPARQL count is the real test.
        if (/wikimedia (list|disambiguation)|scientific article|encyclopedic article/i.test(
          hit.description ?? "",
        )) {
          continue;
        }
        seen.add(hit.id);
        out.push({ id: hit.id, label: hit.label ?? form });
        if (out.length >= MAX_CANDIDATES) return out;
      }
    } catch {
      // this form did not resolve; try the next
    }
  }
  return out;
}

/** Instances of a class, best-known first. Empty array on any failure. */
async function instancesOf(qid: string, limit: number): Promise<string[]> {
  const sparql = `SELECT ?itemLabel ?sitelinks WHERE {
  ?item wdt:P31/wdt:P279* wd:${qid} .
  ?item wikibase:sitelinks ?sitelinks .
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
}
ORDER BY DESC(?sitelinks)
LIMIT ${limit}`;

  try {
    const res = await withTimeout(
      `${SPARQL}?${new URLSearchParams({ query: sparql })}`,
      { "User-Agent": UA, Accept: "application/sparql-results+json" },
      QUERY_TIMEOUT_MS,
    );
    if (!res.ok) return [];
    const json = (await res.json()) as {
      results?: { bindings?: { itemLabel?: { value?: string } }[] };
    };
    const seen = new Set<string>();
    const items: string[] = [];
    for (const b of json.results?.bindings ?? []) {
      const label = (b.itemLabel?.value ?? "").trim();
      // an entity with no English label comes back as its own Q-id
      if (!label || /^Q\d+$/.test(label)) continue;
      if (label.length < 2 || label.length > 60) continue;
      const k = label.toLowerCase();
      if (seen.has(k)) continue;
      seen.add(k);
      items.push(label);
    }
    return items;
  } catch {
    return [];
  }
}

/**
 * The whole step. Tries each candidate class in order and takes the first
 * that yields enough instances — letting the SPARQL result decide what counts
 * as a usable class, rather than trying to read that off a description.
 *
 * Returns null if nothing resolves, which is the signal to try Wikipedia.
 */
export async function fetchWikidataCategory(
  query: string,
  minItems: number,
  keep: number,
): Promise<WikidataResult | null> {
  const deadline = Date.now() + STEP_BUDGET_MS;
  try {
    const list = await candidates(query);
    for (const c of list) {
      if (Date.now() > deadline) break; // out of time: fall through, do not hang
      const items = await instancesOf(c.id, keep);
      if (items.length >= minItems) {
        return { title: c.label, entityId: c.id, items: items.slice(0, keep) };
      }
    }
    return null;
  } catch {
    return null;
  }
}
