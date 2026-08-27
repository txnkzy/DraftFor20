/**
 * A TOOL, NOT A TEST. Regenerates supabase/migrations/0051_library_pictures.sql.
 *
 *   LIB=1 npx vitest run lib/library.seed.test.ts
 *
 * Gives every remaining shelf category a picture, and trims the ones that are
 * a matter of taste down to what people actually recognise.
 *
 * TWO KINDS OF CATEGORY, and treating them the same would be a bug:
 *
 *   complete   US States, NFL/NBA/MLB Teams. The set IS the category. Ranking
 *              Wyoming below California and cutting it would be wrong — every
 *              member stays, images are the only thing being added.
 *   ranked     Superheroes, Board Games, Songs, Movie Villains. These are
 *              opinions, so the tail is dead weight and gets cut by traffic.
 *
 * The item lists come from the DATABASE rather than being retyped here, via
 * df20_library_items (0045) and the dev secret. Retyping 1,127 names to add a
 * picture to each would be a fresh chance to get one wrong.
 *
 * An item with no picture is DROPPED rather than kept with a generated card:
 * the whole point of this pass is that every card in these categories has
 * real art. Categories are skipped, loudly, if that leaves them too small.
 */
import { writeFileSync } from "node:fs";
import { it } from "vitest";
import { createClient } from "@supabase/supabase-js";
import { resolveImages } from "./images/resolve";
import { rankByPageviews } from "./wikipedia";

interface Cfg {
  category: string;
  /** the set is the category; keep every member, only add pictures */
  complete?: boolean;
  /** how many to keep when ranked */
  keep?: number;
  /** appended to the lookup where a bare name lands on the wrong article */
  hint?: string;
}

const CATS: Cfg[] = [
  // complete sets — every member stays
  { category: "US States", complete: true, hint: "U.S. state" },
  { category: "NFL Teams", complete: true, hint: "NFL team" },
  { category: "NBA Teams", complete: true, hint: "NBA team" },
  { category: "MLB Teams", complete: true, hint: "baseball team" },

  // ranked — the tail is dead weight
  { category: "Superheroes", keep: 40, hint: "comics superhero character" },
  { category: "Movie Villains", keep: 40, hint: "fictional villain character" },
  { category: "Disney Animated Movies", keep: 40, hint: "Disney animated film" },
  { category: "TV Sitcoms", keep: 40, hint: "television sitcom" },
  { category: "Video Game Franchises", keep: 40, hint: "video game" },
  { category: "Board Games", keep: 36, hint: "board game" },
  { category: "Dog Breeds", keep: 40, hint: "dog breed" },
  { category: "90s Songs", keep: 40, hint: "song" },
  { category: "2000s Songs", keep: 40, hint: "song" },
  { category: "Breakfast Cereals", keep: 36, hint: "breakfast cereal" },
  { category: "Soft Drinks", keep: 36, hint: "soft drink" },
  { category: "Ice Cream Flavors", keep: 30, hint: "ice cream flavor" },
  { category: "Pizza Toppings", keep: 30, hint: "food ingredient" },
  { category: "Chip Flavors", keep: 24, hint: "potato chip flavor" },
  { category: "Halloween Candy", keep: 36, hint: "candy" },
];

/**
 * The article for a name the bare lookup could not place.
 *
 * THE FAMOUS ITEMS ARE THE AMBIGUOUS ONES, which is why this exists. A direct
 * pageimages lookup finds Wyoming and misses New York; it finds Pepperoni and
 * misses Sprite, Dr Pepper, Cheerios, Halo, Doom, Frozen and Black Panther —
 * because those bare titles belong to a US city, a mythical creature, a
 * spice, a video game engine, an emotion and an animal. Dropping every item
 * the lookup could not place would have quietly deleted the best half of the
 * shelf.
 *
 * Only run for items that already FAILED, so it costs a couple of hundred
 * searches rather than one per item.
 */
