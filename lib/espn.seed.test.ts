/**
 * A TOOL, NOT A TEST. Regenerates supabase/migrations/0049_sports_categories.sql.
 *
 *   SEED=1 npx vitest run lib/espn.seed.test.ts
 *
 * Opt-in via SEED so it never runs in the normal suite — it hits ESPN,
 * Wikipedia and Wikidata for real and takes several minutes.
 *
 * WHY THE PICTURES ARE COMMONS AND NOT ESPN'S. lib/espn.ts already states the
 * rule and this obeys it: a roster is a set of facts and facts are not
 * copyrightable, so ESPN supplies who is on the team and nothing else. Every
 * photograph comes from the ordinary cascade under `freeOnly`, which means
 * Commons and a licence that actually grants reuse. ESPN's headshot CDN would
 * give 100% coverage and no right to use any of it.
 *
 * WHY NOT THE WHOLE ROSTER. Measured: all 3,015 rostered NFL players yield 23%
 * image coverage, because most of a roster is practice squad with no article
 * and no photograph. Filtering to players who have a VERIFIED article — which
 * is very nearly the definition of "notable enough to bid on" — and taking the
 * most-viewed of those gives ~100%.
 *
 * WHY RANK ON THE TITLE, NEVER THE NAME. Ranking bare roster names by
 * pageviews put the actor Bill Murray third in the NFL. The Wikidata check in
 * resolvePlayerTitle runs FIRST, so by the time anything is ranked the string
 * is a verified athlete's article. The same check is what separates the NBA's
 * Anthony Edwards from the ER actor who holds the bare title.
 */
import { writeFileSync } from "node:fs";
import { it } from "vitest";
import { fetchRoster, fetchTeams, resolvePlayerTitle, teamQid, type League } from "./espn";
import { resolveImages } from "./images/resolve";
import { rankByPageviews } from "./wikipedia";

const KEEP = 70;

/**
 * A star is not just "the most viewed of whoever is on a roster".
 *
 * Measured over 60 days of Wikipedia traffic, current NFL players fall into
 * two clearly separated groups and nothing sits between them:
 *
 *     58,695  Bijan Robinson      <- real players stop here
 *     20,977  Denzel Boston       <- and a flat 19-21k plateau begins
 *     18,672  Marist Liufau
 *
 * That plateau is baseline traffic — a stub article nobody sought out — not
 * interest, which is why Drake London and Garrett Wilson sit in it alongside
 * players who have never taken a snap. Taking the top 70 regardless swept the
 * whole plateau in, and a draft full of practice-squad names is a worse game
 * than a shorter one.
 *
 * Expressed as a SHARE of the tenth-ranked player rather than an absolute
 * number, because absolute traffic swings with the season and would silently
 * empty the category in February.
 */
const MIN_SHARE_OF_TENTH = 0.4;
const FLOOR = 24; // a 24-item category still seats a 12-slot roster

