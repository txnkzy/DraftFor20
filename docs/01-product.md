# 01 · Product

What the app does, mode by mode, and the rules that define each one.

---

## The draft — the original mode

`N` roster slots per player means `2N` picks, so `2N` lots.

1. The server deals a card from the room's hidden deck and opens it at the
   minimum bid, with the **opener** (alternating each card) holding it.
2. The opener chooses **Take at $1** or **Give it away** (it lands free on
   the opponent's roster and costs one of their limited gives).
3. On Take, the opponent raises or passes, and the ping-pong runs until
   someone passes or the clock expires.
4. The draft ends when both rosters are full. There is **no algorithmic
   winner** — leftover cash is the scoreboard, plus a one-tap human vote.

### The money rules

```
open(P)          = picks P still owes, INCLUDING the one being bid on
reserve(P)       = min_bid × (open(P) − 1)
max_legal_bid(P) = bankroll(P) − reserve(P)
```

**Hard cap:** never more than the bankroll — under every setting, always.

**Reserve rule:** keep back the minimum bid for every other slot you still
owe. This is now **opt-out**: `rooms.allow_broke` defaults to `true`, which
skips the reserve entirely and lets a player spend to zero. That is the
format the trend actually plays — people spend everything on someone they
want and live with the consequences.

In an underfunded room the raw formula goes negative and would deadlock a
player out of every action, so it degrades: capped at exactly one minimum bid
while solvent, then **broke**.

### Force-or-Take

When a player is broke, owes slots and has no gives left, the dealt card
**lands on their own roster for $0**. Not the opponent's — being out of money
does not entitle you to fill someone else's board.

This is the floor of the format and it is *not* a punishment: it is the other
half of `allow_broke`. Without it, a broke player could only discard, card
after card, until the deck emptied and the results screen called them
disqualified.

A forced pick is flagged `forced` as well as `gifted`, and the board says
**FORCED**, not "given" — free and given are different facts, and the bid
history is the thing people rewatch.

### Bids move in whole dollars

The stepper raises by exactly $1. The floor still clamps to the ceiling, so a
player with 40¢ of headroom over the standing bid can still place it — the
server has never required a minimum increment, so no legal bid is hidden.

### Gives

**`gives_per_player` defaults to 2.** Without a cap, both players dumping
every card is a stable equilibrium that ends the draft $20 vs $20 with zero
bids placed. **Do not remove this cap without replacing it with something.**

### The clock

`lots.turn_expires_at` is the countdown, and `get_room_state` returns
`server_now` so clients correct for clock skew. A client that stalls its own
JS cannot buy time. It is **null when `timer_seconds` is 0**, which is how a
no-limit room works.

---

## Quick Play — solo against a bot

`/quick-play` creates a room with `is_solo = true` and a second seat flagged
`is_bot`. The bot's decisions come from `df20_bot_heuristic` / `bot_act`.

It exists because roughly **one room in four never found a second player**.
Capped at **3 games a day** for free accounts and devices, unlimited with
premium. The cap is keyed on an httpOnly cookie (`df20_sk`) issued by
`/api/solo/key`, or on the account id when signed in — an account beats a
cookie, because it cannot be cleared.

---

## Build the Lineup — solo ranking

`/rank`. Pick a category, then five cards are dealt **one at a time**. Each
must be placed in a ranked slot (1 best, 5 worst) **before the next is
shown**, and slots never reopen.

The tension is the whole mode: putting the strongest character you have seen
at slot 1 is a bet that nothing better is coming. When something better
arrives two cards later, the regret is the game.

- The five cards are written at creation and hidden. `lineups.revealed` gates
  every read — the same deck rule as the draft.
- The riffle animation cycles the **category's** public art, so it leaks
  nothing about the five dealt.
- **No algorithmic score.** There is no power ranking in the database, and
  Wikipedia traffic — the only popularity signal the seeders use — gets the
  motivating case backwards. Instead a finished lineup gets a share link, and
  whoever opens it rates it out of ten, **blind until they have voted**.
- Shares the same 3-a-day single-player cap as Quick Play.

---

## The leaderboard

`/leaderboard` ranks by most wins, most drafts, or win rate — each a real URL
so a sort can be shared.

**A "win" is `df20_manual_winner` and nothing else**: the audience vote's
majority, with a tie scoring for nobody. The profile page has counted wins
that way since migration 0017, and a second definition here would let a
player's own profile and the public board disagree about the same draft.

Win rate is computed over **decided** drafts only — a draft nobody voted on
is not a loss — and needs 5 drafts to rank, or one lucky win tops the table.

Only completed rooms and only seats attached to an account are counted.

---

## The two room layouts

`rooms.content_mode` is `standard` or `creator`, set at creation and never
changed. It is not a skin:

| | Standard | Content Creator |
|---|---|---|
| shape | three-column desktop grid | one 9:16 column |
| rosters | left and right of the card | stacked, top and bottom third |
| card, bid, clock | upper middle, in a panel | dead centre, big |
| the Rail | under both names | not shown |
| bid history | under the board | not shown |
| reserved space | none | right 200px, bottom 150px, for TikTok's buttons |
| ground | `--color-board` | pure black |

`VerticalStage` is the frame, and the same component draws Record Mode (same
stage, fullscreen, black) and the OBS browser source (same stage, transparent
ground). One layout, three grounds.

---

## Usernames

Every account picks a username at signup (3–20 chars, letters/digits/
underscore). It is editable from the profile, validated in one Postgres
function called by the rename, the availability check and the signup trigger.

Accounts created before this shipped have a generated handle and
`handle_chosen = false`, which is what makes the profile page prompt them.

An explicit name is refused with its own message — *"Let's keep it clean —
try another."* — rather than the false "taken". The word list is a **table**,
so an operator extends it with an `INSERT` rather than a deploy.

---

## Rematch — "Run it back"

`create_rematch` copies the settings, seats both players under the names they
just used, and **copies the room pool** so the rematch plays the same
category. The deck is drawn fresh, so it is the same category reshuffled,
never the same order.

For a solo room it also carries `is_solo`, `solo_key` and the bot seat — and
counts against the daily cap, so the cap cannot be walked around by pressing
Run it back.
