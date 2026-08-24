/**
 * Regenerates supabase/migrations/0046_anime_categories.sql.
 *
 *   node scripts/build-anime-seed.mjs
 *
 * Generalises scripts/build-onepiece-seed.mjs (which produced 0044) to a
 * table of series. Adding a seventh show is one row in SERIES below.
 *
 * WHY NOT WIKIPEDIA: probed before writing any of this, and it does not work
 * for a cast. Only headline characters get their own article; everyone else
 * REDIRECTS to a list or group article, and MediaWiki's pageimages then
 * cheerfully returns that group's picture — so several characters come back
 * wearing the same photo and nothing about the response looks like a failure.
 * MyAnimeList has one portrait per character and is keyless through Jikan.
 *
 * LICENCE: promotional character art, fair use, the same footing as the
 * non-free Wikipedia infobox leads lib/images/resolve.ts already serves.
 * Stored as 'nonfree' so the freeOnly policy flag can drop them as a set.
 */

import { writeFileSync } from "node:fs";

const UA = { "User-Agent": "DraftFor20/1.0 (https://draftfor20.vercel.app; hello@draftfor20.app)" };

/**
 * NAME ORDER IS PER SERIES AND IS NOT COSMETIC.
 *
 * MyAnimeList stores every name as "Surname, Given". Which way round to
 * rejoin it depends on how the English release renders that show:
 *
 *   surname-first  One Piece, Dragon Ball — "Monkey D. Luffy", "Son Goku"
 *                  are the canonical English forms, so "A, B" -> "A B".
 *   given-first    Naruto, Demon Slayer, JJK, MHA — English says "Naruto
 *                  Uzumaki" and "Tanjiro Kamado", so "A, B" -> "B A".
 *
 * Getting this wrong does not break anything; it just makes every card in
 * the deck read slightly wrong to the people playing, which for a party game
 * is the entire product.
 */
