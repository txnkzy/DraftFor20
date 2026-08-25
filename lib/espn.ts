/**
 * Server-only. Builds a draftable list of NFL players.
 *
 * SPLIT ON PURPOSE: the roster comes from ESPN, the pictures do not.
 *
 * A roster is a set of facts — who plays for whom, at what position — and
 * facts are not copyrightable. A photograph is. So this module takes from
 * ESPN only the part that is not theirs to own, and hands the names to the
 * ordinary image cascade, which sources pictures from Commons under a licence
 * that actually grants reuse. ESPN's own headshot CDN would give 100% coverage
 * and no right to use any of it.
 *
 * It also sidesteps the category matcher: asking Wikipedia for "NFL teams"
 * lands on "List of first overall NFL draft picks" and offers QB and LB as
 * biddable items. An ESPN roster is exact.
 *
 * ESPN's site API is undocumented and unversioned. Depending on it for names
 * is recoverable — a category simply fails to build — which is the only
 * reason it is acceptable to depend on at all.
 */

import type { WikiItem } from "./wikipedia";

/**
 * Two leagues, and the differences are not cosmetic:
 *
 *   path    ESPN namespaces the site API by sport
 *   sport   the Wikidata P641 value that proves a candidate article is the
 *           right KIND of athlete. Without it the NBA lookup for "Anthony
 *           Edwards" returns the ER actor, who holds the bare title.
 *   hint    appended to the Wikipedia search so relevance ranking starts in
 *           the right universe
 */
export type League = "nfl" | "nba";

const LEAGUES: Record<League, { path: string; sport: string; hint: string }> = {
  nfl: { path: "football/nfl", sport: "Q41323", hint: "American football" },
  nba: { path: "basketball/nba", sport: "Q5372", hint: "basketball" },
};

const espnBase = (league: League) =>
  `https://site.api.espn.com/apis/site/v2/sports/${LEAGUES[league].path}`;
const WP = "https://en.wikipedia.org/w/api.php";
const WD = "https://www.wikidata.org/w/api.php";
/**
 * Wikimedia asks for a descriptive User-Agent and ESPN refuses one: the site
 * API answers 403 to "DraftFor20/1.0 …" and 200 to a browser string or to no
 * UA at all. Verified against both /football/nfl/teams and /basketball/nba/teams.
 * So the honest UA goes to Wikimedia, who want it, and ESPN gets none.
 */
const UA = "DraftFor20/1.0 (https://draftfor20.vercel.app; hello@draftfor20.app)";

const HUMAN = "Q5";

export interface NflPlayer {
  name: string;
  position: string | null;
  team: string;
}

async function json(url: string): Promise<unknown> {
  const espn = new URL(url).host.endsWith("espn.com");
  const res = await fetch(url, {
    headers: espn ? {} : { "User-Agent": UA },
    cache: "no-store",
  });
  if (!res.ok) throw new Error(`${new URL(url).host} ${res.status}`);
  return res.json();
}

/** Every current team in a league, as ESPN ids. */
export async function fetchTeams(league: League = "nfl"): Promise<{ id: string; name: string }[]> {
  const j = (await json(`${espnBase(league)}/teams`)) as {
    sports?: { leagues?: { teams?: { team?: { id?: string; displayName?: string } }[] }[] }[];
  };
  const raw = j.sports?.[0]?.leagues?.[0]?.teams ?? [];
  return raw
    .map((t) => ({ id: String(t.team?.id ?? ""), name: t.team?.displayName ?? "" }))
    .filter((t) => t.id && t.name);
}

/**
 * One team's active roster.
 *
 * THE TWO LEAGUES RETURN DIFFERENT SHAPES. NFL groups athletes by position, so
 * `athletes` is [{items:[...]}]; NBA returns a flat array of athletes. Reading
 * only the NFL shape gives zero NBA players and no error at all, which is how
 * a whole league can quietly come back empty.
 */
export async function fetchRoster(teamId: string, league: League = "nfl"): Promise<NflPlayer[]> {
  const j = (await json(`${espnBase(league)}/teams/${encodeURIComponent(teamId)}/roster`)) as {
    team?: { displayName?: string };
    athletes?: unknown;
  };
  const team = j.team?.displayName ?? "";
  const raw = (j.athletes ?? []) as { items?: unknown[] }[];
  const flat = (Array.isArray(raw) && raw.length && raw[0]?.items
    ? raw.flatMap((g) => g.items ?? [])
    : raw) as { fullName?: string; position?: { abbreviation?: string } }[];
  return flat
    .map((a) => ({
      name: (a.fullName ?? "").trim(),
      position: a.position?.abbreviation ?? null,
      team,
    }))
    .filter((p) => p.name.length > 1);
}

/** Team display name -> Wikidata QID, resolved rather than hardcoded. */
export async function teamQid(teamName: string): Promise<string | null> {
  try {
    const j = (await json(
      `${WP}?${new URLSearchParams({
        action: "query",
        titles: teamName,
        prop: "pageprops",
        ppprop: "wikibase_item",
        redirects: "1",
        format: "json",
      })}`,
    )) as { query?: { pages?: Record<string, { pageprops?: { wikibase_item?: string } }> } };
    for (const p of Object.values(j.query?.pages ?? {})) {
      if (p.pageprops?.wikibase_item) return p.pageprops.wikibase_item;
    }
  } catch {
    /* no team key; disambiguation falls back to sport-only */
  }
  return null;
}

interface Candidate {
  title: string;
  human: boolean;
  sports: string[];
  teams: string[];
}

