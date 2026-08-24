/** DF20_* codes from the RPCs, in language a player can read mid-countdown. */
const MESSAGES: Record<string, string> = {
  DF20_NO_ROOM: "That room code doesn't exist.",
  DF20_BAD_TOKEN: "You're not seated in this room.",
  DF20_ROOM_FULL: "This room already has two players.",
  DF20_ALREADY_STARTED: "This draft already started.",
  DF20_NEED_TWO_PLAYERS: "Wait for the second player.",
  DF20_HOST_ONLY: "Only the host can start the draft.",
  DF20_WRONG_PHASE: "The board moved on.",
  DF20_NOT_YOUR_TURN: "Not your turn.",
  DF20_NOT_YOUR_DECISION: "Your opponent is deciding.",
  DF20_BAD_VOTE: "That isn't a player in this room.",
  DF20_STALE: "The board moved. Look again.",
  DF20_EXPIRED: "Time ran out.",
  DF20_NO_LIVE_LOT: "Nothing is up for bid right now.",
  DF20_TOO_LOW: "Bid higher than the current bid.",
  DF20_OVER_BANKROLL: "You don't have that much.",
  DF20_OVER_RESERVE: "No room left. You have to keep enough to fill your other slots.",
  DF20_BELOW_MIN_BID: "That's under the minimum bid.",
  DF20_CANNOT_AFFORD: "You can't cover the minimum on this one.",
  DF20_NO_GIVES_LEFT: "You're out of gives. You have to take this one.",
  DF20_THEY_ARE_FULL: "Their roster is full, so you can't hand it over.",
  DF20_ROSTER_FULL: "Your roster is already full.",
  DF20_BAD_ROSTER_SIZE: "Roster size has to be 1 to 30.",
  DF20_BAD_GIVES: "Gives per player has to be 0 to 30.",
  DF20_POOL_TOO_SMALL: "Not enough names in the pool for that roster size.",
  DF20_MUST_TAKE_OR_GIVE: "You can still take this one or hand it over.",
  DF20_BAD_CHOICE: "That isn't one of the options.",
  DF20_BAD_NAME: "Pick a name, 24 characters or fewer.",
  DF20_TITLE_TOO_LONG: "Title caps at 60 characters.",
  DF20_BAD_BANKROLL: "That bankroll isn't valid.",
  DF20_BAD_MIN_BID: "That minimum bid isn't valid.",
  DF20_BAD_TIMER: "Timer has to be 3 to 300 seconds.",
  DF20_EMAIL_UNVERIFIED:
    "Confirm your email first. We sent you a link when you signed up.",
  DF20_EMAIL_RATE_LIMIT:
    "Our email provider is rate limiting us. Sign in with your password instead.",
  DF20_RATE_LIMITED: "Too many requests just now. Give it a few minutes.",
  DF20_SIGNIN_REQUIRED: "Custom categories need an account. Sign in and you'll come straight back.",
  DF20_PREMIUM_REQUIRED: "That one's premium. There's an upgrade panel wherever it's locked.",
  DF20_BAD_CONTENT_MODE: "That isn't a room layout.",
  DF20_NOT_YOUR_DECK: "That deck belongs to a different account.",
  DF20_NOT_AUTHORISED: "That isn't something this account can do.",
  DF20_LAST_ADMIN:
    "That's the only admin left. Give someone else admin access first, or the console locks everyone out.",
  DF20_NO_SUCH_USER: "That account doesn't exist.",
  DF20_BAD_HANDLE: "Handles are 3 to 20 characters: letters, numbers, dashes and underscores.",
  DF20_RESERVED_HANDLE: "That handle is reserved.",
  DF20_HANDLE_TAKEN: "Somebody already has that handle.",
  DF20_NO_SUCH_CATEGORY: "That category isn't there any more.",
  DF20_BAD_ACCENT: "Accent colours are hex, like #F5B942.",
  DF20_BAD_LOGO_URL: "That logo has to be one you uploaded here.",
  DF20_NOT_COMPLETE: "The draft isn't finished.",
  DF20_INVARIANT_NEGATIVE_BANKROLL:
    "The server caught an impossible money state and stopped. Nothing was charged.",
};

export function readableError(raw: string | null | undefined): string {
  if (!raw) return "Something went wrong.";
  for (const code of Object.keys(MESSAGES)) {
    if (raw.includes(code)) return MESSAGES[code];
  }
  if (/fetch|network|Failed to fetch/i.test(raw)) return "Lost the connection. Reconnecting.";
  return raw;
}

/** True for rejections caused by hitting a money wall, which the Rail flashes. */
export function isMoneyWall(raw: string | null | undefined): boolean {
  return Boolean(raw && (raw.includes("DF20_OVER_RESERVE") || raw.includes("DF20_OVER_BANKROLL")));
}