/** 60-day view totals, batched. Local to the tool; rankByPageviews hides its scores. */
async function pageviews(titles: string[]): Promise<Map<string, number>> {
  const out = new Map<string, number>();
  for (let i = 0; i < titles.length; i += 50) {
    const params = new URLSearchParams({
      action: "query", prop: "pageviews", titles: titles.slice(i, i + 50).join("|"),
      formatversion: "2", format: "json",
    });
    try {
      // retry: without it this batch silently scored nothing, every player
      // tied at 0, the cutoff computed as 0 and the whole filter was a no-op
      let r: Response | null = null;
      for (let a = 0; a < 4; a++) {
        r = await fetch(`https://en.wikipedia.org/w/api.php?${params}`, {
          headers: { "User-Agent": "DraftFor20/1.0 (https://draftfor20.vercel.app; hello@draftfor20.app)" },
        });
        if (r.ok) break;
        if (r.status !== 429 && r.status < 500) break;
        await new Promise((x) => setTimeout(x, 900 * (a + 1)));
      }
      if (!r || !r.ok) continue;
      const j = (await r.json()) as { query?: { pages?: { title?: string; pageviews?: Record<string, number | null> }[] } };
      for (const pg of j.query?.pages ?? []) {
        if (!pg.title) continue;
        out.set(pg.title, Object.values(pg.pageviews ?? {}).reduce<number>((t, v) => t + (v ?? 0), 0));
      }
    } catch {
      /* a lost batch costs those players their score, not the run */
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  return out;
}

/**
 * Real current players whose fame belongs to somebody else.
 *
 * The resolver gets these RIGHT — Michael Jordan correctly resolves to
 * "Michael Jordan (offensive lineman)" — but pageview ranking does not:
 * that article outscores Patrick Mahomes, because traffic leaks across a
 * disambiguated name. The result is a card labelled "Michael Jordan" showing
 * an offensive lineman, which reads as a bug to anyone playing.
 *
 * Kept as an explicit list rather than a rule, because the rule that would
 * catch them ("drop disambiguated titles") also drops Anthony Edwards, who is
 * a genuine NBA star whose bare title belongs to the ER actor.
 */
const CROSS_SPORT_NAMESAKES = new Set(
  ["michael jordan", "chris paul", "bill murray", "miles davis", "jimmy butler"].map((s) => s),
);
const PROGRESS: string[] = [];

/**
 * All-time rosters are curated, not fetched: ESPN's API only knows about
 * current players, and "greatest of all time" is an argument rather than a
 * query. These are the names a room would actually shout about.
 */
const ALLTIME: Record<string, string[]> = {
  "NFL All-Time Greats": [
    "Tom Brady","Jerry Rice","Joe Montana","Peyton Manning","Walter Payton","Lawrence Taylor",
    "Barry Sanders","Emmitt Smith","Brett Favre","Ray Lewis","John Elway","Dan Marino",
    "Deion Sanders","Reggie White","Jim Brown","Johnny Unitas","Randy Moss","Terrell Owens",
    "Ed Reed","Champ Bailey","Bruce Smith","Michael Strahan","Troy Aikman","Steve Young",
    "Marshall Faulk","LaDainian Tomlinson","Adrian Peterson","Drew Brees","Ben Roethlisberger",
    "Aaron Rodgers","Rob Gronkowski","Tony Gonzalez","Shannon Sharpe","Anthony Munoz",
    "Dick Butkus","Joe Greene","Ronnie Lott","Night Train Lane","Gale Sayers","Earl Campbell",
    "Eric Dickerson","Marcus Allen","Thurman Thomas","Curtis Martin","Terry Bradshaw",
    "Roger Staubach","Bart Starr","Warren Sapp","Junior Seau","Derrick Brooks",
    "Charles Woodson","Darrelle Revis","Richard Sherman","Von Miller","J.J. Watt",
    "Julio Jones", "Larry Fitzgerald", "Calvin Johnson", "Marvin Harrison", "Cris Carter",
  ],
  "NBA All-Time Greats": [
    "Michael Jordan","Kobe Bryant","Magic Johnson","Larry Bird","Shaquille O'Neal",
    "Tim Duncan","Hakeem Olajuwon","Kareem Abdul-Jabbar","Wilt Chamberlain","Bill Russell",
    "LeBron James","Stephen Curry","Kevin Durant","Dirk Nowitzki","Allen Iverson",
    "Charles Barkley","Karl Malone","John Stockton","Scottie Pippen","Jason Kidd",
    "Steve Nash","Dwyane Wade","Kevin Garnett","Paul Pierce","Ray Allen",
    "Oscar Robertson","Jerry West","Elgin Baylor","Julius Erving","Moses Malone",
    "David Robinson","Patrick Ewing","Clyde Drexler","Isiah Thomas","Dominique Wilkins",
    "Reggie Miller","Chris Paul","Russell Westbrook","James Harden","Carmelo Anthony",
    "Vince Carter","Tracy McGrady","Yao Ming","Manu Ginobili","Tony Parker",
    "Pau Gasol","Chris Bosh","Rasheed Wallace","Ben Wallace","Alonzo Mourning",
    "Gary Payton","Dennis Rodman","James Worthy","Bob Cousy","George Gervin",
    "Nikola Jokic","Giannis Antetokounmpo","Joel Embiid","Luka Doncic","Jayson Tatum",
  ],
};

const CURRENT: { category: string; league: League; aliases: string[] }[] = [
  { category: "NFL Players", league: "nfl", aliases: ["nfl players", "current nfl players", "football players", "nfl stars"] },
  { category: "NBA Players", league: "nba", aliases: ["nba players", "current nba players", "basketball players", "nba stars"] },
];

interface Built { category: string; aliases: string[]; picked: { name: string; url: string }[] }

async function currentLeague(cfg: (typeof CURRENT)[number]): Promise<Built | null> {
  const teams = await fetchTeams(cfg.league);
  if (!teams.length) return null;

  const roster: { name: string; position: string | null; team: string }[] = [];
  for (const t of teams) roster.push(...(await fetchRoster(t.id, cfg.league)));
  console.log(`${cfg.category}: ${teams.length} teams, ${roster.length} rostered`);

  // OVER-FETCH BY FAME FIRST, THEN VERIFY. Verifying all 3,015 rostered NFL
  // players costs two Wikimedia requests each; doing it got this run rate
  // limited, and Wikimedia is being used as a courtesy rather than under a
  // contract. Pageview ranking is batched and cheap, so it goes first and
  // only the top slice is verified.
  //
  // Ranking bare names is unsafe on its own — it put the actor Bill Murray
  // third in the NFL — but it is safe as a PRE-FILTER, because the Wikidata
  // sport check below drops him. He costs one slot in the over-fetch and
  // never reaches the category.
  // 100, not 220. Every shortlisted player costs TWO Wikimedia requests to
  // verify, and stacking 440 of those on top of the 60 needed to rank 3,000
  // names got the run rate limited badly enough that pageview scoring returned
  // nothing at all and the fame filter silently became a no-op.
  const OVERFETCH = 100;
  const unique = [...new Set(roster.map((p) => p.name))];
  const famous = await rankByPageviews(unique, OVERFETCH);
  const byName = new Map(roster.map((p) => [p.name, p]));
  const shortlist = famous.items.map((n) => byName.get(n)!).filter(Boolean);
  console.log(`  shortlist ${shortlist.length} by pageviews`);

  // PASS THE TEAM. Two NFL players are called Josh Allen; with no team key the
  // resolver returns whichever ranks first and the Bills quarterback ends up
  // as an offensive lineman. Cached, so it costs one lookup per team.
  const qidCache = new Map<string, string | null>();
  const qidFor = async (team: string) => {
    if (!qidCache.has(team)) qidCache.set(team, await teamQid(team));
    return qidCache.get(team)!;
  };

  const titled: { name: string; title: string }[] = [];
  for (const p of shortlist) {
    try {
      const title = await resolvePlayerTitle(p, await qidFor(p.team), cfg.league);
      // a category of PLAYERS should not contain coaches; "Bill Murray"
      // resolves to "Bill Murray (American football coach)"
      if (
        title &&
        !/\bcoach\b/i.test(title) &&
        !(cfg.league === "nfl" && CROSS_SPORT_NAMESAKES.has(p.name.toLowerCase()))
      ) {
        titled.push({ name: p.name, title });
      }
    } catch {
      /* a transient Wikimedia failure costs one player, not the run */
    }
    await new Promise((r) => setTimeout(r, 200)); // be a good citizen
  }
  console.log(`  verified athletes: ${titled.length}`);

  const byTitle = new Map<string, { name: string; title: string }>();
  for (const t of titled) if (!byTitle.has(t.title)) byTitle.set(t.title, t);

  // RE-RANK ON THE VERIFIED TITLE, THEN CUT AT THE CLIFF.
  //
  // Ranking on the title is what stops an obscure player inheriting a famous
  // namesake's traffic: Bill Murray IS a real NFL lineman and placed third in
  // the league on the actor's numbers. "Bill Murray (American football coach)"
  // scores his own.
  const views = await pageviews([...byTitle.keys()]);
  const scored = [...byTitle.entries()]
    .map(([title, p]) => ({ ...p, views: views.get(title) ?? 0 }))
    .sort((a, b) => b.views - a.views);

  const tenth = scored[9]?.views ?? 0;
  if (tenth === 0) {
    // scoring failed wholesale; shipping every rostered player is worse than
    // shipping nothing, so say so rather than silently widening the category
    throw new Error(`${cfg.category}: pageview scoring returned nothing — re-run`);
  }
  const cutoff = Math.round(tenth * MIN_SHARE_OF_TENTH);
  // Pad the candidate pool before the image filter, not after: some of these
  // will have no free photograph, and slicing to the floor first is what left
  // the category three short and skipped entirely.
  const above = scored.filter((p) => p.views >= cutoff);
  // Pad ONLY when the fame cut leaves too few to play with. Padding whenever
  // it fell short of a comfortable 40 put every sub-threshold player straight
  // back in, which is the practice-squad problem the cut exists to solve.
  const pool = above.length >= FLOOR ? above : scored.slice(0, FLOOR);
  const top = pool.slice(0, KEEP);
  console.log(
    `  cutoff ${cutoff} (40% of 10th=${tenth}) -> ${above.length} clear it; keeping ${top.length}`,
  );
  PROGRESS.push(`  ${cfg.category}: cutoff ${cutoff}, ${above.length} above it`);

  const imgs = await resolveImages(top, { freeOnly: true });
  const picked: { name: string; url: string }[] = [];
  const seen = new Set<string>();
  for (let i = 0; i < top.length; i++) {
    const r = imgs[i];
    // freeOnly means anything left is Commons; a generated card is not stored,
    // and a player with no free photograph is simply not in the category
    if (r.source === "generated") continue;
    const name = top[i].name;
    if (seen.has(name.toLowerCase()) || name.length < 2 || name.length > 60) continue;
    if (/[\n\r$]/.test(name) || /[\n\r$]/.test(r.url)) continue;
    seen.add(name.toLowerCase());
    picked.push({ name, url: r.url });
    if (picked.length >= KEEP) break;
  }
  console.log(`  ${cfg.category}: ${picked.length} with a free photograph (from ${top.length} verified)`);
  PROGRESS.push(`${cfg.category}: rostered->verified ${byTitle.size}, free photos ${picked.length}`);
  return { category: cfg.category, aliases: cfg.aliases, picked };
}

async function allTime(category: string, names: string[]): Promise<Built> {
  const imgs = await resolveImages(names.map((n) => ({ name: n, title: n })), { freeOnly: true });
  const picked: { name: string; url: string }[] = [];
  const seen = new Set<string>();
  for (let i = 0; i < names.length; i++) {
    const r = imgs[i];
    if (r.source === "generated") continue;
    if (seen.has(names[i].toLowerCase())) continue;
    if (/[\n\r$]/.test(names[i]) || /[\n\r$]/.test(r.url)) continue;
    seen.add(names[i].toLowerCase());
    picked.push({ name: names[i], url: r.url });
  }
  console.log(`${category}: ${picked.length}/${names.length} with a free photograph`);
  PROGRESS.push(`${category}: ${picked.length}/${names.length} free photos`);
  const aliases = category.startsWith("NFL")
    ? ["nfl legends", "nfl all time", "greatest nfl players", "football legends"]
    : ["nba legends", "nba all time", "greatest nba players", "basketball legends"];
  return { category, aliases, picked };
}

it.runIf(!!process.env.SEED)("seed", { timeout: 3_600_000 }, async () => {
  const built: Built[] = [];
  const log: string[] = [];
  for (const cfg of CURRENT) {
    const b = await currentLeague(cfg);
    await new Promise((r) => setTimeout(r, 5000)); // let Wikimedia breathe
    if (b && b.picked.length >= 24) built.push(b);
    else log.push(`SKIPPED ${cfg.category}: only ${b?.picked.length ?? 0} usable`);
  }
  for (const [cat, names] of Object.entries(ALLTIME)) {
    const b = await allTime(cat, names);
    await new Promise((r) => setTimeout(r, 3000));
    if (b.picked.length >= 30) built.push(b);
    else log.push(`SKIPPED ${cat}: only ${b.picked.length} usable`);
  }
  writeFileSync("/tmp/seedlog.txt", [...PROGRESS, "", ...log].join("\n"));
  if (!built.length) throw new Error("nothing built: " + log.join(" | "));

  const blocks = built
    .map(
      (b) => `
-- ── ${b.category} · ${b.picked.length} items
select public.df20_seed_category(
  '${b.category}',
  string_to_array($it$${b.picked.map((p) => p.name).join("\n")}$it$, E'\\n'),
  string_to_array($im$${b.picked.map((p) => p.url).join("\n")}$im$, E'\\n'),
  array_fill('free'::text, array[${b.picked.length}]));

select public.df20_add_alias('${b.category}',
  array[${b.aliases.map((a) => `'${a}'`).join(", ")}]);
`,
    )
    .join("");

  const sql = `-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0049 · NFL and NBA players, with free photographs
--
-- GENERATED by lib/espn.seed.test.ts (SEED=1 npx vitest run lib/espn.seed.test.ts).
-- Names and URLs are positional; editing one list without the other slides
-- every later picture onto the wrong player.
--
-- EVERY IMAGE HERE IS COMMONS-LICENSED ('free'), unlike the anime categories
-- in 0044/0046 which are fair-use promotional art. That is deliberate and it
-- is why these categories survive a freeOnly export: lib/espn.ts takes only
-- the roster from ESPN, because a roster is a fact and a photograph is not.
--
-- CURRENT ROSTERS GO STALE. Re-run the generator after a trade deadline or a
-- new season; the seed upserts by normalised name, so re-running refreshes
-- both the list and the photographs.
--
-- Re-runnable — and the delete below is why. df20_seed_category UPSERTS by
-- (library_id, name) and never removes, so re-seeding a shrunken list would
-- leave every dropped player behind. That is exactly how a category that had
-- been cut to 37 stars kept all 70 of its practice-squad names.
-- ═══════════════════════════════════════════════════════════════════════════

delete from public.category_library_items i
 using public.category_library l
 where l.id = i.library_id
   and l.name_norm in (${built.map((b) => `public.df20_norm_category('${b.category}')`).join(",\n                       ")});
${blocks}
-- ── assert they landed, with DISTINCT photographs ─────────────────────────
do $$
declare c text; v_total int; v_imgs int; v_distinct int;
  v_cats text[] := array[${built.map((b) => `'${b.category}'`).join(", ")}];
begin
  foreach c in array v_cats loop
    select count(*), count(i.image_url), count(distinct i.image_url)
      into v_total, v_imgs, v_distinct
      from public.category_library_items i
      join public.category_library l on l.id = i.library_id
     where l.name_norm = public.df20_norm_category(c);

    if v_total < 30 then
      raise exception 'DF20_SPORTS_TOO_SMALL: % has only % items', c, v_total;
    end if;
    if v_imgs < v_total then
      raise exception 'DF20_SPORTS_MISSING_IMAGES: % of % in % have no picture',
        v_total - v_imgs, v_total, c;
    end if;
    if v_distinct < v_total then
      raise exception 'DF20_SPORTS_DUPLICATE_IMAGES: % shares % pictures', c, v_total - v_distinct;
    end if;
    raise notice '%: % items, % distinct photographs', c, v_total, v_distinct;
  end loop;
end $$;
`;

  writeFileSync(new URL("../supabase/migrations/0049_sports_categories.sql", import.meta.url), sql);
  writeFileSync("/tmp/sports-seed.txt",
    built.map((b) => `${b.category} (${b.picked.length})\n  ${b.picked.map((p) => p.name).join(", ")}`).join("\n\n"));
  console.log(`wrote 0049_sports_categories.sql — ${built.length} categories`);
});
