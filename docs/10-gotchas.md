# 10 · Gotchas

**The highest value-per-minute document here.** Every entry is a bug that
actually shipped, with the reason it was invisible.

---

## Postgres

### `revoke … from anon, authenticated` on a FUNCTION does nothing
PUBLIC holds the default grant. 100 of 103 functions were callable with the
publishable key. Write `revoke all on function f() from public, anon,
authenticated`. Tables are different — they have no default PUBLIC grant.
→ [04 · Security](04-security.md)

### A `create or replace` from an OLDER migration silently reverts a newer one
`df20_fill_pool`, `start_draft` and `df20_reveal_next` were restored to their
pre-`0043` bodies by a later run of an older definition. It left the image
columns and all 185 seeded portraits in place while quietly dropping the code
that carries a picture from library to lot. **Nothing errored; cards just
stopped having images.**

The same shape cost ~550 dead drafts when `offer_decide` lost its force
branch — twice.

### plpgsql does not validate function bodies at creation
A function can be created referencing one that does not exist. It fails only
when called. This has bitten at least four times. `df20_selfcheck()` and
`lib/rpc-parity.test.ts` exist because of it.

### Never split a caller from its dependency across migration files
The `df20_clean_logo_url` outage was exactly this: `create_room` in `0010`
calling a function defined in `0008`, which was never applied.

### Supabase's SQL editor runs statements individually
A failure partway through does **not** roll back what came before, so every
migration must be re-runnable from any partial state.

### `DROP TABLE … CASCADE` drops the foreign key but leaves the child table
A later `create table if not exists` then skips it, leaving orphaned rows
invisible to any query joining through the parent.

### `create or replace function` drops `proconfig`
It silently un-pins a `search_path` set by an earlier `alter function`.
Always set `search_path` in the function body.

### `get diagnostics x = row_count` needs an int, not a boolean
plpgsql creates the function anyway and fails at call time. The billing
idempotency check had this; `v6_premium.sql` caught it.

### `stable` and `immutable` functions run in a READ ONLY transaction
`my_scouting_report()` was written with a temp table; creating one would have
failed the moment it was called over HTTP, even though it worked in psql.
Aggregate in a CTE, or mark the function volatile and mean it.

### `translate()`'s from and to strings must be the same length
Otherwise it silently shifts the whole map. A stray space in the leet-fold
table made `!` map to blank.

### `df20_seed_category` upserts and never deletes
Re-seeding a category that has shrunk leaves every dropped item behind.
Delete the category's items first.

### A defaulted new argument makes every positional call ambiguous
Drop the old overloads before adding one. `0041` documents this for
`create_room`; `0010` had to do it for `df20_add_to_roster`.

---

## Supabase / PostgREST

### `.upsert()` needs UPDATE on the primary key
PostgREST compiles it to `on conflict do update set id = excluded.id`. This
is why the profile write is an RPC.

### `df20_public_state` returns `to_jsonb(rooms)`
**Every column you add to `rooms` lands in both players' browsers.** Add
token columns to the strip list.

### PKCE verifiers live in the browser
`createBrowserClient` stores the code verifier client-side, so
`exchangeCodeForSession` must run in the browser. `app/auth/callback/` is a
client page for this reason — a route handler could never succeed.

### `join_room` assigns the first FREE seat, not seat 2
A setup-link room has no players at all until someone joins, so hardcoding
seat 2 makes the first two joiners collide on `players_room_id_seat_key`.

---

## Next.js / React

### A route handler importing from a `"use client"` module gets a proxy
Not the value. Calling `.map()` on it 500s every surface that uses it. Put
shared constants in a file with no directive — see `lib/plans.ts`.

### `NEXT_PUBLIC_*` is inlined at BUILD time
Changing it in the dashboard does nothing to an existing deployment.

### A one-shot ref guard inside an effect deadlocks under StrictMode
React runs the effect, tears it down (clearing timers), and runs it again —
where the guard schedules nothing. Make effects **idempotent**.

### A dep that arrives late re-runs the effect and clears its timers
The lineup riffle hung forever because its images loaded after first paint.

### Satori only accepts `display: flex | contents | none`
`display: block` fails the entire share-card render.

### A scaled stage cannot size its own parent
And a percentage height needs a definite parent, or `VerticalStage` measures
`clientHeight === 0` and draws nothing.

---

## External APIs

### `prop=pageviews` answers for only SOME of the titles you ask
It returns a `continue` token for the rest. Reading the first response
**inverted** rankings — McDonald's scored 0, Auntie Anne's 12,506.

### Wikipedia redirects make a wrong picture look like a success
Cast members redirect to group articles, so `pageimages` returns the group
photo. Assert **distinct** portraits, not merely non-null.

### Never rank a person by their bare name
"Bill Murray" pageviews are the actor's. Verify the article first, then rank
on the resolved title.

### `hits[0]` is not the thing you searched for
Batman → Barbara Gordon, Hulk → Abomination, Deadpool → Yukio. Require an
exact bare-title match, then a name guard.

### Kitsu has no popularity signal
Its cast comes back alphabetically. Drive the roster by hand and use Kitsu
only for pictures.

### ESPN 403s on a descriptive User-Agent
Send none.

---

## Product traps

### Removing the gives cap breaks the game
Both players dumping every card is a stable equilibrium that ends the draft
$20 vs $20 with zero bids placed.

### `allow_broke` without Force-or-Take is a dead end
A broke player with no gives could only discard, card after card, until the
deck emptied and the results screen called them disqualified.

### Free and given are different facts
A forced pick is free but nobody gave it. Reusing the gift flag made the
board say "given" about a card nobody gave, and inflated the gift count.

### The audience vote link is free, deliberately
It is the acquisition loop. `0033` gated it; `0034` put it back.

### A wrong picture passes every assertion you have
Look at `/dev/cards` before shipping a seed.
