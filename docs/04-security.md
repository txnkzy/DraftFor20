# 04 · Security

**Read this before touching any RPC, grant or policy.** Every entry below is
something that was actually exploitable in production, not a hypothetical.

---

## The threat model in one line

**The anon key is public and every RPC is reachable with `curl`.** A UI check
is a courtesy to honest users. The database is the only boundary.

---

## The four layers

1. **RLS** — deny-all, no anon policies, on every game table
2. **Grants** — `EXECUTE` revoked from `PUBLIC`, then granted explicitly to
   the ~69 real client RPCs
3. **SECURITY DEFINER functions** — the only read and write path, each
   authenticating its own caller
4. **Route handlers** — `lib/api/auth.ts`, deciding *who reaches an RPC*

Layer 4 is a convenience. Layers 1–3 are the security.

---

## `revoke … from anon, authenticated` on a FUNCTION does nothing

This is the single most important thing in this document.

Postgres grants `EXECUTE` to `PUBLIC` by default. `anon` and `authenticated`
are members of `PUBLIC`, so revoking from the roles removes a grant they
never held and **leaves the default in place**.

Every such revoke in this repo before `0048` was a no-op. **100 of 103 app
functions were callable with the publishable key**, including:

- `df20_reveal_next` — deals the next card
- `df20_add_to_roster` — writes a roster entry with no money check
- `df20_purge_old_rooms`

Proven with `curl`, not theorised.

```sql
-- WRONG — a no-op
revoke all on function public.f() from anon, authenticated;

-- RIGHT
revoke all on function public.f() from public, anon, authenticated;
grant  execute on function public.f() to anon, authenticated;  -- only if it IS a client RPC
```

`0048` revokes from `PUBLIC`; an explicit grant survives that.

**Tables are different** — tables have no default `PUBLIC` grant.

### The other half of that story

`0048` was right, and it **broke four things silently**, because this app's
own *server* routes also present the anon key and were not re-granted:
billing writes, the billing failure logger, signup signal recording, and
`df20_rate_limit` — which **fails open**, so every rate limit was disabled.

`0054` fixes it. **If you add a new secret-gated function the server calls
with the anon key, it needs an explicit grant to `anon`.**

---

## RLS is not a grant, and a table grant is not a column grant

`profiles` shipped with blanket `anon, authenticated` grants because it never
got the `revoke all` every game table got. RLS held `anon` shut — no policy
means deny — but `profiles_update_own` let a signed-in caller update **any
column** of their own row, and `premium_until` is on that row.

- One `PATCH /rest/v1/profiles?id=eq.<own uid>` bought permanent premium.
- Setting `stripe_customer_id` to a stranger's `cus_…` would have handed over
  their Stripe billing portal the day keys were added.

`0041` scoped the grants; `0042` removed the client's write entirely in
favour of `save_profile()`. `df20_grant_check()` asserts this and runs in the
bundle footer. **Add to it whenever you add a privileged column.**

### Why the write is an RPC now

PostgREST compiles `.upsert()` to `on conflict do update set id = excluded.id`,
so an upsert needs `UPDATE` on the **primary key**. That is what broke the
profile save the moment `0041` scoped the grants.

---

## The deck must never leak

`df20_public_state` touches `room_deck` only to `count(*)` unrevealed rows.
The Lineup mode inherits the rule: `lineup_cards` is revoked from both client
roles and `df20_selfcheck_lineups()` asserts it, because a readable cards
table *is* the entire mode, one PostgREST call away.

**The leak test is the important one** in `supabase/tests/v3_categories.sql`:
it plants a sentinel item and asserts it appears in no create response, no
`get_setup_state`, and no public snapshot until dealt.

---

## Token hygiene

`df20_public_state` returns `to_jsonb(rooms)` minus a **named list** of token
columns. Adding another token column to `rooms` without adding it to that
list hands it out to both players automatically.

Currently stripped: `setup_token`, `setup_result_token`, `obs_token`.

---

## Authorisation decisions that look like reads

`/api/billing/portal` opens a Stripe session for a customer id. Whatever it
treats as "the caller's customer id" **is an authorisation decision** — it
used to read that from a column the client could write, which would have
handed over a victim's invoices, billing address, card last-four and cancel
button. The column is now settable only by the signature-verified webhook.

The shape check (`/^cus_[A-Za-z0-9]{6,64}$/`) is the *second* lock, not the
first: it cannot tell whose id it is.

---

## `search_path` pinning

`create or replace function` **drops `proconfig`**, so it silently un-pins a
`search_path` set by an earlier `alter function`. `0042`'s pinning loop runs
at the very end of the migration *and* the bundle for this reason.

Always write `set search_path = public, pg_temp` in the function body itself.

---

## Admin

Admin is `profiles.is_admin`, with the old `df20_config.admin_user_ids` row
still honoured. `df20_is_admin()` accepts either, **deliberately**: if the
0028 backfill ever missed, the operator would be locked out of the very panel
that grants admin.

Revoking clears **both** sources, because a uuid left in the config row
silently re-grants on the next check.

---

## Rate limiting

`df20_rate_limit(bucket, subject, limit, window_seconds)` backs the
sensitive paths. **It fails open** — if the function is unreachable the limit
does not apply. That is a deliberate availability choice, and it is why the
`0048` grant regression silently disabled every limit for a period.

---

## Checklist for a new RPC

- [ ] `security definer` + `set search_path = public, pg_temp`
- [ ] Authenticates from a session token or `auth.uid()`, never a
      client-supplied id
- [ ] `select … for update` if it mutates room state
- [ ] `revoke all … from public, anon, authenticated` then an explicit
      `grant` if it is a client RPC
- [ ] Added to `df20_selfcheck()`
- [ ] If it touches a privileged column, added to `df20_grant_check()`
- [ ] Defined in a migration **registered in `build-bundle.sh`**
      (`lib/rpc-parity.test.ts` enforces this)
