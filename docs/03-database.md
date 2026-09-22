# 03 · Database

~173 functions, 29 tables, 74 migrations. Postgres via Supabase.

---

## Tables, by purpose

### The game
| Table | Holds |
|---|---|
| `rooms` | One per draft. 34 columns — settings, status, phase, tokens, mode flags |
| `players` | Two seats per room. `session_token`, `bankroll_cents`, `is_bot` |
| `room_pool` | The candidate items copied into a room at creation |
| `room_deck` | The shuffled subset actually dealt. **Never readable by a client** |
| `lots` | One per card dealt. Bid state, clock, opener, winner |
| `bid_events` | The append-only history strip |
| `roster_entries` | What each player ended up with, and at what price |
| `votes` / `audience_votes` | The players' vote and the public one |

### Ranking mode
| Table | Holds |
|---|---|
| `lineups` | One per run. `revealed` gates what the player may see |
| `lineup_cards` | The five dealt cards and where they were placed |
| `lineup_ratings` | One rating per voter key |

### Accounts and content
| Table | Holds |
|---|---|
| `profiles` | The account row. Premium, branding, handle, admin flag |
| `category_library` / `_items` / `_aliases` | The 32 premade categories |
| `user_categories` / `user_category_items` | Saved decks |
| `wikipedia_cache` / `_items` | Parsed "List of …" articles |
| `templates` | Saved room settings |

### Operations
`billing_events`, `admin_audit`, `rate_limits`, `signup_signals`,
`df20_config`, `disposable_domains`, `blocked_handle_words`,
`allowed_handle_words`.

---

## Naming conventions

| Prefix | Meaning | Client-callable? |
|---|---|---|
| `df20_*` | Internal helper | **No** — revoked from PUBLIC |
| `my_*` | Reads the caller's own data, keyed on `auth.uid()` | Yes, authenticated |
| `admin_*` | Gated on `df20_is_admin()` | Yes, admins only |
| everything else | A client action | Yes, explicitly granted |

Errors are raised as `DF20_SCREAMING_SNAKE` and mapped to human sentences in
`lib/game/errors.ts`. Add both halves when you add an error.

---

## The RPC catalogue

**Game loop:** `create_room` · `join_room` · `start_draft` · `offer_decide` ·
`place_bid` · `pass_turn` · `expire_turn` · `leave_room` · `get_room_state`

**Solo:** `create_solo_room` · `bot_act` · `df20_bot_turn` · `df20_solo_quota`

**Lineup:** `create_lineup` · `place_lineup_card` · `my_lineup_state` ·
`public_lineup` · `rate_lineup` · `lineup_rating_state` · `lineup_flip_images`

**Rematch:** `create_rematch` · `claim_rematch`

**Account:** `save_profile` · `my_profile_stats` · `my_premium` ·
`my_handle` · `set_my_handle` · `handle_available` · `my_scouting_report` ·
`my_decks` · `my_rooms`

**Audience:** `cast_audience_vote` · `get_audience_state` ·
`get_audience_tally_for_voter` · `get_audience_hub` · `submit_vote`

**Content:** `list_free_categories` · `df20_match_category` ·
`save_room_deck` · `delete_deck` · `setup_lock_items` · `get_setup_state`

**Broadcast:** `mint_obs_token` · `rotate_obs_token` · `get_obs_state`

**Leaderboard:** `df20_leaderboard` · `room_scouting`

**Admin:** `admin_activity` · `admin_list_profiles` · `admin_set_premium` ·
`admin_set_admin` · `admin_library_*` · `admin_audit_log` ·
`admin_billing_stats` · `admin_recent_events` · `admin_user_signals`

---

## Migrations

### Two naming schemes, both valid

Files `0001`–`0069` are hand-numbered. Newer work is **timestamped**:

```bash
npm run new:migration -- add_widget_table
# → supabase/migrations/20260920034912_add_widget_table.sql
```

A UTC timestamp cannot collide unless two people create a file in the same
second, which removes the class of problem rather than policing it. Fourteen
digits sort after four as plain strings, so new work always runs last.

Existing files keep their numbers — renaming a migration somebody has already
applied buys nothing and risks it running twice.

### ORDER ENCODES DEPENDENCY, NOT AUTHORSHIP

`supabase/build-bundle.sh` defines the apply order, and it is **not** sorted.
Several entries are deliberately out of numeric order with a comment saying
why. Examples that have already cost real outages:

- `0041_allow_broke` runs **after** six migrations that postdate it
- `0055_force_or_take` runs **after** `0041_allow_broke`, which it restates
- `0065_restore_force_or_take` is **absolutely last** — four files define
  `offer_decide` and three have no force branch, so whichever runs last wins.
  This was lost twice: 8 Sep (12 days, ~550 dead drafts) and again on 20 Sep
  within two hours of being fixed.
- `0069_lineups` runs after `0067`, which is where `df20_solo_quota` is
  defined — 0069 restates it to count lineups too

**Do not sort this list.** Moving an entry silently reverts the loser, with
no error.

### Applying

```bash
npm run db:status      # what is applied, pending, or changed since
npm run db:baseline    # ONE TIME, on a database you believe is up to date
npm run db:push        # run the pending ones, oldest first, then reload PostgREST
```

`SUPABASE_DB_URL` is the credential — dashboard → Project Settings →
Database → Connection string → URI, password substituted. Put it in
`.env.local`, which is gitignored. Nothing in the repo stores or prints it.

`db:push` stops at the first failure and applies nothing after it. It does
**not** wrap each file in a transaction, deliberately: these were written for
the Supabase SQL editor, which runs statements one at a time and does not
roll back, so they must be re-runnable from a partial state.

`supabase/APPLY_V7.sql` is the paste-into-the-editor bundle. Rebuild it after
editing any migration:

```bash
./supabase/build-bundle.sh
```

### Numbering check

```bash
npm run check:migrations
```

Fails on two files claiming one number, and on one function being defined by
two different files at the same number — the case where nothing decides which
definition wins. Redefining a function in a *later* migration is normal.

---

## The two self-checks

Both run in the bundle footer and are the fastest way to tell whether a
database is healthy:

| Function | Asserts |
|---|---|
| `df20_selfcheck()` | ~89 functions, 24 tables and 13 columns **exist** |
| `df20_grant_check()` | What must **not** be reachable: locked columns, anon shut out of profiles/templates, deck sealed |

Plus focused ones: `df20_selfcheck_usernames()`,
`df20_selfcheck_lineups()`, `df20_selfcheck_force()`,
`df20_selfcheck_genres()`.

**Keep them updated when you add an RPC.** plpgsql does not validate function
bodies at creation — a function can be created referencing one that does not
exist, and it only fails when called. These checks are how that gets caught
before a user does.

> A stale assertion is worse than none: `df20_selfcheck()` spent weeks
> failing on a healthy database because `0056` added two arguments to
> `df20_apply_billing_event` and nobody updated the signature it asserted. A
> tripwire that is always tripped gets ignored.