const SERIES = [
  {
    category: "Jujutsu Kaisen Characters",
    provider: "kitsu",
    // JJK is split across four Kitsu entries and no single one has a full
    // cast, so they are merged and de-duplicated by character id
    sources: [["manga", 40815], ["anime", 42765], ["anime", 45857], ["anime", 44212]],
    aliases: ["jujutsu kaisen", "jjk", "jujutsu kaisen cast"],
    roster: [
      ["Satoru Gojo", "Satoru Gojou"], ["Yuji Itadori"], ["Megumi Fushiguro"],
      ["Nobara Kugisaki"], ["Sukuna"], ["Suguru Geto", "Suguru Getou"],
      ["Yuta Okkotsu"], ["Kento Nanami"], ["Maki Zenin", "Maki Zen'in"],
      ["Toge Inumaki"], ["Panda"], ["Aoi Todo", "Aoi Toudou"],
      ["Toji Fushiguro", "Touji Fushiguro"], ["Kenjaku"], ["Mahito"],
      ["Choso"], ["Yuki Tsukumo"], ["Kasumi Miwa"], ["Rika Orimoto"],
      ["Kinji Hakari"], ["Hajime Kashimo"], ["Hiromi Higuruma"],
      ["Naoya Zenin", "Naoya Zen'in"], ["Ryu Ishigori"], ["Takako Uro"],
      ["Fumihiko Takaba"], ["Ui Ui"],
      // Kitsu files him under his full 46-character title
      ["Mahoraga", "Eight-Handled Sword Divergent Sila Divine General Mahoraga"],
    ],
  },
  {
    category: "Dragon Ball Z Characters",
    provider: "kitsu",
    sources: [["anime", 720]],
    aliases: ["dragon ball z", "dragonball z", "dbz", "dragon ball"],
    // Kitsu romanises from the Japanese: Kuririn, Tenshinhan, Muten-Roshi,
    // "Jinzouningen 17-gou". Every one of those is a different word from what
    // an English-speaking player would shout at the screen, so the display
    // name is curated and the Kitsu name is only a lookup key.
    roster: [
      ["Goku", "Gokuu Son"], ["Vegeta"], ["Gohan", "Gohan Son"], ["Piccolo"],
      ["Krillin", "Kuririn"], ["Frieza"], ["Cell"], ["Majin Buu"],
      ["Trunks"], ["Future Trunks"], ["Goten", "Goten Son"], ["Bulma"],
      ["Chi-Chi"], ["Master Roshi", "Muten-Roshi"], ["Yamcha"],
      ["Tien", "Tenshinhan"], ["Chiaotzu"], ["Android 16", "Jinzouningen 16-gou"],
      ["Android 17", "Jinzouningen 17-gou"], ["Android 18", "Jinzouningen 18-gou"],
      ["Android 19", "Jinzouningen 19-gou"], ["Dr. Gero"], ["Nappa"],
      ["Raditz"], ["Bardock"], ["King Vegeta"], ["Zarbon"], ["Dodoria"],
      ["Captain Ginyu", "Ginyu"], ["Recoome"], ["Burter"], ["Jeice"],
      ["Guldo"], ["King Cold"], ["Babidi"], ["Dabura"],
      ["Spopovich", "Spopovitch"], ["Videl"], ["Mr. Satan"],
      ["Supreme Kai", "Higashi no Kaioshin"], ["Kibito"], ["Dende"],
      ["Nail"], ["Kami"], ["Mr. Popo"], ["King Kai", "North Kaio"],
      ["Korin", "Karin"], ["Yajirobe"], ["Oolong"], ["Puar", "Pu'ar"],
      ["Uub"], ["Pan"], ["Shenron", "Shen Long"], ["Porunga"],
      ["Mercenary Tao", "Tao Pai Pai"], ["King Piccolo", "Piccolo Daimao"],
      ["Garlic Jr.", "Garlic Junior"], ["Ox-King", "Gyumao"],
      ["Fortuneteller Baba", "Uranai Baba"], ["Launch", "Lunch"],
      ["Marron"], ["Paikuhan"], ["Yakon"], ["Pui Pui"], ["Gine"],
    ],
  },
  {
    category: "My Hero Academia Characters",
    provider: "kitsu",
    sources: [["manga", 26004]],
    aliases: ["my hero academia", "mha", "boku no hero academia", "bnha"],
    // Kitsu lists the villains and pro heroes under their civilian names —
    // "Chizome Akaguro" is Stain, "Chisaki" is Overhaul. On a card the hero
    // name is the one that means anything.
    roster: [
      ["Izuku Midoriya"], ["Katsuki Bakugo", "Katsuki Bakugou"],
      ["Shoto Todoroki", "Shouto Todoroki"], ["Ochaco Uraraka", "Ochako Uraraka"],
      ["Tenya Iida"], ["All Might"], ["Shota Aizawa", "Shouta Aizawa"],
      ["Tsuyu Asui"], ["Eijiro Kirishima", "Eijirou Kirishima"],
      ["Denki Kaminari"], ["Momo Yaoyorozu"], ["Kyoka Jiro", "Kyouka Jirou"],
      ["Fumikage Tokoyami"], ["Mina Ashido"], ["Hanta Sero"],
      ["Mezo Shoji", "Mezou Shouji"], ["Rikido Sato", "Rikidou Satou"],
      ["Koji Koda", "Kouji Kouda"], ["Toru Hagakure", "Tooru Hagakure"],
      ["Yuga Aoyama", "Yuuga Aoyama"], ["Mashirao Ojiro"], ["Minoru Mineta"],
      ["All For One"], ["Tomura Shigaraki"], ["Dabi"], ["Himiko Toga"],
      ["Kurogiri"], ["Stain", "Chizome Akaguro"], ["Overhaul", "Chisaki"],
      ["Twice", "Jin Bubaigawara"], ["Muscular"], ["Mr. Compress", "Atsuhiro Sako"],
      ["Spinner", "Shuuichi Iguchi"], ["Magne", "Kenji Hikiishi"],
      ["Endeavor", "Enji Todoroki"], ["Hawks"], ["Best Jeanist", "Tsunagu Hakamata"],
      ["Mirko"], ["Edgeshot", "Shinya Kamihara"], ["Kamui Woods", "Kamui Wood"],
      ["Mt. Lady", "Yuu Takeyama"], ["Present Mic", "Hizashi Yamada"],
      ["Midnight", "Nemuri Kayama"], ["Recovery Girl", "Chiyo Shuuzenji"],
      ["Principal Nezu", "Nezu"], ["Sir Nighteye"], ["Gran Torino", "Grantorino"],
      ["Mirio Togata", "Mirio Toogata"], ["Nejire Hado", "Nejire Hadou"],
      ["Tamaki Amajiki"], ["Eri"], ["Mei Hatsume"], ["Itsuka Kendo", "Itsuka Kendou"],
      ["Neito Monoma"], ["Tetsutetsu Tetsutetsu"], ["Hitoshi Shinso", "Hitoshi Shinsou"],
      ["Fuyumi Todoroki"], ["Nana Shimura"], ["Inko Midoriya"],
      ["Mitsuki Bakugo", "Mitsuki Bakugou"], ["Ibara Shiozaki"], ["Setsuna Tokage"],
      ["Pony Tsunotori"], ["Inasa Yoarashi"], ["Camie Utsushimi"], ["Nomu", "Noumu"],
    ],
  },
  {
    category: "Naruto Characters",
    malId: 20,
    order: "given-first",
    want: 60,
    aliases: ["naruto", "naruto characters", "naruto shippuden", "hidden leaf"],
    // "Might, Guy" is western-order already: given-first would make him
    // "Guy Might", which is not what anybody calls him
    renames: { "Guy Might": "Might Guy" },
  },
  {
    category: "Demon Slayer Characters",
    malId: 38000,
    order: "given-first",
    want: 45,
    aliases: ["demon slayer", "kimetsu no yaiba", "demon slayer characters"],
    renames: {},
  },
];