async function inspect(titles: string[]): Promise<Candidate[]> {
  if (!titles.length) return [];
  const j = (await json(
    `${WP}?${new URLSearchParams({
      action: "query",
      titles: titles.join("|"),
      prop: "pageprops",
      ppprop: "wikibase_item",
      redirects: "1",
      format: "json",
    })}`,
  )) as { query?: { pages?: Record<string, { title?: string; pageprops?: { wikibase_item?: string } }> } };

  const byTitle = new Map<string, string>();
  for (const p of Object.values(j.query?.pages ?? {})) {
    if (p.title && p.pageprops?.wikibase_item) byTitle.set(p.title, p.pageprops.wikibase_item);
  }
  if (!byTitle.size) return [];

  const e = (await json(
    `${WD}?${new URLSearchParams({
      action: "wbgetentities",
      ids: [...byTitle.values()].join("|"),
      props: "claims",
      format: "json",
    })}`,
  )) as { entities?: Record<string, { claims?: Record<string, unknown[]> }> };

  const out: Candidate[] = [];
  for (const [title, qid] of byTitle) {
    const claims = e.entities?.[qid]?.claims ?? {};
    const ids = (prop: string) =>
      ((claims[prop] ?? []) as { mainsnak?: { datavalue?: { value?: { id?: string } } } }[])
        .map((c) => c.mainsnak?.datavalue?.value?.id)
        .filter((x): x is string => !!x);
    out.push({
      title,
      human: ids("P31").includes(HUMAN),
      sports: ids("P641"),
      teams: ids("P54"),
    });
  }
  return out;
}

/**
 * A player's Wikipedia article, or null.
 *
 * Guessing a parenthetical does not work: the real ones are "(offensive
 * lineman)", "(defensive end)", and some players are at a different name
 * entirely — the Jaguars' edge rusher is "Josh Hines-Allen", not "Josh Allen".
 * So this searches, then VERIFIES against Wikidata rather than trusting a
 * title shape.
 *
 * P54 (member of sports team) is what makes it correct. Two NFL players are
 * called Josh Allen; the bare article is the Bills quarterback, so a roster
 * lookup for the Jaguars would otherwise put the wrong man's face on the
 * card. Matching the team removes the ambiguity outright. Without a team
 * match it falls back to any American-football human, which fixes the other
 * failure — "Trey Smith" alone is a disambiguation page with no picture,
 * while "Trey Smith (offensive lineman)" is the player.
 */
export async function resolvePlayerTitle(
  player: NflPlayer,
  teamKey: string | null,
  league: League = "nfl",
): Promise<string | null> {
  let titles: string[];
  try {
    const s = (await json(
      `${WP}?${new URLSearchParams({
        action: "query",
        list: "search",
        srsearch: `${player.name} ${LEAGUES[league].hint}`,
        srlimit: "6",
        format: "json",
      })}`,
    )) as { query?: { search?: { title: string }[] } };
    titles = (s.query?.search ?? [])
      .map((h) => h.title)
      .filter((t) => !/\(disambiguation\)/i.test(t));
  } catch {
    return null;
  }

  const cands = await inspect(titles);
  let footballers = cands.filter((c) => c.human && c.sports.includes(LEAGUES[league].sport));

  // THE NAME HAS TO MATCH. Relevance order alone is not a check: searching
  // "Miles Davis American football" returned TERRELL DAVIS, a different man
  // entirely, and the blind `footballers[0]` fallback put his photograph on a
  // card labelled Miles Davis. Surname alone is not enough either — that is
  // exactly what Miles/Terrell Davis share.
  //
  // First name must match; surname must match or contain, because the
  // Jaguars' Josh Allen is at "Josh Hines-Allen".
  footballers = footballers.filter((c) => sameName(player.name, c.title));

  // Prefer an actual PLAYER. P54 is "member of sports team"; coaches have a
  // different property, so a coach survives the sport filter with no teams.
  // "Bill Murray" resolved to "Bill Murray (American football coach)".
  const players = footballers.filter((c) => c.teams.length > 0);
  const pool = players.length ? players : footballers;

  if (teamKey) {
    const exact = pool.find((c) => c.teams.includes(teamKey));
    if (exact) return exact.title;
  }
  // search order is relevance order, so the first surviving candidate is the
  // best remaining guess
  return pool[0]?.title ?? null;
}

/** Strip the disambiguating parenthetical and fold accents/punctuation. */
function norm(s: string): string {
  return s
    .replace(/\s*\([^)]*\)\s*$/, "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z\s-]/g, "")
    .trim();
}

function sameName(playerName: string, title: string): boolean {
  const a = norm(playerName).split(/\s+/).filter(Boolean);
  const b = norm(title).split(/\s+/).filter(Boolean);
  if (!a.length || !b.length) return false;
  if (a[0] !== b[0]) return false; // Miles != Terrell
  const la = a[a.length - 1];
  const lb = b[b.length - 1];
  return la === lb || la.includes(lb) || lb.includes(la); // Allen ~ Hines-Allen
}

/**
 * A team's roster as items the image cascade understands.
 *
 * `title` may be null for a player with no verified article — a deep-roster
 * or practice-squad name. That is the expected outcome, not an error: the
 * resolver draws a generated card for them, and they are also exactly the
 * players nobody would bid on.
 */
export async function fetchNflRosterItems(
  teamId: string,
  league: League = "nfl",
): Promise<WikiItem[]> {
  const roster = await fetchRoster(teamId, league);
  if (!roster.length) return [];
  const teamKey = await teamQid(roster[0].team);

  const out: WikiItem[] = [];
  // sequential on purpose: two requests per player against two public APIs
  // that are being used as a courtesy, not under a contract
  for (const p of roster) {
    out.push({ name: p.name, title: await resolvePlayerTitle(p, teamKey, league) });
  }
  return out;
}
