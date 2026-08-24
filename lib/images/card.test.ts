import { describe, expect, it } from "vitest";
import { cardDataUri, cardSvg, initials } from "./card";

describe("initials", () => {
  it("takes one letter per word, up to two", () => {
    expect(initials("Iron Man")).toBe("IM");
    expect(initials("Groot")).toBe("G");
    expect(initials("The Legend of Zelda")).toBe("TL");
  });

  it("treats punctuation as a word break, not as a letter", () => {
    expect(initials("Dr. No")).toBe("DN");
    // the hyphen separates two words, so "WE" is right — a card reading "W"
    // would be less recognisable, not more
    expect(initials("WALL-E")).toBe("WE");
  });

  it("never returns empty, because the card always has to render something", () => {
    expect(initials("")).toBe("?");
    expect(initials("!!!")).toBe("?");
  });
});

describe("cardSvg", () => {
  it("is deterministic, so a card can be cached by name", () => {
    expect(cardSvg("Iron Man")).toBe(cardSvg("Iron Man"));
  });

  it("gives different names different colours", () => {
    expect(cardSvg("Iron Man")).not.toBe(cardSvg("Captain America"));
  });

  it("never emits coral or gold, which mean tension and money elsewhere", () => {
    // hue is confined to 170-265; assert on every hue the generator can pick
    for (const name of ["a", "Iron Man", "Yosemite", "Abbey Road", "zzz", "Q"]) {
      const hue = Number(/hsl\((\d+)/.exec(cardSvg(name))?.[1]);
      expect(hue).toBeGreaterThanOrEqual(170);
      expect(hue).toBeLessThanOrEqual(265);
    }
  });

  it("escapes markup instead of letting an item name break the document", () => {
    const svg = cardSvg('Bond & <script>alert("x")</script>');
    expect(svg).not.toContain("<script>");
    expect(svg).toContain("&amp;");
  });

  it("renders the initials and nothing else as text", () => {
    // the board prints the name directly below; at ~150px tall a second copy
    // rendered around six pixels high and read as noise. The name survives in
    // aria-label, which is markup rather than something anyone has to read.
    const svg = cardSvg("The Fellowship of the Ring");
    const texts = [...svg.matchAll(/<text\b[^>]*>([\s\S]*?)<\/text>/g)].map((m) => m[1]);
    expect(texts).toEqual(["TF"]);
    expect(svg).not.toContain("DRAFTFOR20");
  });

  it("produces a data URI that declares itself as SVG", () => {
    expect(cardDataUri("Iron Man")).toMatch(/^data:image\/svg\+xml;charset=utf-8,/);
  });
});
