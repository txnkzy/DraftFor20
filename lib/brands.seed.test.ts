/**
 * A TOOL, NOT A TEST. Regenerates supabase/migrations/0050_brand_categories.sql.
 *
 *   BRANDS=1 npx vitest run lib/brands.seed.test.ts
 *
 * Rebuilds Fast Food Chains and Candy and Sweets around what people actually
 * recognise, and gives both a picture.
 *
 * WHY THE OLD LISTS NEEDED IT: they were not wrong so much as tail-heavy.
 * Fast Food carried Moe's Southwest Grill, Potbelly, Qdoba and Quiznos;
 * Candy carried Zagnut, Sno-Caps, Krackel, Raisinets and Mr. Goodbar — and
 * did not carry M&M's at all, which is the single most-viewed candy there is.
 *
 * RANKED ON 60 DAYS OF WIKIPEDIA TRAFFIC, which only started telling the
 * truth once rankByPageviews learned to follow the API's continuation token:
 * prop=pageviews answers for a SUBSET of the titles asked for and hands back
 * a `continue` for the rest. Reading the first response only had McDonald's
 * scoring 0 while Auntie Anne's scored 12,506.
 *
 * LICENCE: brand logos and wrappers are fair use, stored 'nonfree', the same
 * footing as the anime art. Unlike the sports categories these cannot be
 * Commons-only — a logo is the trademark holder's.
 */
import { writeFileSync } from "node:fs";
import { it } from "vitest";
import { resolveImages } from "./images/resolve";
import { rankByPageviews } from "./wikipedia";

/** [display name, wikipedia article] — the article is explicit wherever the
 *  bare name is ambiguous ("Subway", "Nerds", "Dots" are all something else). */
const FOOD: [string, string][] = [
  ["McDonald's","McDonald's"],["Starbucks","Starbucks"],["KFC","KFC"],
  ["In-N-Out Burger","In-N-Out Burger"],["Chick-fil-A","Chick-fil-A"],
  ["Burger King","Burger King"],["Taco Bell","Taco Bell"],["Tim Hortons","Tim Hortons"],
  ["Raising Cane's","Raising Cane's Chicken Fingers"],["Chipotle","Chipotle Mexican Grill"],
  ["Pizza Hut","Pizza Hut"],["Wendy's","Wendy's"],["Subway","Subway (restaurant)"],
  ["Dunkin'","Dunkin' Donuts"],["Dairy Queen","Dairy Queen"],["Domino's","Domino's Pizza"],
  ["Popeyes","Popeyes"],["Culver's","Culver's"],["Five Guys","Five Guys"],
  ["White Castle","White Castle (restaurant)"],["Krispy Kreme","Krispy Kreme"],
  ["Shake Shack","Shake Shack"],["Jersey Mike's","Jersey Mike's Subs"],
  ["Little Caesars","Little Caesars"],["Jack in the Box","Jack in the Box"],
  ["Panda Express","Panda Express"],["Papa John's","Papa John's Pizza"],["Arby's","Arby's"],
  ["Whataburger","Whataburger"],["Wingstop","Wingstop"],["Panera Bread","Panera Bread"],
  ["Hardee's","Hardee's"],["Carl's Jr.","Carl's Jr."],["Bojangles","Bojangles (restaurant)"],
  ["Sonic Drive-In","Sonic Drive-In"],["Zaxby's","Zaxby's"],["Jimmy John's","Jimmy John's"],
  ["Steak 'n Shake","Steak 'n Shake"],["Buffalo Wild Wings","Buffalo Wild Wings"],
  ["Del Taco","Del Taco"],["Cinnabon","Cinnabon"],["Auntie Anne's","Auntie Anne's"],
];

const CANDY: [string, string][] = [
  ["M&M's","M&M's"],["Toblerone","Toblerone"],["Snickers","Snickers"],
  // Haribo omitted on purpose: its article lead is the company HEADQUARTERS
  // BUILDING, which on a candy card reads as a broken image. Gummy Bears
  // already covers the same shelf space with an actual photograph of sweets.
  ["Kit Kat","Kit Kat"],["Airheads","Airheads (candy)"],
  ["Reese's Peanut Butter Cups","Reese's Peanut Butter Cups"],
  ["Milky Way","Milky Way (chocolate bar)"],["Skittles","Skittles (confectionery)"],
  ["Twix","Twix"],["Swedish Fish","Swedish Fish"],["Gobstopper","Gobstopper"],
  ["Gummy Bears","Gummy bear"],["Nerds","Nerds (candy)"],["Butterfinger","Butterfinger"],
  ["Tootsie Roll","Tootsie Roll"],["Baby Ruth","Baby Ruth"],["Candy Corn","Candy corn"],
  ["Jolly Rancher","Jolly Rancher"],["Starburst","Starburst (candy)"],
  ["Sour Patch Kids","Sour Patch Kids"],["Pop Rocks","Pop Rocks"],
  ["Mike and Ike","Mike and Ike"],["Twizzlers","Twizzlers"],
  ["3 Musketeers","3 Musketeers (chocolate bar)"],["Whoppers","Whoppers"],
  ["Nestle Crunch","Nestlé Crunch"],["Milk Duds","Milk Duds"],["Heath Bar","Heath bar"],
  ["Hershey's Bar","Hershey bar"],["Hershey's Kisses","Hershey's Kisses"],["Rolo","Rolo"],
  ["Almond Joy","Almond Joy"],["Warheads","Warheads (candy)"],["Mounds","Mounds (candy)"],
  ["Peeps","Peeps"],["Runts","Runts"],["Skor","Skor"],["100 Grand","100 Grand Bar"],
  ["Hot Tamales","Hot Tamales"],["Laffy Taffy","Laffy Taffy"],["Junior Mints","Junior Mints"],
  ["Ring Pop","Ring Pop"],["PayDay","PayDay (confection)"],
];

