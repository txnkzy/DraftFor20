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

const ESPN = "https://site.api.espn.com/apis/site/v2/sports/football/nfl";
const WP = "https://en.wikipedia.org/w/api.php";
const WD = "https://www.wikidata.org/w/api.php";
const UA = "DraftFor20/1.0 (https://draftfor20.vercel.app; hello@draftfor20.app)";

const HUMAN = "Q5";
const AMERICAN_FOOTBALL = "Q41323";

export interface NflPlayer {
  name: string;
  position: string | null;
  team: string;
}

async function json(url: string): Promise<unknown> {
  const res = await fetch(url, { headers: { "User-Agent": UA }, cache: "no-store" });
  if (!res.ok) throw new Error(`${new URL(url).host} ${res.status}`);
  return res.json();
}

/** Every current NFL team, as ESPN ids. */
export async function fetchTeams(): Promise<{ id: string; name: string }[]> {
  const j = (await json(`${ESPN}/teams`)) as {
    sports?: { leagues?: { teams?: { team?: { id?: string; displayName?: string } }[] }[] }[];
  };
  const raw = j.sports?.[0]?.leagues?.[0]?.teams ?? [];
  return raw
    .map((t) => ({ id: String(t.team?.id ?? ""), name: t.team?.displayName ?? "" }))
    .filter((t) => t.id && t.name);
}

/** One team's active roster. */
export async function fetchRoster(teamId: string): Promise<NflPlayer[]> {
  const j = (await json(`${ESPN}/teams/${encodeURIComponent(teamId)}/roster`)) as {
    team?: { displayName?: string };
    athletes?: { items?: { fullName?: string; position?: { abbreviation?: string } }[] }[];
  };
  const team = j.team?.displayName ?? "";
  return (j.athletes ?? [])
    .flatMap((g) => g.items ?? [])
    .map((a) => ({
      name: (a.fullName ?? "").trim(),
      position: a.position?.abbreviation ?? null,
      team,
    }))
    .filter((p) => p.name.length > 1);
}

/** Team display name -> Wikidata QID, resolved rather than hardcoded. */
async function teamQid(teamName: string): Promise<string | null> {
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
): Promise<string | null> {
  let titles: string[];
  try {
    const s = (await json(
      `${WP}?${new URLSearchParams({
        action: "query",
        list: "search",
        srsearch: `${player.name} American football`,
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
  const footballers = cands.filter((c) => c.human && c.sports.includes(AMERICAN_FOOTBALL));

  if (teamKey) {
    const exact = footballers.find((c) => c.teams.includes(teamKey));
    if (exact) return exact.title;
  }
  // search order is relevance order, so the first surviving candidate is the
  // best remaining guess
  return footballers[0]?.title ?? null;
}

/**
 * A team's roster as items the image cascade understands.
 *
 * `title` may be null for a player with no verified article — a deep-roster
 * or practice-squad name. That is the expected outcome, not an error: the
 * resolver draws a generated card for them, and they are also exactly the
 * players nobody would bid on.
 */
export async function fetchNflRosterItems(teamId: string): Promise<WikiItem[]> {
  const roster = await fetchRoster(teamId);
  if (!roster.length) return [];
  const teamKey = await teamQid(roster[0].team);

  const out: WikiItem[] = [];
  // sequential on purpose: two requests per player against two public APIs
  // that are being used as a courtesy, not under a contract
  for (const p of roster) {
    out.push({ name: p.name, title: await resolvePlayerTitle(p, teamKey) });
  }
  return out;
}
