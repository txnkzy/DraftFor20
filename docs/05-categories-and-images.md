# 05 · Categories and images

32 premade categories, 1,398 items, 1,368 with pictures. Getting the picture
right is most of the work, and most of the bugs.

---

## The four category sources

| Source | Free? | How it works |
|---|---|---|
| `library` | yes | The 32 premade categories — the shelf |
| `wikipedia` | **account** | Trigram match, then parse a "List of …" article |
| `manual` | **account** | A third party builds the list via a setup link |
| `saved` | **account** | A deck the host kept from an earlier draft, reshuffled |

Since `0033`, **any host-supplied category is premium** — free is the premade
shelf. The boundary is drawn by which *table* is reachable, not by a flag.

A **saved deck returns names and counts only, never items**: the host of a
handoff room has never seen that list, and reusing it must not be the thing
that shows it to them.

### Fuzzy matching

`pg_trgm` at **0.5**, plus a token-overlap guard: two names must share a
*meaningful* word. Without the guard, "nhl teams" matched NFL Teams at 0.538,
because the shared word "teams" is most of a short string.

---

## Where the pictures come from

`lib/images/` runs a cascade. **Wikidata is the router** — one request per
batch gives three things at once:

1. a KIND from P31 (`film`, `album`, `club`, `person`…) so the item goes to
   the source that specialises in it
2. a free-licensed image from P18/P154/P41
3. external IDs (TMDB, MusicBrainz, ISBN) so the specialist lookup is an
   **exact fetch** rather than a name search that can land on the wrong thing

Point 3 is why Wikidata sits in front: searching TMDB for "Iron Man" is a
guess; fetching TMDB movie 1726 because Wikidata says so is not.

---

## Licensing is a real constraint

| Category family | Licence | Why |
|---|---|---|
| Sports (NFL/NBA Players) | `free` — Commons only | A roster is a set of facts and facts are not copyrightable; a **photograph is**. ESPN's headshot CDN would give 100% coverage and no right to use any of it |
| Anime | `nonfree` — fair use | MyAnimeList art |
| Brands (fast food, candy) | `nonfree` — fair use | A logo is the trademark holder's |

`lib/espn.ts` takes the **roster** from ESPN and nothing else.

---

## Provider lessons

### Wikipedia does not work for a cast

Only the nine Straw Hats have their own article; everyone else **redirects**
to a group article, so `pageimages` cheerfully returns the Straw Hats line-up
for Jinbe and the Four Emperors for Shanks. A wrong picture is worse than
none, and the redirect makes it look like a success — which is why
`v8_images.sql` asserts **distinct** portraits, not just non-null ones.

### Jikan vs Kitsu — good at different things

- **Jikan (MyAnimeList)** has a `favorites` count, so a series it can serve
  is ranked by popularity and the top N is a good draft.
- **Kitsu has no popularity signal at all.** After the handful flagged
  `role:"main"`, the cast comes back **alphabetically** — taking the first
  fifty Dragon Ball entries yields Piccolo, Goku, Vegeta, then Ackman,
  Angela, Appule.

A Kitsu series is therefore driven by a **hand-written roster** in the
generator, with Kitsu used only to turn a name into a picture. That also
fixes naming, because Kitsu romanises from the Japanese: *Kuririn*,
*Tenshinhan*, *Jinzouningen 17-gou* — none of which is the word a player
recognises.

One Piece / Naruto / Demon Slayer are Jikan. JJK / DBZ / MHA are curated
Kitsu.

**Jikan only serves a cast it has already cached.** An uncached one needs a
live MyAnimeList fetch, and when MAL refuses, that arrives as a 504 that
retrying does not fix. The generator **skips a series it cannot fetch and
reports it** rather than aborting the run.

### Name order is per series and is not cosmetic

MyAnimeList stores every name as "Surname, Given".

- One Piece and Dragon Ball rejoin **surname-first** — *Monkey D. Luffy*,
  *Son Goku*
- Naruto, Demon Slayer, JJK and MHA rejoin **given-first** — *Naruto
  Uzumaki*, *Tanjiro Kamado*

MAL also romanises long vowels literally — *Tanjirou*, *Kyoujurou*, *Giyuu* —
which every English release drops, so the generator strips them. Both are
per-series settings in `SERIES`, with a `renames` map for the handful neither
rule gets right (*Clown, Caesar* is Caesar Clown; *Might, Guy* is not Guy
Might).

---

## Ranking traps

### `prop=pageviews` answers for only SOME of the titles you ask about

It hands back a `continue` token for the rest. Reading the first response
looked like it worked and was wrong in a way that **inverted the results**:
McDonald's scored 0 while Auntie Anne's scored 12,506, and Joe Flacco
outranked Patrick Mahomes.

`rankByPageviews` follows the continuation now. Anything ranked before that
fix was ranked on roughly half its data.

### Never rank players by their bare name

Wikipedia pageviews for "Bill Murray" are the actor's, and there is a real
NFL lineman by that name, so he placed **third in the league**.

The generator verifies the article **first** (Wikidata P641 sport + P54
team), then re-ranks on the resolved title. A short `CROSS_SPORT_NAMESAKES`
list catches the rest, because "Michael Jordan (offensive lineman)" still
inherits traffic across a disambiguated name.

### Resolve by SEARCH, then guard the result

For anything that is a *name* rather than a *thing*, resolve by search — then
**require the result to match**: exact bare title first (Wikipedia gives the
original the bare name and pushes remakes into a parenthetical), then a name
guard. Otherwise search relevance hands you a sibling: `hits[0]` gave Batman
as Barbara Gordon, Hulk as Abomination, and Deadpool as Yukio.

### A roster is not a draft

NFL rosters run to 3,015 players and most of a roster is practice squad.
Measured over 60 days of traffic the cast splits cleanly in two — Bijan
Robinson at 58,695, then a flat 19–21k plateau of stub articles nobody
sought out. The generator cuts at **40% of the tenth-ranked player** rather
than taking a fixed top N. That yields ~37 NFL and ~31 NBA, all recognisable.

---

## A WRONG picture passes every assertion you have

The checks catch missing images and duplicated ones. They **cannot** catch an
image that is present, unique and of the wrong thing.

Caught only by looking: Cyclops as a Greek statue, Wolverine as the **animal**,
Captain America as a science museum in Valencia, Nirvana's "Lithium" as the
chemical element, The Cranberries' "Zombie" as Haitian folklore, Airheads as
the 1994 **film**, Haribo as the company's **head office**, Puffins as the
**bird**, Kryptonite as the DC mineral, and half of Disney as the live-action
remakes.

> **Look at every category in `/dev/cards` before shipping a seed.**

---

## Regenerating a category

```bash
node scripts/build-anime-seed.mjs          # anime (One Piece has its own script)
SEED=1 npx vitest run lib/espn.seed.test.ts # NFL/NBA rosters — go stale, re-run after a trade deadline
BRANDS=1 npx vitest run lib/brands.seed.test.ts
```

Names and URLs are **positional** — never hand-edit one list without the
other.

### `df20_seed_category` upserts and never deletes

Re-seeding a category that has **shrunk** leaves every dropped item behind —
which is how a list cut to 37 stars kept all 70 of its practice-squad names.
`0049` deletes the category's items first. **Do the same for any regenerated
category.**
