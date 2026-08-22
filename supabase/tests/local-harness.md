# Running the game engine without Supabase

Useful for testing the money rules and the full loop offline. It stands up a
throwaway Postgres, stubs the two Supabase-managed pieces the schema touches
(`auth.uid()` and `realtime.send()`), and puts PostgREST behind a tiny proxy
shaped like the Supabase REST edge.

Realtime and host auth do not work under the harness. That is deliberate: it
exercises the polling fallback in `lib/game/useRoom.ts`, which is what keeps a
draft correct when the websocket is unavailable.

```bash
brew install postgresql@17 postgrest
export PATH="/opt/homebrew/opt/postgresql@17/bin:$PATH" LC_ALL=C LANG=C

PGDIR=/tmp/df20pg SOCK=/tmp/df20sock
initdb -D "$PGDIR" -U postgres --auth=trust
mkdir -p "$SOCK"
pg_ctl -D "$PGDIR" -o "-p 55432 -k $SOCK -c listen_addresses=''" -l "$PGDIR/log" start
createdb -h "$SOCK" -p 55432 -U postgres df20
```

Then apply the stubs:

```sql
create role anon nologin;
create role authenticated nologin;

create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid());
create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;

create schema realtime;
create table realtime.sent (
  id bigserial primary key, payload jsonb, event text, topic text,
  private boolean, at timestamptz default now());
create function realtime.send(payload jsonb, event text, topic text, private boolean default true)
returns void language sql as $$ insert into realtime.sent(payload,event,topic,private)
                                values ($1,$2,$3,$4); $$;
```

Apply `migrations/0001`–`0004`, then run the suites:

```bash
psql "$DB" -f supabase/tests/full_draft.sql   # money rules, both draft shapes
./supabase/tests/race.sh "$DB"                # concurrency
```

To drive the browser against it, run PostgREST on 3001 with
`db-anon-role = "anon"` and put a proxy on 54321 that maps `/rest/v1/*` onto it
and strips the `Authorization` / `apikey` headers supabase-js sends.

Two players on one machine need two localStorage origins: run the host on
`http://localhost:3000` and the guest on `http://127.0.0.1:3000`. That is what
`allowedDevOrigins` in `next.config.ts` is for.
