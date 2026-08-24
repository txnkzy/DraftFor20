/**
 * The four-step category lookup, as pure control flow.
 *
 * The steps themselves are injected, so the two properties that matter can be
 * tested without a network: that a dead Wikidata step FALLS THROUGH to
 * Wikipedia rather than ending the lookup, and that one host-initiated
 * lookup spends exactly one unit of rate-limit budget however many API calls
 * it took underneath.
 *
 *   1 library / cache match   free, no budget
 *   2 Wikidata by sitelinks   ─┐
 *   3 Wikipedia by pageviews  ─┴ one shared unit of budget between them
 *   4 nothing                  the manual setup path
 */

export interface LibraryHit {
  source: "library" | "wikipedia" | "wikidata";
  source_id: string;
  name: string;
  item_count: number;
  score?: number;
}

export interface FetchedList {
  title: string;
  items: string[];
  entityId?: string;
  /** step 3 only: whether pageviews actually ranked this */
  popularityFiltered?: boolean;
}

export type ChainOutcome =
  | { kind: "hit"; hit: LibraryHit }
  | { kind: "fetched"; from: "wikidata" | "wikipedia"; list: FetchedList }
  | { kind: "none" }
  | { kind: "rate_limited" };

export interface ChainSteps {
  /** step 1 — the shelf and the cache. Never costs budget. */
  libraryMatch: () => Promise<LibraryHit | null>;
  /** the single unit of budget covering every external lookup below */
  spendBudget: () => Promise<boolean>;
  /** step 2 — null means "no usable class", which is not an error */
  wikidata: () => Promise<FetchedList | null>;
  /** step 3 — null means no parseable list */
  wikipedia: () => Promise<FetchedList | null>;
}

export async function runLookupChain(steps: ChainSteps): Promise<ChainOutcome> {
  // ── 1. already known ────────────────────────────────────────────────────
  const hit = await steps.libraryMatch();
  if (hit) return { kind: "hit", hit };

  // ── budget, once ────────────────────────────────────────────────────────
  // Taken here, before any external call, and never again. Steps 2 and 3 are
  // two halves of ONE lookup as far as the host is concerned; charging them
  // separately would let a single search eat two of ten hourly attempts, and
  // charging per underlying API call would burn an hourly allowance on one
  // search that happened to try four candidate classes.
  if (!(await steps.spendBudget())) return { kind: "rate_limited" };

  // ── 2. Wikidata ─────────────────────────────────────────────────────────
  const wd = await steps.wikidata();
  if (wd) return { kind: "fetched", from: "wikidata", list: wd };

  // ── 3. Wikipedia. Reached precisely because step 2 gave nothing. ────────
  const wp = await steps.wikipedia();
  if (wp) return { kind: "fetched", from: "wikipedia", list: wp };

  // ── 4. nothing doing ────────────────────────────────────────────────────
  return { kind: "none" };
}
