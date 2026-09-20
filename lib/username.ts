/**
 * Username rules, in the browser and at the API edge.
 *
 * THE DATABASE IS THE AUTHORITY. df20_handle_problem() in 0057 enforces
 * exactly these rules, and set_my_handle() and the signup trigger both ask
 * it. This file exists so the form can say what is wrong before a round
 * trip, and so the signup route can reject a malformed name without
 * troubling Supabase — not because it is trusted. Anything that reaches the
 * database is checked again there.
 *
 * Keep the two in step. If you add a rule here, add it to
 * df20_handle_problem, and vice versa — the parity test in username.test.ts
 * checks the reserved list and the shape rules against this same table.
 *
 * ONE RULE IS DELIBERATELY NOT MIRRORED: the explicit-word filter. Its list
 * lives in a table so an operator can extend it with an INSERT instead of a
 * deploy, and shipping a copy of it to every browser would both leak the
 * list and guarantee the two drift. usernameCode() therefore returns null
 * for a name the server will still refuse as "explicit" — which is fine,
 * because the form only enables submit once handle_available has answered.
 */

export const USERNAME_MIN = 3;
export const USERNAME_MAX = 20;
export const USERNAME_RULES = "3–20 characters · letters, numbers and underscores";

/** Names that would let somebody pose as the site or as staff, plus every
 *  top-level route, so a username can never read as a page path. */
export const RESERVED = [
  "admin", "administrator", "root", "staff", "mod", "moderator", "support", "help",
  "system", "official", "draftfor20", "draft420", "df20", "team", "owner",
  "api", "auth", "login", "signin", "signup", "logout", "profile", "settings",
  "billing", "pricing", "room", "rooms", "new", "vote", "votes", "results", "setup",
  "leaderboard", "dev", "obs", "privacy", "terms", "about", "contact", "null",
  "undefined", "anonymous", "anon", "you", "everyone", "host", "guest",
] as const;

export type UsernameProblem =
  | "required" | "too_short" | "too_long" | "charset" | "edge" | "reserved"
  | "taken" | "explicit";

/** The reason codes the database raises, as sentences a person can act on. */
export const USERNAME_SAYS: Record<UsernameProblem, string> = {
  required: "Pick a username.",
  too_short: `At least ${USERNAME_MIN} characters.`,
  too_long: `At most ${USERNAME_MAX} characters.`,
  charset: "Letters, numbers and underscores only.",
  edge: "Can't start or end with an underscore, or use two in a row.",
  reserved: "That one's reserved.",
  taken: "Taken — try another.",
  /* Its own message because "Taken" was a lie AND useless: the name is free,
     and the person is told to guess again with no idea what was wrong. */
  explicit: "Let's keep it clean — try another.",
};

/** null when the name is well formed. Says nothing about whether it is FREE:
 *  only the database's unique index can answer that. */
export function usernameCode(raw: string | null | undefined): UsernameProblem | null {
  const v = (raw ?? "").trim().toLowerCase();
  if (v.length === 0) return "required";
  if (v.length < USERNAME_MIN) return "too_short";
  if (v.length > USERNAME_MAX) return "too_long";
  if (!/^[a-z0-9_]+$/.test(v)) return "charset";
  if (!/^[a-z0-9]/.test(v)) return "edge";
  if (!/[a-z0-9]$/.test(v)) return "edge";
  if (v.includes("__")) return "edge";
  if ((RESERVED as readonly string[]).includes(v)) return "reserved";
  return null;
}

/** The same check, as the sentence an API response carries. */
export function usernameProblem(raw: string | null | undefined): string | null {
  const code = usernameCode(raw);
  return code ? USERNAME_SAYS[code] : null;
}
