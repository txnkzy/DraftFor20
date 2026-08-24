/**
 * Server-only. The individual image sources, each reduced to "give me a URL
 * or give me null".
 *
 * Only keyless sources live here. TMDB (film/TV) and IGDB (games) are the two
 * that would raise coverage most, and both want an API key — they slot in as
 * extra branches in resolve.ts without changing its shape.
 */

const UA = "DraftFor20/1.0 (https://draftfor20.vercel.app; hello@draftfor20.app)";
const WP = "https://en.wikipedia.org/w/api.php";

/** Free (Commons) or non-free (local en-wiki fair-use upload). */
export type License = "free" | "nonfree" | "generated";

/**
 * Which bucket a Wikimedia URL is in, read off the path.
 *
 *   upload.wikimedia.org/wikipedia/commons/…  → freely licensed
 *   upload.wikimedia.org/wikipedia/en/…       → non-free, fair-use rationale
 *
 * This distinction is the entire licensing story for Wikipedia images and it
 * is machine-readable, so nothing here has to guess.
 */
export function licenseOf(url: string): License {
  return /\/wikipedia\/commons\//.test(url) ? "free" : "nonfree";
}

/** Run `fn` over `xs` with at most `n` in flight. */
export async function mapLimit<T, R>(
  xs: T[],
  n: number,
  fn: (x: T) => Promise<R>,
): Promise<R[]> {
  const out = new Array<R>(xs.length);
  let i = 0;
  const workers = Array.from({ length: Math.min(n, xs.length) }, async () => {
    for (;;) {
      const k = i++;
      if (k >= xs.length) return;
      out[k] = await fn(xs[k]);
    }
  });
  await Promise.all(workers);
  return out;
}

/**
 * Does this URL actually serve an image?
 *
 * Cover Art Archive and Open Library both answer a miss with a redirect or a
 * placeholder rather than an error, so a URL that was merely *constructed*
 * cannot be trusted. A generated card beats a broken <img>.
 */
async function serves(url: string): Promise<boolean> {
  try {
    const res = await fetch(url, {
      method: "HEAD",
      redirect: "follow",
      headers: { "User-Agent": UA },
      cache: "no-store",
    });
    return res.ok && (res.headers.get("content-type") ?? "").startsWith("image/");
  } catch {
    return false;
  }
}

/**
 * Wikipedia lead images, 50 titles per request.
 *
 * pilicense=any is deliberate and consequential: the default is `free`, which
 * returns NOTHING for films, clubs, albums or characters, because those lead
 * images are all fair-use uploads. Callers get the licence alongside the URL
 * and decide what they are willing to serve — see licenseOf.
 */
export async function pageImages(
  titles: string[],
): Promise<Map<string, { url: string; license: License }>> {
  const out = new Map<string, { url: string; license: License }>();
  for (let i = 0; i < titles.length; i += 50) {
    const params = new URLSearchParams({
      action: "query",
      titles: titles.slice(i, i + 50).join("|"),
      prop: "pageimages",
      piprop: "thumbnail",
      pithumbsize: "800",
      pilimit: "50",
      pilicense: "any",
      redirects: "1",
      format: "json",
    });
    try {
      const res = await fetch(`${WP}?${params}`, {
        headers: { "User-Agent": UA },
        cache: "no-store",
      });
      if (!res.ok) continue;
      const json = (await res.json()) as {
        query?: {
          pages?: Record<string, { title?: string; thumbnail?: { source?: string } }>;
          normalized?: { from: string; to: string }[];
          redirects?: { from: string; to: string }[];
        };
      };
      const alias = new Map<string, string>();
      for (const r of json.query?.normalized ?? []) alias.set(r.to, r.from);
      for (const r of json.query?.redirects ?? []) alias.set(r.to, alias.get(r.from) ?? r.from);

      for (const p of Object.values(json.query?.pages ?? {})) {
        const src = p.thumbnail?.source;
        if (!p.title || !src) continue;
        // the tracking querystring Wikipedia appends is noise in a stored URL
        const url = src.split("?")[0];
        out.set(alias.get(p.title) ?? p.title, { url, license: licenseOf(url) });
      }
    } catch {
      // a failed batch costs those items their image, nothing more
    }
  }
  return out;
}

/** Album art from the Cover Art Archive, keyed by MusicBrainz release group. */
export async function coverArt(mbid: string): Promise<string | null> {
  const url = `https://coverartarchive.org/release-group/${encodeURIComponent(mbid)}/front-500`;
  return (await serves(url)) ? url : null;
}

/** Book jackets from Open Library. default=false turns a miss into a 404. */
export async function openLibrary(isbn: string): Promise<string | null> {
  const clean = isbn.replace(/[^0-9Xx]/g, "");
  if (!clean) return null;
  const url = `https://covers.openlibrary.org/b/isbn/${clean}-L.jpg?default=false`;
  return (await serves(url)) ? url : null;
}
