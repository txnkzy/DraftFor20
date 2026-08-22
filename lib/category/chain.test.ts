import { describe, expect, it, vi } from "vitest";
import { runLookupChain, type ChainSteps, type FetchedList } from "./chain";

const LIST: FetchedList = { title: "dog breed", items: ["German Shepherd", "Beagle"] };

function steps(over: Partial<ChainSteps> = {}) {
  return {
    libraryMatch: vi.fn(async () => null),
    spendBudget: vi.fn(async () => true),
    wikidata: vi.fn(async () => null),
    wikipedia: vi.fn(async () => null),
    ...over,
  } as ChainSteps & Record<string, ReturnType<typeof vi.fn>>;
}

describe("the category lookup chain", () => {
  it("stops at the library and spends no budget", async () => {
    const s = steps({
      libraryMatch: vi.fn(async () => ({
        source: "library" as const, source_id: "x", name: "Dog Breeds", item_count: 40,
      })),
    });
    const out = await runLookupChain(s);

    expect(out.kind).toBe("hit");
    expect(s.spendBudget).not.toHaveBeenCalled();
    expect(s.wikidata).not.toHaveBeenCalled();
    expect(s.wikipedia).not.toHaveBeenCalled();
  });

  it("FALLS THROUGH to Wikipedia when Wikidata resolves nothing", async () => {
    // the case in the brief: a name too colloquial or abstract to be a
    // Wikidata class, where every candidate query comes back unusable
    const s = steps({
      wikidata: vi.fn(async () => null),
      wikipedia: vi.fn(async () => LIST),
    });
    const out = await runLookupChain(s);

    expect(s.wikidata).toHaveBeenCalledOnce();
    expect(s.wikipedia).toHaveBeenCalledOnce(); // the fallthrough itself
    expect(out).toMatchObject({ kind: "fetched", from: "wikipedia" });
  });

  it("does not reach Wikipedia when Wikidata answers", async () => {
    const s = steps({ wikidata: vi.fn(async () => LIST) });
    const out = await runLookupChain(s);

    expect(out).toMatchObject({ kind: "fetched", from: "wikidata" });
    expect(s.wikipedia).not.toHaveBeenCalled();
  });

  it("spends exactly ONE unit of budget even when both steps run", async () => {
    const s = steps({
      wikidata: vi.fn(async () => null),
      wikipedia: vi.fn(async () => LIST),
    });
    await runLookupChain(s);

    expect(s.spendBudget).toHaveBeenCalledOnce();
  });

  it("spends exactly one unit even when everything fails", async () => {
    const s = steps();
    const out = await runLookupChain(s);

    expect(out.kind).toBe("none");
    expect(s.spendBudget).toHaveBeenCalledOnce();
  });

  it("reaches neither service once the budget is gone", async () => {
    const s = steps({ spendBudget: vi.fn(async () => false) });
    const out = await runLookupChain(s);

    expect(out.kind).toBe("rate_limited");
    expect(s.wikidata).not.toHaveBeenCalled();
    expect(s.wikipedia).not.toHaveBeenCalled();
  });
});
