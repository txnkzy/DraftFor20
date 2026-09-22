# 07 · Frontend

---

## Design language

Palette (`app/globals.css`) — **semantic, not decorative**:

| Token | Hex | Means |
|---|---|---|
| `board` | `#14161C` | page ground |
| `surface` | `#1D2029` | cards, rails, rows |
| `coral` | `#FF5A36` | **tension only** — live bid, running timer, your turn |
| `gold` | `#F5B942` | **money only** |
| `teal` | `#2DD4BF` | resolved, passed, free |
| `ink` | `#E8E6E1` | text |
| `muted` | `#9C978E` | secondary text |

Players are told apart by **gold vs off-white** markers, never by coral or
teal — if identity used those, the palette would stop meaning anything.

Type: **Bricolage Grotesque** display, **Instrument Sans** body.

The signature element is **the Rail**: spent / available / hatched-reserved.
Hitting the reserve wall flashes the hatch rather than throwing a toast.

### Button colour

All three **plan** buttons are `btn-primary` (coral), everywhere plans are
sold. The **in-draft action buttons are deliberately not uniform**: Raise is
coral against an outlined Pass, Take is coral against a teal Give away. Those
are the two most time-critical decisions in the product and colour is how a
player tells them apart with a clock draining.

Every enabled control gets `cursor: pointer`, including the bare-text buttons
(sound toggle, room code, tap-to-type bid amount) which were the ones most
likely to be mistaken for plain text.

---

## Component map

| Folder | Holds |
|---|---|
| `components/board/` | The draft board — `ActionBar`, `OfferCard`, `BidBoard`, `RosterColumn`, `LotHistory`, `CardImage`, `FlipDigits` |
| `components/results/` | The final board and the share card model |
| `components/premium/` | `PlanCards`, `UpgradeDialog`, `UpgradeCard`, `BillingPanel`, `Padlock` |
| `components/lineup/` | `FlipReveal` — the ranking mode's riffle |
| `components/content/` | `VerticalStage` and the 9:16 surfaces |
| `components/profile/` | `HandleRow` (username editor), `ScoutingReport` |
| `components/site/` | `Chrome` (Header/Footer), `Turnstile`, `Analytics` |
| `components/ui/` | `Button`, `Field`, `TextInput` |

---

## State conventions

- **Game state** comes from `lib/game/useRoom.ts` — one hook, one
  subscription, `get_room_state` plus realtime.
- **Derived view state** is built in `lib/game/view.ts`, not in components.
- **`lib/game/rules.ts` is a UI HINT ONLY.** Its header says so. Every rule
  it expresses is re-checked in Postgres; it exists so the UI can disable a
  button before a round trip.
- **Session identity** is an external store (`useSyncExternalStore`), not
  effect-synced state, so the server render and the hydrated client agree.
  The same pattern is used for the lineup token.

### Two patterns worth copying

**Derive, don't store.** Both username fields compute validity as a pure
function of the input; only the availability round trip keeps state. Storing
it meant a `setState` inside an effect and a wasted render.

**Stamp every async check.** Each availability request carries a sequence
number and only the newest may write its answer. Without it a slow early
check lands after a fast later one and reports "taken" for a free name.

---

## Layout traps

**A stage rendered at true size and scaled cannot size its own parent.**
`VerticalStage` lays out at 1080×1920 and scales to fit, measured with a
ResizeObserver — so the measured box must be `position: relative; overflow:
hidden` with the stage absolutely positioned inside. Without that the 1920px
child grows the parent, the measurement is circular, and the frame overflows
the viewport.

**A percentage height needs a definite parent.** `VerticalStage` measures its
box to work out scale, so a wrapper sized by `min-height` plus `flex` gives
it `clientHeight === 0` and it draws nothing — a black rectangle that looks
like a broken board. Give the wrapper a real height (`h-[62dvh] lg:h-dvh`),
never `min-h-*`.

**Three cards do not go in a two-column grid.** The pricing page stacks below
`lg` rather than going two-wide, because three cards in a two-wide grid strand
the third alone at half width, which reads as a layout bug rather than a third
option. Subgrid (`grid-rows-subgrid`) keeps all six rows aligned across the
three cards.

**Wide content scrolls inside its own box**, never the page body.

---

## Effects and React 19

The repo lints `react-hooks/set-state-in-effect`. Two real hangs came from
getting this wrong:

1. **A one-shot ref guard inside an effect deadlocks under StrictMode.**
   React mounts, runs the effect, tears it down (clearing timers), and runs
   it again — where the guard schedules nothing. Make the effect
   **idempotent**: key the skip on the *settled state*, not on a ref.

2. **A dep that arrives late re-runs the effect and clears its timers.** The
   lineup riffle hung because its images loaded after first paint. Fixed by
   holding the card until the images are in hand, so the effect runs exactly
   once per card.

If you pass a callback into an effect's deps, **memoise it in the parent** —
an inline arrow changes identity every render.

---

## Images

`CardImage` has **no "no image" state**. A category with no pictures, a
source that went missing, and a hotlink that 404s months later all land on
the same generated card drawn from the item name. That is what lets the board
treat an image as always present instead of laying out twice.

`object-contain`, never `cover`: a club crest and a film poster have nothing
in common as shapes, and cropping either to fill a box is how a crest loses
its top half.

---

## The share card (Satori)

`/api/share-card/[code]` renders the 1080×1920 PNG.

**Satori only accepts `display: flex | contents | none`.** A `display: block`
anywhere fails the entire render. Every node needs an explicit display and
one text child.

It also carries a hand-maintained glyph subset string — if you add copy with
a character outside it, the character does not render.