/** lowercase, strip the disambiguating parenthetical and punctuation */
function norm(s: string): string {
  return s
    .replace(/\s*\([^)]*\)\s*$/, "")
    .toLowerCase()
    .replace(/[^a-z0-9 ]/g, "")
    .replace(/\s+/g, " ")
    .trim();
}

async function searchTitle(name: string, hint: string): Promise<string | null> {
  const params = new URLSearchParams({
    action: "query", list: "search", srsearch: `${name} ${hint}`,
    srlimit: "5", format: "json",
  });
  for (let a = 0; a < 3; a++) {
    try {
      const r = await fetch(`https://en.wikipedia.org/w/api.php?${params}`, {
        headers: { "User-Agent": "DraftFor20/1.0 (https://draftfor20.vercel.app; hello@draftfor20.app)" },
      });
      if (!r.ok) { await new Promise((x) => setTimeout(x, 800 * (a + 1))); continue; }
      const j = (await r.json()) as { query?: { search?: { title: string }[] } };
      // THE TITLE HAS TO BE ABOUT THE THING WE ASKED FOR. Taking hits[0]
      // blindly is how "Batman comics superhero character" came back as
      // Barbara Gordon, Hulk as Abomination, Deadpool as Yukio and Loki as
      // Hela: the search is ranking articles that MENTION the terms, and a
      // sibling character mentions all of them. Same failure as espn.ts
      // returning Terrell Davis for Miles Davis.
      const key = norm(name);
      const hits = (j.query?.search ?? [])
        .map((h) => h.title)
        .filter((t) => !/\(disambiguation\)|^List of /i.test(t))
        .filter((t) => {
          const base = norm(t);
          return base === key || base.startsWith(key + " ") || base.includes(key);
        });

      // PREFER AN EXACT TITLE. Search relevance is not the same as "is the
      // thing", and hits[0] kept being a remake or a sibling: The Lion King,
      // Dumbo, Mulan, The Jungle Book and Lady and the Tramp all came back as
      // the LIVE-ACTION versions in a category called Disney ANIMATED Movies,
      // Beauty and the Beast as a direct-to-video sequel, and Aladdin as the
      // television series. Wikipedia gives the original the bare title and
      // pushes everything else into a parenthetical, so an exact match on the
      // bare name is exactly the discriminator we want.
      const exact = hits.filter((t) => norm(t) === key && !/\(/.test(t));
      const parenthesised = hits.filter((t) => norm(t) === key);
      return exact[0] ?? parenthesised[0] ?? hits[0] ?? null;
    } catch {
      await new Promise((x) => setTimeout(x, 800 * (a + 1)));
    }
  }
  return null;
}

/**
 * Items where even an exact-title search lands on the wrong thing, because
 * the bare title belongs to a namesake rather than to a remake.
 *
 *   Scar      the bare article is Fullmetal Alchemist's
 *   Beast     search finds DC's Bwana Beast before Marvel's Hank McCoy
 *   Checkers  resolves to CHINESE checkers, a different game entirely
 */
/**
 * Items whose ARTICLE has no lead image at all, so no amount of title
 * resolution helps — the search then wanders off and Captain America came
 * back as a science museum in Valencia.
 */
const FORCE_IMAGE: Record<string, string> = {
  "Captain America":
    "https://upload.wikimedia.org/wikipedia/en/9/9c/Captain_America_Comics-1_%28March_1941_Timely_Comics%29.jpg",
};

const FORCE_TITLE: Record<string, string> = {
  "Scar": "Scar (The Lion King)",
  "Beast": "Beast (Marvel Comics)",
  "Checkers": "Draughts",
  "Batman": "Batman",
  "Hades": "Hades (Disney)",
  // the bare titles are the 1894 book and the 2020 remake
  "The Jungle Book": "The Jungle Book (1967 film)",
  "Mulan": "Mulan (1998 film)",
};

const FLOOR = 24;

/**
 * Built lazily. At module scope createClient() throws "supabaseUrl is
 * required" the moment vitest COLLECTS this file, which fails the ordinary
 * suite even though the test itself is skipped without LIB=1.
 */
let _sb: ReturnType<typeof createClient> | null = null;
function db() {
  if (!_sb) {
    _sb = createClient(
      process.env.NEXT_PUBLIC_SUPABASE_URL!,
      process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
      { auth: { persistSession: false } },
    );
  }
  return _sb;
}

async function itemsOf(category: string): Promise<string[]> {
  const { data, error } = await db().rpc("df20_library_items", {
    p_secret: process.env.DF20_DEV_SECRET,
    p_query: category,
  });
  if (error || !data) throw new Error(`${category}: ${error?.message ?? "no rows"}`);
  const hit = data as { name: string; items: { name: string }[] };
  return (hit.items ?? []).map((i) => i.name);
}

it.runIf(!!process.env.LIB)("library", { timeout: 3_600_000 }, async () => {
  const built: { category: string; picked: { name: string; url: string }[] }[] = [];
  const log: string[] = [];

  for (const cfg of CATS) {
    let names: string[];
    try {
      names = await itemsOf(cfg.category);
    } catch (e) {
      log.push(`${cfg.category}: COULD NOT READ — ${(e as Error).message}`);
      continue;
    }

    // SEARCH FIRST FOR ANYTHING THAT IS A NAME RATHER THAN A THING.
    //
    // A bare-name lookup does not fail loudly when it is wrong, it just
    // returns the wrong article's picture: Cyclops came back as a Greek
    // statue in the Colosseum, Wolverine as the ANIMAL, Captain America as a
    // science museum in Valencia, Nirvana's "Lithium" as the chemical element
    // and The Cranberries' "Zombie" as Haitian folklore. Every one of those
    // passed the not-generated check and the distinct-image check, because a
    // wrong picture is still a picture and still unique.
    //
    // Complete sets are exempt: "Alabama" and "Dallas Cowboys" are exact, and
    // pass 1 was verified to give flags and team logos for all 142 of them.
    const searchFirst = !cfg.complete && !!cfg.hint;
    let first: Awaited<ReturnType<typeof resolveImages>>;
    if (searchFirst) {
      const titles = new Map<string, string>();
      for (const n of names) {
        const t = FORCE_TITLE[n] ?? (await searchTitle(n, cfg.hint!));
        if (t) titles.set(n, t);
        await new Promise((r) => setTimeout(r, 150));
      }
      first = await resolveImages(names.map((n) => ({ name: n, title: titles.get(n) ?? n })));
    } else {
      first = await resolveImages(names.map((n) => ({ name: n, title: n })));
    }

    // pass 2: search for whatever is still unplaced (only useful when pass 1
    // was the bare-name path; a searched miss will not improve by re-searching)
    const stuck = searchFirst ? [] : names.filter((_, i) => first[i].source === "generated");
    const found = new Map<string, string>();
    for (const n of stuck) {
      const t = cfg.hint ? await searchTitle(n, cfg.hint) : null;
      if (t) found.set(n, t);
      await new Promise((r) => setTimeout(r, 150));
    }
    const second = found.size
      ? await resolveImages([...found.entries()].map(([n, t]) => ({ name: n, title: t })))
      : [];
    const rescued = new Map<string, (typeof second)[number]>();
    [...found.keys()].forEach((n, i) => { if (second[i]) rescued.set(n, second[i]); });

    const imgs = names.map((n, i) => {
      const r = first[i];
      if (r.source !== "generated") return r;
      return rescued.get(n) ?? r;
    });

    const withArt: { name: string; url: string }[] = [];
    const seenUrl = new Set<string>();
    const missing: string[] = [];
    for (let i = 0; i < names.length; i++) {
      const r = imgs[i];
      if (r.source === "generated") { missing.push(names[i]); continue; }
      // a shared picture means the lookup collapsed several items onto one
      // article, which on a board looks like a bug
      if (seenUrl.has(r.url)) { missing.push(`${names[i]} (dup)`); continue; }
      if (/[\n\r$]/.test(names[i]) || /[\n\r$]/.test(r.url)) continue;
      seenUrl.add(r.url);
      withArt.push({ name: names[i], url: r.url });
    }

    let picked = withArt;
    if (!cfg.complete) {
      // rank on the names that survived, then cut. rankByPageviews returns
      // fame order; it only started telling the truth once it learned to
      // follow the API's continuation token.
      const byName = new Map(withArt.map((w) => [w.name, w]));
      const ranked = await rankByPageviews([...byName.keys()], cfg.keep ?? 40);
      picked = ranked.items.map((n) => byName.get(n)!).filter(Boolean);
    }

    log.push(
      `${cfg.category.padEnd(24)} ${String(picked.length).padStart(3)}/${String(names.length).padStart(3)}` +
      `${cfg.complete ? "  [complete]" : "  [ranked]"}` +
      (missing.length ? `  no picture: ${missing.slice(0, 8).join(", ")}${missing.length > 8 ? ` +${missing.length - 8}` : ""}` : ""),
    );

    if (picked.length < FLOOR) { log.push(`   SKIPPED — under ${FLOOR}`); continue; }
    built.push({ category: cfg.category, picked });
    await new Promise((r) => setTimeout(r, 1500));
  }

  writeFileSync("/tmp/library-seed.txt", log.join("\n"));
  if (!built.length) throw new Error("nothing built");

  const blocks = built.map((b) => `
-- ── ${b.category} · ${b.picked.length} items
select public.df20_seed_category(
  '${b.category.replace(/'/g, "''")}',
  string_to_array($it$${b.picked.map((p) => p.name).join("\n")}$it$, E'\\n'),
  string_to_array($im$${b.picked.map((p) => p.url).join("\n")}$im$, E'\\n'),
  array_fill('nonfree'::text, array[${b.picked.length}]));
`).join("");

  const sql = `-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0051 · a picture on every remaining shelf category
--
-- GENERATED by lib/library.seed.test.ts. Names and URLs are positional.
--
-- Completes what 0049 and 0050 started: the shelf had 20 categories that were
-- names alone, so every card in them drew a generated placeholder.
--
-- COMPLETE vs RANKED. US States and the three team categories keep every
-- member — the set IS the category, and cutting Wyoming for having less
-- traffic than California would be wrong. Everything else is a matter of
-- taste, so the tail is cut by real Wikipedia traffic.
--
-- 'nonfree' throughout: box art, album covers, logos and film stills are the
-- rights holder's. Same footing as the anime categories in 0044/0046, unlike
-- the Commons-only sports photographs in 0049.
--
-- Re-runnable. The delete matters — df20_seed_category upserts and never
-- removes, so re-seeding a shortened list would leave the old tail behind.
-- ═══════════════════════════════════════════════════════════════════════════

delete from public.category_library_items i
 using public.category_library l
 where l.id = i.library_id
   and l.name_norm in (${built.map((b) => `public.df20_norm_category('${b.category.replace(/'/g, "''")}')`).join(",\n                       ")});
${blocks}
do $$
declare c text; v_total int; v_imgs int; v_distinct int;
  v_cats text[] := array[${built.map((b) => `'${b.category.replace(/'/g, "''")}'`).join(", ")}];
begin
  foreach c in array v_cats loop
    select count(*), count(i.image_url), count(distinct i.image_url)
      into v_total, v_imgs, v_distinct
      from public.category_library_items i
      join public.category_library l on l.id = i.library_id
     where l.name_norm = public.df20_norm_category(c);
    if v_total < ${FLOOR} then raise exception 'DF20_LIB_TOO_SMALL: % has %', c, v_total; end if;
    if v_imgs < v_total then raise exception 'DF20_LIB_MISSING_IMAGES: % of % in %', v_total - v_imgs, v_total, c; end if;
    if v_distinct < v_total then raise exception 'DF20_LIB_DUPLICATE_IMAGES: % shares %', c, v_total - v_distinct; end if;
    raise notice '%: % items, % distinct pictures', c, v_total, v_distinct;
  end loop;
end $$;
`;
  writeFileSync(new URL("../supabase/migrations/0051_library_pictures.sql", import.meta.url), sql);
});
