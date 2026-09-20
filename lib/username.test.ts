import { describe, expect, it } from "vitest";
import { RESERVED, usernameCode } from "./username";

/**
 * These rules are enforced twice: here, and in df20_handle_problem() in
 * migration 0057. This file guards the browser half. If it changes, change
 * the SQL — a name the form accepts and the database refuses is a dead end
 * the user cannot get out of.
 */
describe("username rules", () => {
  it("accepts ordinary names", () => {
    for (const ok of ["mason", "abc", "a_b", "user_1", "x".repeat(20), "0cool"]) {
      expect(usernameCode(ok), ok).toBeNull();
    }
  });

  it("is case and whitespace insensitive", () => {
    expect(usernameCode("  MaSoN  ")).toBeNull();
  });

  it("rejects the wrong length", () => {
    expect(usernameCode("")).toBe("required");
    expect(usernameCode("ab")).toBe("too_short");
    expect(usernameCode("x".repeat(21))).toBe("too_long");
  });

  it("rejects anything but letters, digits and underscore", () => {
    for (const bad of ["has space", "dash-name", "emoji😀", "dot.name", "at@name"]) {
      expect(usernameCode(bad), bad).toBe("charset");
    }
  });

  it("rejects underscores at the edges or doubled", () => {
    for (const bad of ["_lead", "trail_", "a__b"]) {
      expect(usernameCode(bad), bad).toBe("edge");
    }
  });

  it("rejects names that impersonate the site or shadow a route", () => {
    for (const bad of ["admin", "support", "draftfor20", "leaderboard", "billing"]) {
      expect(usernameCode(bad), bad).toBe("reserved");
    }
  });

  it("keeps every reserved word reachable", () => {
    // A reserved word shorter than the minimum can never be reported as
    // reserved — length is checked first — so it is dead weight in the list
    // and hides which rule actually rejected the name. "me" was exactly that.
    for (const w of RESERVED) {
      expect(usernameCode(w), w).toBe("reserved");
    }
  });
});