/**
 * MAL romanises long vowels literally: Tanjirou, Kyoujurou, Giyuu, Kochou.
 * Every English release drops them — Tanjiro, Kyojuro, Giyu, Kocho — and the
 * doubled form looks like a typo on a card. Applied per word so a legitimate
 * short name is untouched.
 */
function romanize(s) {
  return s
    .split(" ")
    .map((w) => w.replace(/ou/g, "o").replace(/uu/g, "u").replace(/oo/g, "o"))
    .join(" ");
}

function playName(raw, order, renames) {
  const s = raw.replace(/\s+/g, " ").trim();
  const m = /^([^,]+),\s*(.+)$/.exec(s);
  const joined = m
    ? order === "given-first"
      ? `${m[2].trim()} ${m[1].trim()}`
      : `${m[1].trim()} ${m[2].trim()}`
    : s;
  const clean = romanize(joined.replace(/\s+/g, " ").trim());
  return renames[clean] ?? clean;
}

/**
 * Jikan proxies MyAnimeList, and it can only serve a cast it already has
 * cached: an uncached one needs a live MAL fetch, and when MAL refuses that
 * comes back as a 504 no amount of retrying fixes. Observed for real —
 * Naruto and Demon Slayer answered instantly while Jujutsu Kaisen, Dragon
 * Ball Z and My Hero Academia returned 504 for ninety seconds straight, on
 * both the anime AND manga endpoints, with /anime/<id> itself answering 200.
 *
 * So a failure here is NOT fatal. Returning null lets the run seed every
 * series it could actually fetch and report the rest, because a partial
 * shelf that works beats no shelf at all, and re-running later picks up
 * whatever has warmed up in the meantime. Every seed is an upsert, so a
 * second run costs nothing for the categories already in.
 */
async function cast(malId) {
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      const r = await fetch(`https://api.jikan.moe/v4/anime/${malId}/characters`, { headers: UA });
      if (r.ok) return (await r.json()).data ?? [];
      if (r.status < 500 && r.status !== 429) return null; // a real 404, not an outage
    } catch {
      /* network blip: retry */
    }
    await new Promise((s) => setTimeout(s, 1500 * (attempt + 1)));
  }
  return null;
}

/**
 * Kitsu, the fallback provider — and the reason the two are not interchangeable.
 *
 * Kitsu is up when Jikan is not, and it has a portrait for every character.
 * What it does NOT have is any popularity signal: `favoritesCount` is absent
 * or zero, so after the handful of characters flagged role:"main" the cast
 * comes back ALPHABETICALLY. Taking the first fifty Dragon Ball entries that
 * way yields Piccolo, Goku, Vegeta, and then Ackman, Angela, Appule, Arqua.
 *
 * So a Kitsu series is driven by a hand-written roster instead, and Kitsu is
 * reduced to what it is actually good at: turning a name into a picture.
 * That also fixes the naming, because Kitsu romanises from the Japanese —
 * "Kuririn", "Tenshinhan", "Jinzouningen 17-gou" — and none of those is the
 * word an English-speaking player recognises.
 */