const CATS: { category: string; list: [string, string][]; aliases: string[] }[] = [
  { category: "Fast Food Chains", list: FOOD,
    aliases: ["fast food", "fast food chains", "burger chains", "restaurant chains"] },
  { category: "Candy and Sweets", list: CANDY,
    // NOT "halloween candy": that is a different category on the shelf and
    // the alias would make df20_match_category ambiguous between the two
    aliases: ["candy", "candy and sweets", "sweets", "chocolate bars", "candy bars"] },
];

/** Below this share of the tenth-ranked entry, nobody at the table reacts. */
const MIN_SHARE_OF_TENTH = 0.12;
const FLOOR = 28;

it.runIf(!!process.env.BRANDS)("brands", { timeout: 1_800_000 }, async () => {
  const built: { category: string; aliases: string[]; picked: { name: string; url: string }[] }[] = [];
  const log: string[] = [];

  for (const cfg of CATS) {
    const byTitle = new Map(cfg.list.map(([d, t]) => [t, d]));
    const ranked = await rankByPageviews([...byTitle.keys()], cfg.list.length);
    // rankByPageviews returns the full set in fame order when keep >= length
    const ordered = ranked.items.map((t) => ({ title: t, name: byTitle.get(t)! })).filter((x) => x.name);

    const tenth = ordered.length >= 10 ? ordered[9] : ordered[ordered.length - 1];
    // the ranker hides its scores, so cut by POSITION against a floor instead:
    // keep everything, then let the image step and the floor decide.
    const pool = ordered;

    const imgs = await resolveImages(pool.map((p) => ({ name: p.name, title: p.title })));
    const picked: { name: string; url: string }[] = [];
    const seenUrl = new Set<string>();
    const missing: string[] = [];
    for (let i = 0; i < pool.length; i++) {
      const r = imgs[i];
      if (r.source === "generated") { missing.push(pool[i].name); continue; }
      if (seenUrl.has(r.url)) { missing.push(`${pool[i].name} (dup image)`); continue; }
      if (/[\n\r$]/.test(pool[i].name) || /[\n\r$]/.test(r.url)) continue;
      seenUrl.add(r.url);
      picked.push({ name: pool[i].name, url: r.url });
    }
    log.push(`${cfg.category}: ${picked.length}/${pool.length} with a picture` +
      (missing.length ? ` | no picture: ${missing.join(", ")}` : ""));
    log.push(`  order: ${pool.slice(0, 12).map((p) => p.name).join(", ")}`);
    if (picked.length < FLOOR) { log.push(`  SKIPPED (under ${FLOOR})`); continue; }
    built.push({ category: cfg.category, aliases: cfg.aliases, picked });
    await new Promise((r) => setTimeout(r, 3000));
  }

  writeFileSync("/tmp/brands-seed.txt", log.join("\n"));
  if (!built.length) throw new Error("nothing built: " + log.join(" | "));

  const blocks = built.map((b) => `
-- ── ${b.category} · ${b.picked.length} items
select public.df20_seed_category(
  '${b.category.replace(/'/g, "''")}',
  string_to_array($it$${b.picked.map((p) => p.name).join("\n")}$it$, E'\\n'),
  string_to_array($im$${b.picked.map((p) => p.url).join("\n")}$im$, E'\\n'),
  array_fill('nonfree'::text, array[${b.picked.length}]));

select public.df20_add_alias('${b.category.replace(/'/g, "''")}',
  array[${b.aliases.map((a) => `'${a}'`).join(", ")}]);
`).join("");

  const sql = `-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0050 · Fast Food and Candy, rebuilt around what people know
--
-- GENERATED by lib/brands.seed.test.ts. Names and URLs are positional.
--
-- The old lists were tail-heavy rather than wrong: Moe's Southwest Grill,
-- Potbelly, Qdoba and Quiznos in one; Zagnut, Sno-Caps, Krackel and Mr.
-- Goodbar in the other — which also managed not to contain M&M's, the most
-- viewed candy on Wikipedia. Both are now ordered by 60 days of real traffic
-- and every entry carries a logo or a wrapper.
--
-- 'nonfree': a logo is the trademark holder's, so unlike the sports
-- categories in 0049 these cannot be Commons-only.
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
    if v_total < ${FLOOR} then raise exception 'DF20_BRANDS_TOO_SMALL: % has %', c, v_total; end if;
    if v_imgs < v_total then raise exception 'DF20_BRANDS_MISSING_IMAGES: % of % in %', v_total - v_imgs, v_total, c; end if;
    if v_distinct < v_total then raise exception 'DF20_BRANDS_DUPLICATE_IMAGES: % shares %', c, v_total - v_distinct; end if;
    raise notice '%: % items, % distinct pictures', c, v_total, v_distinct;
  end loop;
end $$;
`;
  writeFileSync(new URL("../supabase/migrations/0050_brand_categories.sql", import.meta.url), sql);
});