async function kitsuCast(sources) {
  const byName = new Map();
  for (const [kind, id] of sources) {
    for (let offset = 0; offset < 240; offset += 20) {
      let page = null;
      for (let attempt = 0; attempt < 4 && !page; attempt++) {
        try {
          const r = await fetch(
            `https://kitsu.io/api/edge/${kind}/${id}/characters?include=character&page[limit]=20&page[offset]=${offset}`,
            { headers: { ...UA, Accept: "application/vnd.api+json" } },
          );
          if (r.ok) page = await r.json();
        } catch {
          /* retry */
        }
        if (!page) await new Promise((s) => setTimeout(s, 700 * (attempt + 1)));
      }
      if (!page) break;
      for (const c of page.included ?? []) {
        const name = c.attributes?.canonicalName;
        const img = c.attributes?.image?.original;
        // first source wins, so the order of `sources` is the priority order
        if (name && img && !byName.has(name)) byName.set(name, img);
      }
      if ((page.data ?? []).length < 20) break;
      await new Promise((r) => setTimeout(r, 200));
    }
  }
  return byName;
}

const built = [];
const skipped = [];
for (const s of SERIES) {
  if (s.provider === "kitsu") {
    const byName = await kitsuCast(s.sources);
    if (!byName.size) {
      skipped.push(`${s.category} (Kitsu returned nothing)`);
      console.warn(`${s.category.padEnd(34)} SKIPPED — Kitsu returned nothing`);
      continue;
    }
    const picked = [];
    const missing = [];
    const seenUrl = new Set();
    for (const [display, kitsuName] of s.roster) {
      const url = byName.get(kitsuName ?? display);
      // an unmatched roster entry is REPORTED, never silently dropped: a
      // renamed character upstream would otherwise just quietly shrink the
      // category and nothing would say so
      if (!url) { missing.push(kitsuName ?? display); continue; }
      if (seenUrl.has(url)) { missing.push(`${display} (duplicate image)`); continue; }
      if (display.length < 2 || display.length > 60) continue;
      if (!/^https:\/\/media\.kitsu\.app\//.test(url)) { missing.push(`${display} (bad host)`); continue; }
      if (/[\n\r$]/.test(display) || /[\n\r$]/.test(url)) continue;
      seenUrl.add(url);
      picked.push({ name: display, url });
    }
    if (missing.length) console.warn(`  ${s.category}: ${missing.length} unmatched -> ${missing.join(", ")}`);
    if (picked.length < 24) {
      skipped.push(`${s.category} (only ${picked.length} matched)`);
      console.warn(`${s.category.padEnd(34)} SKIPPED — only ${picked.length} matched`);
      continue;
    }
    built.push({ ...s, picked });
    console.log(`${s.category.padEnd(34)} ${String(picked.length).padStart(3)} characters  (kitsu)`);
    continue;
  }

  const raw = await cast(s.malId);
  if (!raw) {
    skipped.push(s.category);
    console.warn(`${s.category.padEnd(34)} SKIPPED — Jikan/MAL would not serve this cast`);
    continue;
  }
  const rows = raw
    // a missing portrait falls back to MAL's question-mark placeholder, which
    // is a picture of nothing and worse than a generated card
    .filter((c) => c.character?.images?.jpg?.image_url && !/questionmark/i.test(c.character.images.jpg.image_url))
    .sort((a, b) => (b.favorites || 0) - (a.favorites || 0));

  const seen = new Set();
  const seenUrl = new Set();
  const picked = [];
  for (const c of rows) {
    const name = playName(c.character.name, s.order, s.renames);
    const key = name.toLowerCase();
    const url = c.character.images.jpg.image_url.split("?")[0];
    if (seen.has(key) || seenUrl.has(url)) continue;
    if (name.length < 2 || name.length > 60) continue; // df20_clean_text bounds
    if (!/^https:\/\/cdn\.myanimelist\.net\//.test(url)) continue;
    if (/[\n\r$]/.test(name) || /[\n\r$]/.test(url)) continue; // dollar-quote safety
    seen.add(key);
    seenUrl.add(url);
    picked.push({ name, url });
    if (picked.length >= s.want) break;
  }

  // 2N lots means a category has to cover twice the biggest roster it is
  // offered for. Below 60 the room simply refuses with DF20_POOL_TOO_SMALL,
  // so it is better to fail here than to ship a category that cannot start.
  if (picked.length < 30) {
    skipped.push(`${s.category} (only ${picked.length} usable characters)`);
    console.warn(`${s.category.padEnd(34)} SKIPPED — only ${picked.length} usable characters`);
    continue;
  }
  built.push({ ...s, picked });
  console.log(`${s.category.padEnd(34)} ${String(picked.length).padStart(3)} characters`);
  await new Promise((r) => setTimeout(r, 1100)); // Jikan: 3 req/sec, 60/min
}

const blocks = built
  .map(
    (s) => `
-- ── ${s.category} · ${s.picked.length} items
select public.df20_seed_category(
  '${s.category}',
  string_to_array($it$${s.picked.map((p) => p.name).join("\n")}$it$, E'\\n'),
  string_to_array($im$${s.picked.map((p) => p.url).join("\n")}$im$, E'\\n'),
  array_fill('nonfree'::text, array[${s.picked.length}]));

select public.df20_add_alias('${s.category}',
  array[${s.aliases.map((a) => `'${a}'`).join(", ")}]);
`,
  )
  .join("");

const sql = `-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0046 · five more anime casts, with portraits
--
-- GENERATED by scripts/build-anime-seed.mjs. Re-run that rather than editing
-- the lists below; names and URLs are positional, and hand editing one
-- without the other slides every later picture onto the wrong character.
--
-- Same shape and same reasoning as 0044 (One Piece): seeded from MyAnimeList
-- rather than resolved from Wikipedia, because Wikipedia redirects most of a
-- cast to a group article and hands several characters the same photograph.
--
-- Depends on 0044 for df20_seed_category(text,text[],text[],text[]) and for
-- the MyAnimeList host on the image allowlist. df20_clean_image_url is
-- re-declared below anyway so this file is correct applied on its own — the
-- df20_clean_logo_url outage was exactly a caller split from its dependency
-- across two migrations.
--
-- Re-runnable. Every seed upserts by normalised name and refreshes portraits.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.df20_clean_image_url(p_in text)
returns text language plpgsql immutable
set search_path = public, pg_temp as $$
declare v text;
begin
  v := btrim(coalesce(p_in, ''));
  if length(v) = 0 or length(v) > 600 then return null; end if;
  if v !~ '^https://' then return null; end if;
  if v !~* '^https://(upload\\.wikimedia\\.org|commons\\.wikimedia\\.org|coverartarchive\\.org|covers\\.openlibrary\\.org|cdn\\.myanimelist\\.net|media\\.kitsu\\.app)/' then
    return null;
  end if;
  if v ~ '[[:cntrl:]"''<>]' then return null; end if;
  return v;
end $$;
${blocks}
-- ── assert every one of them landed with distinct pictures ────────────────
-- Distinct, not merely non-null: the Wikipedia failure mode this whole
-- approach exists to avoid is several characters sharing one group photo,
-- and a count of non-null images would not notice that at all.
do $$
declare c text; v_total int; v_imgs int; v_distinct int;
  v_cats text[] := array[${built.map((s) => `'${s.category}'`).join(", ")}];
begin
  foreach c in array v_cats loop
    select count(*), count(i.image_url), count(distinct i.image_url)
      into v_total, v_imgs, v_distinct
      from public.category_library_items i
      join public.category_library l on l.id = i.library_id
     where l.name_norm = public.df20_norm_category(c);

    if v_total < 30 then
      raise exception 'DF20_ANIME_TOO_SMALL: % has only % items', c, v_total;
    end if;
    if v_imgs < v_total then
      raise exception 'DF20_ANIME_MISSING_IMAGES: % of % items in % have no picture',
        v_total - v_imgs, v_total, c;
    end if;
    if v_distinct < v_total then
      raise exception 'DF20_ANIME_DUPLICATE_IMAGES: % shares % pictures across % items',
        c, v_total - v_distinct, v_total;
    end if;
    raise notice '%: % items, % distinct portraits', c, v_total, v_distinct;
  end loop;
end $$;
`;

if (!built.length) {
  throw new Error("no series could be fetched — nothing written, re-run when MAL is up");
}

writeFileSync(new URL("../supabase/migrations/0046_anime_categories.sql", import.meta.url), sql);
console.log(`\nwrote 0046_anime_categories.sql — ${built.length} categories, ${built.reduce((n, s) => n + s.picked.length, 0)} characters`);
for (const s of built) console.log(`\n${s.category}:\n  ${s.picked.map((p) => p.name).join(" | ")}`);
if (skipped.length) {
  console.warn(`\nNOT SEEDED (re-run this script to pick them up):`);
  for (const k of skipped) console.warn(`  - ${k}`);
}
