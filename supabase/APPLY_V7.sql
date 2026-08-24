-- ═══════════════════════════════════════════════════════════════════════════
--  DraftFor20 v7 · ADDITIVE. Paste into the Supabase SQL Editor and Run.
--  Does NOT drop rooms. Safe to re-run. Ends with df20_selfcheck().
--
--  Built by supabase/build-bundle.sh — edit the migrations, not this file.
-- ═══════════════════════════════════════════════════════════════════════════


-- ─────────── 0008_hardening.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0008 · abuse control and brand uploads
-- ═══════════════════════════════════════════════════════════════════════════

-- ── fixed-window rate limiter ──────────────────────────────────────────────
-- Called from Next route handlers with the caller's IP. Returns true if the
-- request is allowed. A table rather than Redis because this has to work on
-- serverless with no extra infrastructure.
create or replace function public.df20_rate_limit(
  p_bucket text, p_subject text, p_limit int, p_window_seconds int
) returns boolean language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_start timestamptz; v_count int;
begin
  if p_window_seconds < 1 then p_window_seconds := 60; end if;
  v_start := to_timestamp(
    floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);

  insert into public.rate_limits (bucket, subject, window_start, count)
  values (left(p_bucket, 40), left(p_subject, 100), v_start, 1)
  on conflict (bucket, subject, window_start)
  do update set count = public.rate_limits.count + 1
  returning count into v_count;

  return v_count <= p_limit;
end $$;
grant execute on function public.df20_rate_limit(text, text, int, int) to anon, authenticated;

-- ── host brand logos ───────────────────────────────────────────────────────
-- 512KB cap, raster only. SVG is deliberately excluded: it can carry script
-- and this file gets rendered onto other people's shareable cards.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('brand', 'brand', true, 524288,
        array['image/png','image/jpeg','image/webp'])
on conflict (id) do update
  set public = true,
      file_size_limit = 524288,
      allowed_mime_types = array['image/png','image/jpeg','image/webp'];

-- a signed-in host may only write inside a folder named after their own uid
drop policy if exists brand_read   on storage.objects;
drop policy if exists brand_insert on storage.objects;
drop policy if exists brand_update on storage.objects;
drop policy if exists brand_delete on storage.objects;

create policy brand_read on storage.objects
  for select to anon, authenticated using (bucket_id = 'brand');

create policy brand_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'brand'
              and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy brand_update on storage.objects
  for update to authenticated
  using (bucket_id = 'brand'
         and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy brand_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'brand'
         and (storage.foldername(name))[1] = (select auth.uid())::text);

-- ── brand logo URLs must be https and must point at our own storage ───────
-- Anything else is a URL a stranger controls being rendered into someone
-- else's shareable card.
create or replace function public.df20_clean_logo_url(p_in text)
returns text language plpgsql immutable as $$
declare v text;
begin
  v := public.df20_clean_text(p_in, 500);
  if v = '' then return null; end if;
  if v !~ '^https://[A-Za-z0-9.-]+\.supabase\.co/storage/v1/object/public/brand/' then
    raise exception 'DF20_BAD_LOGO_URL';
  end if;
  return v;
end $$;

create or replace function public.create_room(
  p_title text, p_roster_size int, p_bankroll_cents int, p_min_bid_cents int,
  p_timer_seconds int, p_host_name text, p_is_private boolean default true,
  p_gives_per_player int default 2, p_brand_accent text default null,
  p_brand_logo_url text default null
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_pl public.players; v_uid uuid; v_pool int; v_accent text;
begin
  v_uid := auth.uid();

  p_title := public.df20_clean_text(p_title, 60);
  if length(p_title) = 0 then p_title := 'Football Draft'; end if;

  p_host_name := public.df20_clean_text(p_host_name, 24);
  if length(p_host_name) = 0 then raise exception 'DF20_BAD_NAME'; end if;

  if p_roster_size is null or p_roster_size < 1 or p_roster_size > 30
    then raise exception 'DF20_BAD_ROSTER_SIZE'; end if;
  if p_bankroll_cents is null or p_bankroll_cents < 0 or p_bankroll_cents > 10000000
    then raise exception 'DF20_BAD_BANKROLL'; end if;
  if p_min_bid_cents is null or p_min_bid_cents < 0 or p_min_bid_cents > 1000000
    then raise exception 'DF20_BAD_MIN_BID'; end if;
  if p_timer_seconds is null or p_timer_seconds < 3 or p_timer_seconds > 300
    then raise exception 'DF20_BAD_TIMER'; end if;
  if p_gives_per_player is null or p_gives_per_player < 0 or p_gives_per_player > 30
    then raise exception 'DF20_BAD_GIVES'; end if;

  -- accent must be a plain hex colour, never arbitrary CSS
  v_accent := public.df20_clean_text(p_brand_accent, 9);
  if v_accent = '' then v_accent := null; end if;
  if v_accent is not null and v_accent !~ '^#[0-9A-Fa-f]{6}$'
    then raise exception 'DF20_BAD_ACCENT'; end if;

  select count(*) into v_pool from public.nfl_players;
  if v_pool < p_roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;

  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, gives_per_player,
                            is_private, brand_accent, brand_logo_url, host_profile_id)
  values (public.df20_gen_code(), p_title, p_roster_size, p_bankroll_cents,
          p_min_bid_cents, p_timer_seconds, p_gives_per_player,
          coalesce(p_is_private, true), v_accent,
          public.df20_clean_logo_url(p_brand_logo_url), v_uid)
  returning * into v_room;

  insert into public.players (room_id, seat, display_name, bankroll_cents, is_host, profile_id)
  values (v_room.id, 1, p_host_name, p_bankroll_cents, true, v_uid)
  returning * into v_pl;

  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code,
                            'player_id', v_pl.id, 'session_token', v_pl.session_token,
                            'seat', 1);
end $$;
grant execute on function public.create_room(text, int, int, int, int, text, boolean, int, text, text) to anon, authenticated;

-- ─────────── 0009_categories.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0009 · custom categories
--
-- The pool stops being hard-coded NFL names. A room now carries its own
-- locked item list (room_pool), sourced from one of:
--   builtin/library  a reusable public entry in category_library
--   wikipedia        a parsed article cached in wikipedia_cache
--   manual           typed by a third-party setup host via a setup link
--
-- Football Draft is migrated into category_library and behaves identically.
-- Bidding, bankroll, the reserve rule and RLS are untouched.
-- ═══════════════════════════════════════════════════════════════════════════

create extension if not exists pg_trgm;

-- ── normalisation used by every fuzzy match ────────────────────────────────
-- lowercase, drop a leading "list of", strip punctuation, collapse whitespace
create or replace function public.df20_norm_category(p_in text)
returns text language sql immutable as $$
  select btrim(regexp_replace(
           regexp_replace(
             regexp_replace(lower(coalesce(p_in, '')), '^\s*list\s+of\s+', ''),
             '[^a-z0-9 ]+', ' ', 'g'),
           '\s+', ' ', 'g'))
$$;

-- ── the public, reusable library ───────────────────────────────────────────
create table if not exists public.category_library (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  name_norm  text not null,
  created_at timestamptz not null default now(),
  unique (name_norm)
);
create index if not exists category_library_trgm
  on public.category_library using gin (name_norm gin_trgm_ops);

create table if not exists public.category_library_items (
  library_id uuid not null references public.category_library(id) on delete cascade,
  name       text not null,
  primary key (library_id, name)
);

-- Repair after a partial earlier run. "drop table category_library cascade"
-- removes the foreign key but leaves this child table standing, so its rows
-- survive with no parent and nothing to cascade them away. They are invisible
-- to every query that joins through category_library, which makes them the
-- worst kind of leftover: harmless-looking and permanent.
delete from public.category_library_items i
 where not exists (select 1 from public.category_library l where l.id = i.library_id);

do $$
begin
  alter table public.category_library_items
    add constraint category_library_items_library_id_fkey
    foreign key (library_id) references public.category_library(id) on delete cascade;
exception when duplicate_object then null;
end $$;

-- ── internal cache of successful Wikipedia parses. NOT a user-facing
--    library: it exists purely to avoid hitting the API twice for the same
--    category. Public encyclopedia content, so no opt-in (see 0011 notes). ──
create table if not exists public.wikipedia_cache (
  id            uuid primary key default gen_random_uuid(),
  query_norm    text not null unique,
  article_title text not null,
  fetched_at    timestamptz not null default now()
);
create index if not exists wikipedia_cache_trgm
  on public.wikipedia_cache using gin (query_norm gin_trgm_ops);

create table if not exists public.wikipedia_cache_items (
  cache_id uuid not null references public.wikipedia_cache(id) on delete cascade,
  name     text not null,
  primary key (cache_id, name)
);

delete from public.wikipedia_cache_items i
 where not exists (select 1 from public.wikipedia_cache c where c.id = i.cache_id);

do $$
begin
  alter table public.wikipedia_cache_items
    add constraint wikipedia_cache_items_cache_id_fkey
    foreign key (cache_id) references public.wikipedia_cache(id) on delete cascade;
exception when duplicate_object then null;
end $$;

-- ── a room's locked item list. Copied in once, never sent to a client. ────
create table if not exists public.room_pool (
  room_id uuid not null references public.rooms(id) on delete cascade,
  name    text not null,
  primary key (room_id, name)
);

-- ── rooms: pool provenance and the setup-link lifecycle ───────────────────
alter table public.rooms
  add column if not exists category_name       text,
  add column if not exists pool_source         text,
  add column if not exists setup_token         uuid,
  add column if not exists setup_locked_at     timestamptz,
  add column if not exists setup_expires_at    timestamptz,
  add column if not exists setup_result_token  uuid,
  add column if not exists library_optin_state text not null default 'none';

do $$ begin
  alter table public.rooms add constraint rooms_pool_source_chk
    check (pool_source is null or pool_source in ('builtin','library','wikipedia','manual'));
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.rooms add constraint rooms_optin_chk
    check (library_optin_state in ('none','eligible','ineligible','accepted','declined'));
exception when duplicate_object then null; end $$;

-- a pending room has no code yet; the code appears when the list is locked in
alter table public.rooms alter column code drop not null;
create unique index if not exists rooms_setup_token_idx
  on public.rooms(setup_token) where setup_token is not null;
create unique index if not exists rooms_result_token_idx
  on public.rooms(setup_result_token) where setup_result_token is not null;

-- ── deck and rosters carry the item NAME, not a pool foreign key ──────────
alter table public.room_deck add column if not exists item_name text;

-- Backfill only while the old pool table is still around. On a re-run it has
-- already been dropped and there is nothing left to copy, so this whole block
-- has to be conditional rather than referencing a table that may be gone.
do $$
begin
  if to_regclass('public.nfl_players') is not null
     and exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'room_deck'
                    and column_name = 'nfl_player_id') then
    execute $q$
      update public.room_deck d set item_name = n.name
        from public.nfl_players n
       where n.id = d.nfl_player_id and d.item_name is null
    $q$;
  end if;
end $$;

delete from public.room_deck where item_name is null;

do $$
begin
  alter table public.room_deck alter column item_name set not null;
exception when others then null;   -- already not null
end $$;

do $$ begin
  alter table public.room_deck drop constraint room_deck_room_id_nfl_player_id_key;
exception when undefined_object then null; end $$;
alter table public.room_deck drop column if exists nfl_player_id;
do $$ begin
  alter table public.room_deck add constraint room_deck_room_item_key unique (room_id, item_name);
exception when duplicate_table then null; end $$;

do $$ begin
  alter table public.roster_entries drop constraint roster_entries_room_id_nfl_player_id_key;
exception when undefined_object then null; end $$;
alter table public.roster_entries drop column if exists nfl_player_id;
do $$ begin
  alter table public.roster_entries add constraint roster_entries_room_item_key unique (room_id, item_name);
exception when duplicate_table then null; end $$;

alter table public.lots drop column if exists nfl_player_id;

-- ── migrate the built-in pool into the library, then retire the table ─────
do $$
declare v_id uuid;
begin
  if to_regclass('public.nfl_players') is null then return; end if;

  insert into public.category_library (name, name_norm)
  values ('Football Draft', public.df20_norm_category('Football Draft'))
  on conflict (name_norm) do update set name = excluded.name
  returning id into v_id;

  if v_id is null then
    select id into v_id from public.category_library
     where name_norm = public.df20_norm_category('Football Draft');
  end if;

  insert into public.category_library_items (library_id, name)
  select v_id, n.name from public.nfl_players n
  on conflict do nothing;
end $$;

drop table if exists public.nfl_players cascade;

-- ── RLS: same deny-all posture as every other game table ──────────────────
alter table public.category_library       enable row level security;
alter table public.category_library_items enable row level security;
alter table public.wikipedia_cache        enable row level security;
alter table public.wikipedia_cache_items  enable row level security;
alter table public.room_pool              enable row level security;

revoke all on public.category_library       from anon, authenticated;
revoke all on public.category_library_items from anon, authenticated;
revoke all on public.wikipedia_cache        from anon, authenticated;
revoke all on public.wikipedia_cache_items  from anon, authenticated;
revoke all on public.room_pool              from anon, authenticated;

-- ─────────── 0010_category_rpc.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0010 · category resolution, setup links, library opt-in
--
-- INVARIANT THIS FILE EXISTS TO PROTECT:
--   no function here ever returns an item name to a caller.
--   Items go in (once, at lock-in or from a server-side source) and come out
--   only through df20_reveal_next, one card at a time, after being dealt.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── deck reads the name directly now; no pool join ────────────────────────
create or replace function public.df20_reveal_next(p_room uuid)
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_room public.rooms; v_p1 public.players; v_p2 public.players;
  v_o1 int; v_o2 int; v_opener public.players; v_card record; v_lot uuid;
begin
  select * into v_room from public.rooms where id = p_room;
  select * into v_p1 from public.players where room_id = p_room and seat = 1;
  select * into v_p2 from public.players where room_id = p_room and seat = 2;
  v_o1 := public.df20_open_slots(p_room, v_p1.id);
  v_o2 := public.df20_open_slots(p_room, v_p2.id);

  if v_o1 = 0 and v_o2 = 0 then
    update public.rooms
       set phase = 'complete', status = 'complete',
           completed_at = coalesce(completed_at, now())
     where id = p_room;
    return;
  end if;

  if v_o1 > 0 and v_o2 > 0 then
    v_opener := case when v_room.opener_seat = 1 then v_p1 else v_p2 end;
  elsif v_o1 > 0 then v_opener := v_p1;
  else                v_opener := v_p2;
  end if;

  select d.position as pos, d.item_name as nm into v_card
    from public.room_deck d
   where d.room_id = p_room and d.revealed_at is null
   order by d.position limit 1;

  if not found then
    update public.rooms
       set phase = 'complete', status = 'complete',
           completed_at = coalesce(completed_at, now())
     where id = p_room;
    return;
  end if;

  update public.room_deck set revealed_at = now()
   where room_id = p_room and position = v_card.pos;

  insert into public.lots
    (room_id, item_name, opener_player_id, status,
     current_bid_cents, high_bidder_player_id, on_the_clock_player_id,
     turn_expires_at, turn_seq)
  values
    (p_room, v_card.nm, v_opener.id, 'offered',
     v_room.min_bid_cents, v_opener.id, v_opener.id,
     now() + make_interval(secs => v_room.timer_seconds), 1)
  returning id into v_lot;

  insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
  values (p_room, v_lot, null, 'reveal', v_room.min_bid_cents, 1);

  update public.rooms set phase = 'offering' where id = p_room;
end $$;

-- ── fill a room's locked pool from whichever source produced it ───────────
create or replace function public.df20_fill_pool(
  p_room uuid, p_source text, p_ref uuid
) returns int language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_n int; v_name text;
begin
  if p_source in ('builtin','library') then
    if p_ref is null then
      select id into p_ref from public.category_library
       where name_norm = public.df20_norm_category('Football Draft');
    end if;
    select name into v_name from public.category_library where id = p_ref;
    if v_name is null then raise exception 'DF20_NO_SUCH_CATEGORY'; end if;
    insert into public.room_pool (room_id, name)
      select p_room, i.name from public.category_library_items i where i.library_id = p_ref
      on conflict do nothing;
  elsif p_source = 'wikipedia' then
    select article_title into v_name from public.wikipedia_cache where id = p_ref;
    if v_name is null then raise exception 'DF20_NO_SUCH_CATEGORY'; end if;
    insert into public.room_pool (room_id, name)
      select p_room, i.name from public.wikipedia_cache_items i where i.cache_id = p_ref
      on conflict do nothing;
  else
    raise exception 'DF20_BAD_POOL_SOURCE';
  end if;

  select count(*) into v_n from public.room_pool where room_id = p_room;
  update public.rooms
     set pool_source = p_source,
         category_name = coalesce(category_name, v_name)
   where id = p_room;
  return v_n;
end $$;

-- ── fuzzy match: public library first, then the Wikipedia cache ───────────
-- Returns provenance and a COUNT. Never an item.
-- 0.5 rather than pg_trgm's default 0.3: on two-to-four-word category names
-- 0.3 matches phrases that merely share a common word, and a wrong pool ruins
-- the draft rather than looking slightly off.
create or replace function public.df20_match_category(
  p_query text, p_min_items int default 0
) returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_q text; v_id uuid; v_name text; v_n int; v_score real;
begin
  v_q := public.df20_norm_category(p_query);
  if length(v_q) = 0 then return null; end if;

  -- 1. public library, exact then fuzzy
  select l.id, l.name, similarity(l.name_norm, v_q) into v_id, v_name, v_score
    from public.category_library l
   where l.name_norm = v_q or similarity(l.name_norm, v_q) >= 0.5
   order by (l.name_norm = v_q) desc, similarity(l.name_norm, v_q) desc
   limit 1;

  if v_id is not null then
    select count(*) into v_n from public.category_library_items where library_id = v_id;
    if v_n >= p_min_items then
      return jsonb_build_object('source','library','source_id',v_id,
                                'name',v_name,'item_count',v_n,
                                'score',round(coalesce(v_score,1)::numeric,3));
    end if;
  end if;

  -- 2. internal Wikipedia cache
  select c.id, c.article_title, similarity(c.query_norm, v_q) into v_id, v_name, v_score
    from public.wikipedia_cache c
   where c.query_norm = v_q or similarity(c.query_norm, v_q) >= 0.5
   order by (c.query_norm = v_q) desc, similarity(c.query_norm, v_q) desc
   limit 1;

  if v_id is not null then
    select count(*) into v_n from public.wikipedia_cache_items where cache_id = v_id;
    if v_n >= p_min_items then
      return jsonb_build_object('source','wikipedia','source_id',v_id,
                                'name',v_name,'item_count',v_n,
                                'score',round(coalesce(v_score,1)::numeric,3));
    end if;
  end if;

  return null;
end $$;

-- ── server-only configuration. RLS-denied, read only from inside
--    SECURITY DEFINER functions. ────────────────────────────────────────────
create table if not exists public.df20_config (
  key text primary key, value text not null
);
alter table public.df20_config enable row level security;
revoke all on public.df20_config from anon, authenticated;

-- Generated, never written down. This used to be a literal, which meant the
-- secret guarding the shared category cache was sitting in source control
-- for anyone who could read the repo. It is created once, on first apply,
-- and read out of the table when you need it:
--   select value from public.df20_config where key = 'wiki_write_secret';
insert into public.df20_config (key, value)
values ('wiki_write_secret', encode(gen_random_bytes(24), 'hex'))
on conflict (key) do nothing;

-- ── store a fresh Wikipedia parse.
--
-- Gated by a shared secret rather than left open, because this writes to a
-- cache every future room can draw from: an open endpoint here lets anyone
-- poison other people's drafts. Deliberately NOT the Supabase service-role
-- key — this secret can only write parsed categories, so leaking it costs a
-- cache flush rather than the whole database.
create or replace function public.df20_cache_wikipedia(
  p_secret text, p_query text, p_title text, p_items text[]
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_q text; v_id uuid; v_n int; s text; v_clean text; v_expected text;
begin
  select value into v_expected from public.df20_config where key = 'wiki_write_secret';
  if v_expected is null or p_secret is null or p_secret <> v_expected then
    raise exception 'DF20_NOT_AUTHORISED';
  end if;

  v_q := public.df20_norm_category(p_query);
  if length(v_q) = 0 then raise exception 'DF20_BAD_CATEGORY'; end if;

  insert into public.wikipedia_cache (query_norm, article_title)
  values (v_q, public.df20_clean_text(p_title, 120))
  on conflict (query_norm) do update set article_title = excluded.article_title,
                                         fetched_at = now()
  returning id into v_id;

  delete from public.wikipedia_cache_items where cache_id = v_id;
  foreach s in array coalesce(p_items, '{}'::text[]) loop
    v_clean := public.df20_clean_text(s, 60);
    if length(v_clean) >= 2 then
      insert into public.wikipedia_cache_items (cache_id, name)
      values (v_id, v_clean) on conflict do nothing;
    end if;
  end loop;

  select count(*) into v_n from public.wikipedia_cache_items where cache_id = v_id;
  return jsonb_build_object('source','wikipedia','source_id',v_id,
                            'name',p_title,'item_count',v_n);
end $$;

-- ── real-name heuristics, used only to DISQUALIFY a manual list from the
--    public library. Tuned to over-block: wrongly publishing someone's
--    friend group is far worse than wrongly withholding cereal brands. ─────
create or replace function public.df20_looks_like_person(p text)
returns boolean language sql immutable as $$
  select coalesce(p ~ '^[A-Z][a-z''\.\-]+( [A-Z][a-z''\.\-]+){1,2}$', false)
$$;

create or replace function public.df20_person_oriented_category(p text)
returns boolean language sql immutable as $$
  select coalesce(lower(coalesce(p,'')) ~
    '(friend|coworker|co-worker|colleague|classmate|family|cousin|roommate|
      teammate|group chat|tier list|people i|my |our )', false)
$$;

-- ── CREATE ROOM, now source-aware ─────────────────────────────────────────
-- Drop every earlier signature first. The new one adds two defaulted
-- arguments, so leaving an old overload in place makes any positional call
-- ambiguous rather than resolving to the newest definition.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'create_room'
  loop
    execute 'drop function if exists ' || r.sig || ' cascade';
  end loop;
end $$;

create or replace function public.create_room(
  p_title text, p_roster_size int, p_bankroll_cents int, p_min_bid_cents int,
  p_timer_seconds int, p_host_name text, p_is_private boolean default true,
  p_gives_per_player int default 2, p_brand_accent text default null,
  p_brand_logo_url text default null,
  p_pool_source text default 'builtin', p_pool_ref uuid default null
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_pl public.players; v_uid uuid; v_accent text; v_n int;
begin
  v_uid := auth.uid();

  p_title := public.df20_clean_text(p_title, 60);
  if length(p_title) = 0 then p_title := 'Football Draft'; end if;
  p_host_name := public.df20_clean_text(p_host_name, 24);
  if length(p_host_name) = 0 then raise exception 'DF20_BAD_NAME'; end if;

  if p_roster_size is null or p_roster_size < 1 or p_roster_size > 30
    then raise exception 'DF20_BAD_ROSTER_SIZE'; end if;
  if p_bankroll_cents is null or p_bankroll_cents < 0 or p_bankroll_cents > 10000000
    then raise exception 'DF20_BAD_BANKROLL'; end if;
  if p_min_bid_cents is null or p_min_bid_cents < 0 or p_min_bid_cents > 1000000
    then raise exception 'DF20_BAD_MIN_BID'; end if;
  if p_timer_seconds is null or p_timer_seconds < 3 or p_timer_seconds > 300
    then raise exception 'DF20_BAD_TIMER'; end if;
  if p_gives_per_player is null or p_gives_per_player < 0 or p_gives_per_player > 30
    then raise exception 'DF20_BAD_GIVES'; end if;

  v_accent := public.df20_clean_text(p_brand_accent, 9);
  if v_accent = '' then v_accent := null; end if;
  if v_accent is not null and v_accent !~ '^#[0-9A-Fa-f]{6}$'
    then raise exception 'DF20_BAD_ACCENT'; end if;

  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, gives_per_player,
                            is_private, brand_accent, brand_logo_url, host_profile_id)
  values (public.df20_gen_code(), p_title, p_roster_size, p_bankroll_cents,
          p_min_bid_cents, p_timer_seconds, p_gives_per_player,
          coalesce(p_is_private, true), v_accent,
          public.df20_clean_logo_url(p_brand_logo_url), v_uid)
  returning * into v_room;

  v_n := public.df20_fill_pool(v_room.id, coalesce(p_pool_source,'builtin'), p_pool_ref);
  if v_n < p_roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;

  insert into public.players (room_id, seat, display_name, bankroll_cents, is_host, profile_id)
  values (v_room.id, 1, p_host_name, p_bankroll_cents, true, v_uid)
  returning * into v_pl;

  -- provenance and a count. never an item.
  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code,
                            'player_id', v_pl.id, 'session_token', v_pl.session_token,
                            'seat', 1, 'pool_size', v_n);
end $$;

-- ── OPTION 1: a pending room that exists only as a setup link ─────────────
create or replace function public.create_pending_room()
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms;
begin
  -- placeholders; the setup host sets the real numbers at lock-in
  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, host_profile_id,
                            setup_token, setup_expires_at, pool_source)
  values (null, 'Untitled draft', 5, 2000, 100, 15, auth.uid(),
          gen_random_uuid(), now() + interval '24 hours', 'manual')
  returning * into v_room;

  return jsonb_build_object('setup_token', v_room.setup_token,
                            'expires_at', v_room.setup_expires_at);
end $$;

-- Config and status only. Deliberately never returns items, not even before
-- lock-in: the setup host already has their list in their own browser, so
-- there is no reason for the server to ever hand an item list to anybody.
create or replace function public.get_setup_state(p_setup_token uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms;
begin
  select * into v_room from public.rooms where setup_token = p_setup_token;
  if not found then return jsonb_build_object('status','gone'); end if;
  if v_room.setup_expires_at < now() then return jsonb_build_object('status','expired'); end if;
  return jsonb_build_object('status','open',
    'roster_size', v_room.roster_size,
    'bankroll_cents', v_room.starting_bankroll_cents,
    'min_bid_cents', v_room.min_bid_cents,
    'timer_seconds', v_room.timer_seconds,
    'gives_per_player', v_room.gives_per_player);
end $$;

-- ── LOCK-IN: the one and only write of a manual list ──────────────────────
create or replace function public.setup_lock_items(
  p_setup_token uuid, p_category text, p_items text[],
  p_roster_size int, p_bankroll_cents int, p_min_bid_cents int,
  p_timer_seconds int, p_gives_per_player int default 2
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; s text; v_clean text; v_n int; v_result uuid; v_code text;
begin
  select * into v_room from public.rooms where setup_token = p_setup_token for update;
  if not found then raise exception 'DF20_SETUP_LINK_SPENT'; end if;
  if v_room.setup_expires_at < now() then raise exception 'DF20_SETUP_LINK_EXPIRED'; end if;

  p_category := public.df20_clean_text(p_category, 60);
  if length(p_category) = 0 then raise exception 'DF20_BAD_CATEGORY'; end if;

  if p_roster_size is null or p_roster_size < 1 or p_roster_size > 30
    then raise exception 'DF20_BAD_ROSTER_SIZE'; end if;
  if p_bankroll_cents is null or p_bankroll_cents < 0 or p_bankroll_cents > 10000000
    then raise exception 'DF20_BAD_BANKROLL'; end if;
  if p_min_bid_cents is null or p_min_bid_cents < 0 or p_min_bid_cents > 1000000
    then raise exception 'DF20_BAD_MIN_BID'; end if;
  if p_timer_seconds is null or p_timer_seconds < 3 or p_timer_seconds > 300
    then raise exception 'DF20_BAD_TIMER'; end if;

  -- sanitise, length-check and de-duplicate case-insensitively
  foreach s in array coalesce(p_items, '{}'::text[]) loop
    v_clean := public.df20_clean_text(s, 60);
    if length(v_clean) >= 1 then
      if exists (select 1 from public.room_pool
                  where room_id = v_room.id and lower(name) = lower(v_clean)) then
        raise exception 'DF20_DUPLICATE_ITEM';
      end if;
      insert into public.room_pool (room_id, name) values (v_room.id, v_clean);
    end if;
  end loop;

  select count(*) into v_n from public.room_pool where room_id = v_room.id;
  if v_n < p_roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;
  if v_n > 500 then raise exception 'DF20_POOL_TOO_BIG'; end if;

  v_code   := public.df20_gen_code();
  v_result := gen_random_uuid();

  update public.rooms
     set code = v_code, title = p_category, category_name = p_category,
         roster_size = p_roster_size, starting_bankroll_cents = p_bankroll_cents,
         min_bid_cents = p_min_bid_cents, timer_seconds = p_timer_seconds,
         gives_per_player = coalesce(p_gives_per_player, 2),
         pool_source = 'manual',
         setup_locked_at = now(),
         setup_token = null,             -- the link is GONE, not read-only
         setup_result_token = v_result
   where id = v_room.id;

  return jsonb_build_object('code', v_code, 'item_count', v_n,
                            'setup_result_token', v_result);
end $$;

-- ── roster insert loses the pool foreign key ──────────────────────────────
create or replace function public.df20_add_to_roster(
  p_room uuid, p_player uuid, p_name text, p_price int, p_gifted boolean
) returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_pick int; v_bank int;
begin
  select coalesce(max(pick_number), 0) + 1 into v_pick
    from public.roster_entries where room_id = p_room and player_id = p_player;

  if p_price > 0 then
    update public.players set bankroll_cents = bankroll_cents - p_price
     where id = p_player returning bankroll_cents into v_bank;
    -- SAFETY NET. Unreachable if the Hard Cap and Reserve Rule held upstream.
    if v_bank < 0 then raise exception 'DF20_INVARIANT_NEGATIVE_BANKROLL'; end if;
  end if;

  insert into public.roster_entries
    (room_id, player_id, pick_number, item_name, price_cents, gifted)
  values (p_room, p_player, v_pick, p_name, p_price, p_gifted);
end $$;
drop function if exists public.df20_add_to_roster(uuid, uuid, int, text, int, boolean);

create or replace function public.df20_resolve_lot(p_lot uuid, p_action text)
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_lot public.lots;
begin
  select * into v_lot from public.lots where id = p_lot for update;
  if v_lot.status not in ('offered', 'bidding') then return; end if;

  perform public.df20_add_to_roster(
    v_lot.room_id, v_lot.high_bidder_player_id,
    v_lot.item_name, v_lot.current_bid_cents, false);

  update public.lots
     set status = 'resolved', winner_player_id = v_lot.high_bidder_player_id,
         final_price_cents = v_lot.current_bid_cents,
         on_the_clock_player_id = null, turn_expires_at = null, resolved_at = now()
   where id = p_lot;

  insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
  values (v_lot.room_id, p_lot, v_lot.high_bidder_player_id, p_action,
          v_lot.current_bid_cents, v_lot.turn_seq);

  perform public.df20_advance(v_lot.room_id);
end $$;

create or replace function public.df20_resolve_gift(p_lot uuid, p_giver uuid)
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_lot public.lots; v_to uuid;
begin
  select * into v_lot from public.lots where id = p_lot for update;
  if v_lot.status not in ('offered', 'bidding') then return; end if;

  v_to := public.df20_opponent(v_lot.room_id, p_giver);
  perform public.df20_add_to_roster(v_lot.room_id, v_to, v_lot.item_name, 0, true);

  update public.players set gives_used = gives_used + 1 where id = p_giver;

  update public.lots
     set status = 'resolved', winner_player_id = v_to, final_price_cents = 0,
         gifted = true, on_the_clock_player_id = null, turn_expires_at = null,
         resolved_at = now()
   where id = p_lot;

  insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
  values (v_lot.room_id, p_lot, p_giver, 'offer_give', 0, v_lot.turn_seq);

  perform public.df20_advance(v_lot.room_id);
end $$;

-- ── the deck is now drawn from the room's own locked pool ─────────────────
create or replace function public.start_draft(p_code text, p_token uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_me public.players; v_n int; v_pool int; v_size int;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  select * into v_me from public.players
   where room_id = v_room.id and session_token = p_token;
  if not found then raise exception 'DF20_BAD_TOKEN'; end if;
  if not v_me.is_host then raise exception 'DF20_HOST_ONLY'; end if;
  if v_room.status <> 'lobby' then raise exception 'DF20_ALREADY_STARTED'; end if;

  select count(*) into v_n from public.players where room_id = v_room.id;
  if v_n <> 2 then raise exception 'DF20_NEED_TWO_PLAYERS'; end if;

  -- A room draws a small random SUBSET of its pool, sized to the game, so
  -- scarcity is real and the deck differs every draft.
  select count(*) into v_pool from public.room_pool where room_id = v_room.id;
  if v_pool < v_room.roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;
  v_size := least(greatest(v_room.roster_size * 6, v_room.roster_size * 2 + 4), v_pool);

  insert into public.room_deck (room_id, position, item_name)
  select v_room.id, row_number() over (order by s.r), s.name
    from (select name, random() as r from public.room_pool
           where room_id = v_room.id order by random() limit v_size) s;

  update public.rooms set status = 'live', started_at = now() where id = v_room.id;
  perform public.df20_reveal_next(v_room.id);
  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);
  return public.df20_public_state(v_room.id);
end $$;

-- ── join takes the lowest free seat, because an Option 1 room has no host
--    player until someone arrives ─────────────────────────────────────────
create or replace function public.join_room(p_code text, p_display_name text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_pl public.players; v_n int; v_seat int; v_host boolean;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  if v_room.status <> 'lobby' then raise exception 'DF20_ALREADY_STARTED'; end if;

  p_display_name := public.df20_clean_text(p_display_name, 24);
  if length(p_display_name) = 0 then raise exception 'DF20_BAD_NAME'; end if;

  select count(*) into v_n from public.players where room_id = v_room.id;
  if v_n >= 2 then raise exception 'DF20_ROOM_FULL'; end if;

  select min(s) into v_seat from generate_series(1,2) s
   where not exists (select 1 from public.players
                      where room_id = v_room.id and seat = s);

  v_host := not exists (select 1 from public.players
                         where room_id = v_room.id and is_host);

  insert into public.players (room_id, seat, display_name, bankroll_cents, is_host)
  values (v_room.id, v_seat, p_display_name, v_room.starting_bankroll_cents, v_host)
  returning * into v_pl;

  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);
  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code,
                            'player_id', v_pl.id, 'session_token', v_pl.session_token,
                            'seat', v_pl.seat);
end $$;

-- ── OPT-IN: offered only to an Option 1 setup host, only after the draft,
--    only when nothing in the list looks like a real person ───────────────
create or replace function public.offer_library_optin(p_result_token uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_n int; v_people int; v_state text;
begin
  select * into v_room from public.rooms where setup_result_token = p_result_token;
  if not found then return jsonb_build_object('status','gone'); end if;
  if v_room.status <> 'complete' then return jsonb_build_object('status','not_finished'); end if;
  if v_room.library_optin_state in ('accepted','declined','ineligible') then
    return jsonb_build_object('status', v_room.library_optin_state);
  end if;
  if v_room.pool_source <> 'manual' then
    return jsonb_build_object('status','ineligible');
  end if;

  select count(*) into v_n from public.room_pool where room_id = v_room.id;
  select count(*) into v_people from public.room_pool
   where room_id = v_room.id and public.df20_looks_like_person(name);

  if public.df20_person_oriented_category(v_room.category_name)
     or (v_n > 0 and v_people::numeric / v_n > 0.30) then
    update public.rooms set library_optin_state = 'ineligible' where id = v_room.id;
    return jsonb_build_object('status','ineligible');
  end if;

  update public.rooms set library_optin_state = 'eligible' where id = v_room.id;
  return jsonb_build_object('status','eligible',
                            'category_name', v_room.category_name,
                            'item_count', v_n);
end $$;

create or replace function public.submit_library_optin(
  p_result_token uuid, p_accept boolean
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_id uuid; v_check jsonb;
begin
  select * into v_room from public.rooms where setup_result_token = p_result_token;
  if not found then raise exception 'DF20_NO_ROOM'; end if;

  if not coalesce(p_accept, false) then
    update public.rooms set library_optin_state = 'declined' where id = v_room.id;
    return jsonb_build_object('status','declined');
  end if;

  -- re-run eligibility at submit time; never trust the earlier answer
  v_check := public.offer_library_optin(p_result_token);
  if v_check->>'status' <> 'eligible' then
    return jsonb_build_object('status', v_check->>'status');
  end if;

  insert into public.category_library (name, name_norm)
  values (v_room.category_name, public.df20_norm_category(v_room.category_name))
  on conflict (name_norm) do nothing
  returning id into v_id;
  if v_id is null then
    return jsonb_build_object('status','already_exists');
  end if;

  -- name and items only. no room, no player, no timing.
  insert into public.category_library_items (library_id, name)
  select v_id, name from public.room_pool where room_id = v_room.id
  on conflict do nothing;

  update public.rooms set library_optin_state = 'accepted' where id = v_room.id;
  return jsonb_build_object('status','accepted');
end $$;

-- ── grants. Internal helpers stay ungranted. ──────────────────────────────
grant execute on function public.create_room(text,int,int,int,int,text,boolean,int,text,text,text,uuid) to anon, authenticated;
grant execute on function public.create_pending_room()                    to anon, authenticated;
grant execute on function public.get_setup_state(uuid)                    to anon, authenticated;
grant execute on function public.setup_lock_items(uuid,text,text[],int,int,int,int,int) to anon, authenticated;
grant execute on function public.join_room(text, text)                    to anon, authenticated;
grant execute on function public.start_draft(text, uuid)                  to anon, authenticated;
grant execute on function public.offer_library_optin(uuid)                to anon, authenticated;
grant execute on function public.submit_library_optin(uuid, boolean)      to anon, authenticated;

-- matching returns provenance and a count, never an item, so it is safe to
-- expose; caching gates on the secret above rather than on the grant
grant  execute on function public.df20_match_category(text, int)          to anon, authenticated;
grant  execute on function public.df20_cache_wikipedia(text,text,text,text[]) to anon, authenticated;
revoke all on function public.df20_fill_pool(uuid, text, uuid)            from anon, authenticated;
revoke all on function public.df20_add_to_roster(uuid, uuid, text, int, boolean) from anon, authenticated;

-- ─────────── 0011_library_seed.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0011 · shared library seed
--
-- Real, factual lists of public things. Curated for PLAY, not for reference:
-- they are chosen to be recognisable and arguable, and none of them claims to
-- be exhaustive. A draft only needs enough good options that passing on one
-- hurts.
--
-- Edit freely. Re-running is safe; each category upserts by normalised name.
-- ═══════════════════════════════════════════════════════════════════════════

-- the loader
create or replace function public.df20_seed_category(p_name text, p_items text[])
returns int language plpgsql security definer
set search_path = public, pg_temp as $fn$
declare v_id uuid; s text; v_clean text; v_n int;
begin
  insert into public.category_library (name, name_norm)
  values (p_name, public.df20_norm_category(p_name))
  on conflict (name_norm) do update set name = excluded.name
  returning id into v_id;

  foreach s in array p_items loop
    v_clean := public.df20_clean_text(s, 60);
    if length(v_clean) >= 1 then
      insert into public.category_library_items (library_id, name)
      values (v_id, v_clean) on conflict do nothing;
    end if;
  end loop;

  select count(*) into v_n from public.category_library_items where library_id = v_id;
  return v_n;
end $fn$;
revoke all on function public.df20_seed_category(text, text[]) from anon, authenticated;

-- Football Draft · 268 items
-- Seeded explicitly rather than relying on the nfl_players migration in
-- 0009: if that table was already dropped by an earlier partial run, the
-- built-in pool would otherwise be gone for good and every default room
-- would fail with DF20_POOL_TOO_SMALL.
select public.df20_seed_category('Football Draft', string_to_array($ff$Patrick Mahomes
Josh Allen
Lamar Jackson
Joe Burrow
Jalen Hurts
Justin Herbert
C.J. Stroud
Jayden Daniels
Caleb Williams
Bo Nix
Dak Prescott
Tua Tagovailoa
Trevor Lawrence
Kyler Murray
Brock Purdy
Jared Goff
Matthew Stafford
Baker Mayfield
Geno Smith
Kirk Cousins
Aaron Rodgers
Russell Wilson
Derek Carr
Sam Darnold
Anthony Richardson
Will Levis
Drake Maye
Michael Penix Jr.
J.J. McCarthy
Bryce Young
Daniel Jones
Justin Fields
Gardner Minshew
Jacoby Brissett
Mac Jones
Aidan O'Connell
Jimmy Garoppolo
Andy Dalton
Cooper Rush
Malik Willis
Christian McCaffrey
Saquon Barkley
Bijan Robinson
Jahmyr Gibbs
Jonathan Taylor
Derrick Henry
Josh Jacobs
Kyren Williams
Breece Hall
De'Von Achane
Kenneth Walker III
Rachaad White
Travis Etienne Jr.
James Cook
Alvin Kamara
Joe Mixon
Aaron Jones
Najee Harris
David Montgomery
Isiah Pacheco
Tony Pollard
Rhamondre Stevenson
Zamir White
Javonte Williams
D'Andre Swift
Chuba Hubbard
Brian Robinson Jr.
Zack Moss
Tyjae Spears
Jaylen Warren
Austin Ekeler
Nick Chubb
J.K. Dobbins
Gus Edwards
Ezekiel Elliott
Raheem Mostert
Jerome Ford
Devin Singletary
Antonio Gibson
Roschon Johnson
Blake Corum
Jonathon Brooks
Trey Benson
MarShawn Lloyd
Ray Davis
Bucky Irving
Jaylen Wright
Braelon Allen
Isaac Guerendo
Audric Estime
Tyrone Tracy Jr.
Kimani Vidal
Justin Jefferson
Ja'Marr Chase
CeeDee Lamb
Tyreek Hill
A.J. Brown
Amon-Ra St. Brown
Puka Nacua
Garrett Wilson
Chris Olave
Drake London
DK Metcalf
Mike Evans
Davante Adams
Stefon Diggs
Deebo Samuel
Brandon Aiyuk
Nico Collins
Tee Higgins
DeVonta Smith
Terry McLaurin
Jaylen Waddle
Marvin Harrison Jr.
Malik Nabers
Rome Odunze
Brian Thomas Jr.
Ladd McConkey
Xavier Worthy
Keon Coleman
Ricky Pearsall
Adonai Mitchell
Xavier Legette
Jayden Reed
Zay Flowers
Jordan Addison
Rashee Rice
Christian Watson
George Pickens
Michael Pittman Jr.
Courtland Sutton
Jerry Jeudy
Amari Cooper
Keenan Allen
Cooper Kupp
Calvin Ridley
Diontae Johnson
Tyler Lockett
Jakobi Meyers
Darnell Mooney
Curtis Samuel
Tank Dell
Josh Downs
Wan'Dale Robinson
Khalil Shakir
Rashid Shaheed
Jalen McMillan
Jermaine Burton
Troy Franklin
Malachi Corley
Luke McCaffrey
Roman Wilson
Ja'Lynn Polk
Devontez Walker
Brenden Rice
Jalen Coker
Travis Kelce
Sam LaPorta
Mark Andrews
T.J. Hockenson
George Kittle
Trey McBride
Evan Engram
Dalton Kincaid
Kyle Pitts
David Njoku
Jake Ferguson
Cole Kmet
Pat Freiermuth
Dallas Goedert
Hunter Henry
Tyler Higbee
Isaiah Likely
Brock Bowers
Ben Sinnott
Ja'Tavion Sanders
Cade Otton
Tucker Kraft
Luke Musgrave
Michael Mayer
Zach Ertz
Noah Fant
Juwan Johnson
Chigoziem Okonkwo
Myles Garrett
Micah Parsons
T.J. Watt
Nick Bosa
Maxx Crosby
Aidan Hutchinson
Will Anderson Jr.
Danielle Hunter
Trey Hendrickson
Brian Burns
Montez Sweat
Rashan Gary
Chris Jones
Dexter Lawrence
Quinnen Williams
Jeffery Simmons
Vita Vea
Cameron Heyward
Fred Warner
Roquan Smith
Bobby Wagner
Lavonte David
Zack Baun
Jordyn Brooks
Devin White
Patrick Queen
Derwin James
Minkah Fitzpatrick
Kyle Hamilton
Antoine Winfield Jr.
Budda Baker
Jessie Bates III
Talanoa Hufanga
Sauce Gardner
Patrick Surtain II
Jalen Ramsey
Marlon Humphrey
Trent McDuffie
Devon Witherspoon
Christian Gonzalez
Charvarius Ward
Denzel Ward
Jaycee Horn
Riq Woolen
Cooper DeJean
Quinyon Mitchell
Terrion Arnold
Nate Wiggins
Jared Verse
Laiatu Latu
Dallas Turner
Byron Murphy II
Chop Robinson
Edgerrin Cooper
Payton Wilson
Justin Tucker
Harrison Butker
Brandon Aubrey
Jake Elliott
Younghoe Koo
Tyler Bass
Jason Sanders
Cameron Dicker
Chris Boswell
Ka'imi Fairbairn
Trent Williams
Penei Sewell
Lane Johnson
Tristan Wirfs
Laremy Tunsil
Christian Darrisaw
Rashawn Slater
Quenton Nelson
Zack Martin
Creed Humphrey
Frank Ragnow
Joe Thuney
Landon Dickerson
Chris Lindstrom
Tyler Smith
Joe Alt
Olu Fashanu
JC Latham
Amarius Mims$ff$, E'\n'));

-- NFL Teams · 32 items
select public.df20_seed_category('NFL Teams', string_to_array($items$Arizona Cardinals
Atlanta Falcons
Baltimore Ravens
Buffalo Bills
Carolina Panthers
Chicago Bears
Cincinnati Bengals
Cleveland Browns
Dallas Cowboys
Denver Broncos
Detroit Lions
Green Bay Packers
Houston Texans
Indianapolis Colts
Jacksonville Jaguars
Kansas City Chiefs
Las Vegas Raiders
Los Angeles Chargers
Los Angeles Rams
Miami Dolphins
Minnesota Vikings
New England Patriots
New Orleans Saints
New York Giants
New York Jets
Philadelphia Eagles
Pittsburgh Steelers
San Francisco 49ers
Seattle Seahawks
Tampa Bay Buccaneers
Tennessee Titans
Washington Commanders$items$, E'\n'));

-- NBA Teams · 30 items
select public.df20_seed_category('NBA Teams', string_to_array($items$Atlanta Hawks
Boston Celtics
Brooklyn Nets
Charlotte Hornets
Chicago Bulls
Cleveland Cavaliers
Dallas Mavericks
Denver Nuggets
Detroit Pistons
Golden State Warriors
Houston Rockets
Indiana Pacers
LA Clippers
Los Angeles Lakers
Memphis Grizzlies
Miami Heat
Milwaukee Bucks
Minnesota Timberwolves
New Orleans Pelicans
New York Knicks
Oklahoma City Thunder
Orlando Magic
Philadelphia 76ers
Phoenix Suns
Portland Trail Blazers
Sacramento Kings
San Antonio Spurs
Toronto Raptors
Utah Jazz
Washington Wizards$items$, E'\n'));

-- MLB Teams · 30 items
select public.df20_seed_category('MLB Teams', string_to_array($items$Arizona Diamondbacks
Athletics
Atlanta Braves
Baltimore Orioles
Boston Red Sox
Chicago Cubs
Chicago White Sox
Cincinnati Reds
Cleveland Guardians
Colorado Rockies
Detroit Tigers
Houston Astros
Kansas City Royals
Los Angeles Angels
Los Angeles Dodgers
Miami Marlins
Milwaukee Brewers
Minnesota Twins
New York Mets
New York Yankees
Philadelphia Phillies
Pittsburgh Pirates
San Diego Padres
San Francisco Giants
Seattle Mariners
St. Louis Cardinals
Tampa Bay Rays
Texas Rangers
Toronto Blue Jays
Washington Nationals$items$, E'\n'));

-- US States · 50 items
select public.df20_seed_category('US States', string_to_array($items$Alabama
Alaska
Arizona
Arkansas
California
Colorado
Connecticut
Delaware
Florida
Georgia
Hawaii
Idaho
Illinois
Indiana
Iowa
Kansas
Kentucky
Louisiana
Maine
Maryland
Massachusetts
Michigan
Minnesota
Mississippi
Missouri
Montana
Nebraska
Nevada
New Hampshire
New Jersey
New Mexico
New York
North Carolina
North Dakota
Ohio
Oklahoma
Oregon
Pennsylvania
Rhode Island
South Carolina
South Dakota
Tennessee
Texas
Utah
Vermont
Virginia
Washington
West Virginia
Wisconsin
Wyoming$items$, E'\n'));

-- Breakfast Cereals · 50 items
select public.df20_seed_category('Breakfast Cereals', string_to_array($items$Lucky Charms
Cheerios
Honey Nut Cheerios
Frosted Flakes
Froot Loops
Cinnamon Toast Crunch
Rice Krispies
Corn Flakes
Raisin Bran
Special K
Cocoa Puffs
Trix
Apple Jacks
Cap'n Crunch
Crunch Berries
Golden Grahams
Cookie Crisp
Reese's Puffs
Honey Bunches of Oats
Frosted Mini-Wheats
Life
Kix
Wheaties
Grape-Nuts
Shredded Wheat
Corn Chex
Rice Chex
Honeycomb
Fruity Pebbles
Cocoa Pebbles
Alpha-Bits
Count Chocula
Franken Berry
Boo Berry
Corn Pops
Honey Smacks
Krave
Raisin Nut Bran
Total
Oatmeal Crisp
Puffins
Cracklin' Oat Bran
Mueslix
Basic 4
French Toast Crunch
Waffle Crisp
Frosted Cheerios
Multi Grain Cheerios
Peanut Butter Crunch
Golden Crisp$items$, E'\n'));

-- Fast Food Chains · 50 items
select public.df20_seed_category('Fast Food Chains', string_to_array($items$McDonald's
Burger King
Wendy's
Taco Bell
KFC
Subway
Chick-fil-A
Popeyes
Chipotle
Five Guys
Shake Shack
In-N-Out Burger
Whataburger
Culver's
Sonic Drive-In
Jack in the Box
Arby's
Dairy Queen
Hardee's
Carl's Jr.
White Castle
Raising Cane's
Zaxby's
Bojangles
Church's Chicken
Del Taco
Qdoba
Moe's Southwest Grill
Panera Bread
Panda Express
Jimmy John's
Jersey Mike's
Firehouse Subs
Potbelly
Quiznos
Domino's
Pizza Hut
Papa John's
Little Caesars
Wingstop
Buffalo Wild Wings
Dunkin'
Starbucks
Tim Hortons
Krispy Kreme
Auntie Anne's
Cinnabon
Checkers
Steak 'n Shake
Portillo's$items$, E'\n'));

-- Candy and Sweets · 50 items
select public.df20_seed_category('Candy and Sweets', string_to_array($items$Snickers
Milky Way
Twix
3 Musketeers
Butterfinger
Baby Ruth
Reese's Peanut Butter Cups
Kit Kat
Hershey's Milk Chocolate
Cookies 'n' Creme
Almond Joy
Mounds
Payday
100 Grand
Take 5
Whatchamacallit
Mr. Goodbar
Krackel
Heath Bar
Skor
Toblerone
Nestle Crunch
Charleston Chew
Zagnut
Bit-O-Honey
Oh Henry!
Rolo
Twizzlers
Milk Duds
Whoppers
Junior Mints
Raisinets
Goobers
Sno-Caps
Dots
Airheads
Starburst
Skittles
Sour Patch Kids
Swedish Fish
Nerds
Laffy Taffy
Jolly Rancher
Tootsie Roll
Gobstopper
Runts
Now and Later
Mike and Ike
Warheads
Ring Pop$items$, E'\n'));

-- Pizza Toppings · 40 items
select public.df20_seed_category('Pizza Toppings', string_to_array($items$Pepperoni
Italian Sausage
Mushrooms
Onions
Green Peppers
Black Olives
Bacon
Ham
Pineapple
Extra Cheese
Spinach
Fresh Tomatoes
Jalapenos
Roasted Garlic
Fresh Basil
Anchovies
Grilled Chicken
Ground Beef
Salami
Prosciutto
Artichoke Hearts
Sun-Dried Tomatoes
Red Onion
Banana Peppers
Ricotta
Feta
Goat Cheese
Blue Cheese
Broccoli
Zucchini
Eggplant
Arugula
Pesto
BBQ Sauce
Buffalo Sauce
Meatballs
Chorizo
Sweet Corn
Fried Egg
Truffle Oil$items$, E'\n'));

-- Ice Cream Flavors · 40 items
select public.df20_seed_category('Ice Cream Flavors', string_to_array($items$Vanilla
Chocolate
Strawberry
Mint Chocolate Chip
Cookies and Cream
Rocky Road
Butter Pecan
Neapolitan
Cookie Dough
Pistachio
Coffee
Salted Caramel
Chocolate Chip
Moose Tracks
Birthday Cake
Peanut Butter Cup
Mango
Coconut
Lemon Sorbet
Raspberry Ripple
Rum Raisin
Black Raspberry
Maple Walnut
Praline
Cheesecake
Tiramisu
Green Tea
Cotton Candy
Superman
Bubblegum
Banana
Peach
Pumpkin
Eggnog
Spumoni
Cannoli
S'mores
Caramel Swirl
Butterscotch
Blackberry$items$, E'\n'));

-- Soft Drinks · 40 items
select public.df20_seed_category('Soft Drinks', string_to_array($items$Coca-Cola
Diet Coke
Coke Zero
Pepsi
Diet Pepsi
Dr Pepper
Sprite
7 Up
Mountain Dew
Fanta Orange
Fanta Grape
Sunkist
Orange Crush
A&W Root Beer
Barq's
Mug Root Beer
Canada Dry Ginger Ale
Schweppes
Squirt
Fresca
Mello Yello
Big Red
Cheerwine
Moxie
Jarritos
Inca Kola
Irn-Bru
Vernors
Faygo
Shasta
RC Cola
Cherry Coke
Vanilla Coke
Diet Dr Pepper
Code Red
Wild Cherry Pepsi
Sprite Zero
Ginger Beer
Cream Soda
Root Beer Float$items$, E'\n'));

-- Dog Breeds · 50 items
select public.df20_seed_category('Dog Breeds', string_to_array($items$Labrador Retriever
Golden Retriever
German Shepherd
French Bulldog
Bulldog
Poodle
Beagle
Rottweiler
Dachshund
Yorkshire Terrier
Boxer
Siberian Husky
Great Dane
Doberman Pinscher
Australian Shepherd
Border Collie
Shih Tzu
Pomeranian
Chihuahua
Pug
Cocker Spaniel
Boston Terrier
Bernese Mountain Dog
Cavalier King Charles Spaniel
Shiba Inu
Corgi
Basset Hound
Bloodhound
Saint Bernard
Newfoundland
Mastiff
Weimaraner
Vizsla
Whippet
Greyhound
Jack Russell Terrier
Scottish Terrier
West Highland White Terrier
Samoyed
Akita
Alaskan Malamute
Papillon
Maltese
Bichon Frise
Havanese
Schnauzer
Airedale Terrier
Irish Setter
Springer Spaniel
Australian Cattle Dog$items$, E'\n'));

-- Board Games · 50 items
select public.df20_seed_category('Board Games', string_to_array($items$Monopoly
Scrabble
Risk
Clue
Catan
Ticket to Ride
Carcassonne
Pandemic
Chess
Checkers
Backgammon
Go
Battleship
Connect Four
Sorry!
Trouble
The Game of Life
Candy Land
Chutes and Ladders
Operation
Guess Who?
Yahtzee
Boggle
Trivial Pursuit
Balderdash
Taboo
Pictionary
Cranium
Codenames
Dixit
Azul
Wingspan
Splendor
7 Wonders
Dominion
Agricola
Terraforming Mars
Scythe
Gloomhaven
Betrayal at House on the Hill
Munchkin
Exploding Kittens
Uno
Skip-Bo
Phase 10
Jenga
Twister
Mancala
Stratego
Axis and Allies$items$, E'\n'));

-- Video Game Franchises · 50 items
select public.df20_seed_category('Video Game Franchises', string_to_array($items$Super Mario
The Legend of Zelda
Pokemon
Call of Duty
Grand Theft Auto
Minecraft
FIFA
Madden NFL
Halo
Final Fantasy
Resident Evil
Street Fighter
Mortal Kombat
Tekken
Sonic the Hedgehog
Metal Gear
Assassin's Creed
Far Cry
Battlefield
Doom
The Elder Scrolls
Fallout
Diablo
StarCraft
Warcraft
Overwatch
Counter-Strike
Half-Life
Portal
Left 4 Dead
BioShock
Dark Souls
Elden Ring
Monster Hunter
Animal Crossing
Kirby
Metroid
Donkey Kong
Splatoon
Fire Emblem
Civilization
SimCity
The Sims
Tomb Raider
Uncharted
God of War
The Last of Us
Gran Turismo
Forza
Need for Speed$items$, E'\n'));

-- Superheroes · 50 items
select public.df20_seed_category('Superheroes', string_to_array($items$Superman
Batman
Spider-Man
Iron Man
Captain America
Thor
Hulk
Black Widow
Hawkeye
Wonder Woman
The Flash
Aquaman
Green Lantern
Cyborg
Doctor Strange
Black Panther
Ant-Man
Wasp
Captain Marvel
Scarlet Witch
Vision
Falcon
Winter Soldier
Star-Lord
Gamora
Drax
Rocket Raccoon
Groot
Wolverine
Cyclops
Storm
Jean Grey
Professor X
Beast
Nightcrawler
Rogue
Gambit
Deadpool
Daredevil
Punisher
Jessica Jones
Luke Cage
Iron Fist
Ghost Rider
Silver Surfer
Mister Fantastic
Invisible Woman
Human Torch
The Thing
Nova$items$, E'\n'));

-- Chip Flavors · 30 items
select public.df20_seed_category('Chip Flavors', string_to_array($items$Original
Barbecue
Sour Cream and Onion
Salt and Vinegar
Cheddar and Sour Cream
Jalapeno
Dill Pickle
Honey Barbecue
Flamin' Hot
Nacho Cheese
Cool Ranch
Spicy Sweet Chili
Ranch
Buffalo
Ketchup
All Dressed
Prawn Cocktail
Cheese and Onion
Roast Chicken
Smoky Bacon
Sea Salt
Cracked Black Pepper
Chili Lime
Wasabi
Truffle
Garlic Parmesan
Everything Bagel
Pizza
Taco
Sweet Onion$items$, E'\n'));

do $$
declare v_c int; v_i int;
begin
  select count(*) into v_c from public.category_library;
  select count(*) into v_i from public.category_library_items;
  raise notice 'library now holds % categories and % items', v_c, v_i;
end $$;
-- ─────────── 0012_match_tightening.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0012 · stop acronym collisions, and accept how people type
--
-- Trigram similarity alone matched "nhl teams" to NFL Teams at 0.538 and
-- "wnba teams" to NBA Teams at 0.615, because the shared word "teams" is most
-- of a short string and the acronym that actually carries the meaning is only
-- three characters. Similarity is necessary but not sufficient.
--
-- Meanwhile the opposite problem: people type "soda", not "Soft Drinks".
-- ═══════════════════════════════════════════════════════════════════════════

-- ── two names must share a MEANINGFUL word, not just a generic one ────────
create or replace function public.df20_token_overlap(a text, b text)
returns boolean language sql immutable as $$
  select exists (
    select 1
      from unnest(string_to_array(a, ' ')) ta
      join unnest(string_to_array(b, ' ')) tb
        on ta = tb
        -- prefix match so cereal/cereals and game/games count, but never
        -- short acronyms: nfl and nba must not be allowed to blur together
        or (length(ta) >= 4 and length(tb) >= 4
            and (ta like tb || '%' or tb like ta || '%'))
     where ta not in ('teams','team','list','of','the','and','a','an','all',
                      'best','top','my','our','favorite','favourite','greatest')
       and tb not in ('teams','team','list','of','the','and','a','an','all',
                      'best','top','my','our','favorite','favourite','greatest')
  )
$$;

-- ── the words people actually type ────────────────────────────────────────
create table if not exists public.category_library_aliases (
  library_id uuid not null references public.category_library(id) on delete cascade,
  alias_norm text not null,
  primary key (library_id, alias_norm)
);
create index if not exists category_alias_trgm
  on public.category_library_aliases using gin (alias_norm gin_trgm_ops);
alter table public.category_library_aliases enable row level security;
revoke all on public.category_library_aliases from anon, authenticated;

create or replace function public.df20_add_alias(p_category text, p_aliases text[])
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_id uuid; s text;
begin
  select id into v_id from public.category_library
   where name_norm = public.df20_norm_category(p_category);
  if v_id is null then return; end if;
  foreach s in array p_aliases loop
    insert into public.category_library_aliases (library_id, alias_norm)
    values (v_id, public.df20_norm_category(s))
    on conflict do nothing;
  end loop;
end $$;
revoke all on function public.df20_add_alias(text, text[]) from anon, authenticated;

-- ── matching: name or alias, similarity AND a shared meaningful word ──────
create or replace function public.df20_match_category(
  p_query text, p_min_items int default 0
) returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_q text; v_id uuid; v_name text; v_n int; v_score real;
begin
  v_q := public.df20_norm_category(p_query);
  if length(v_q) = 0 then return null; end if;

  -- 1. public library: exact name, then alias, then fuzzy name
  select l.id, l.name, 1.0::real into v_id, v_name, v_score
    from public.category_library l where l.name_norm = v_q limit 1;

  if v_id is null then
    select l.id, l.name, 1.0::real into v_id, v_name, v_score
      from public.category_library_aliases a
      join public.category_library l on l.id = a.library_id
     where a.alias_norm = v_q limit 1;
  end if;

  if v_id is null then
    select l.id, l.name, similarity(l.name_norm, v_q) into v_id, v_name, v_score
      from public.category_library l
     where similarity(l.name_norm, v_q) >= 0.5
       and public.df20_token_overlap(l.name_norm, v_q)
     order by similarity(l.name_norm, v_q) desc limit 1;
  end if;

  if v_id is null then
    select l.id, l.name, similarity(a.alias_norm, v_q) into v_id, v_name, v_score
      from public.category_library_aliases a
      join public.category_library l on l.id = a.library_id
     where similarity(a.alias_norm, v_q) >= 0.5
       and public.df20_token_overlap(a.alias_norm, v_q)
     order by similarity(a.alias_norm, v_q) desc limit 1;
  end if;

  if v_id is not null then
    select count(*) into v_n from public.category_library_items where library_id = v_id;
    if v_n >= p_min_items then
      return jsonb_build_object('source','library','source_id',v_id,'name',v_name,
                                'item_count',v_n,'score',round(v_score::numeric,3));
    end if;
  end if;

  -- 2. internal Wikipedia cache, same rules
  select c.id, c.article_title, 1.0::real into v_id, v_name, v_score
    from public.wikipedia_cache c where c.query_norm = v_q limit 1;

  if v_id is null then
    select c.id, c.article_title, similarity(c.query_norm, v_q) into v_id, v_name, v_score
      from public.wikipedia_cache c
     where similarity(c.query_norm, v_q) >= 0.5
       and public.df20_token_overlap(c.query_norm, v_q)
     order by similarity(c.query_norm, v_q) desc limit 1;
  end if;

  if v_id is not null then
    select count(*) into v_n from public.wikipedia_cache_items where cache_id = v_id;
    if v_n >= p_min_items then
      return jsonb_build_object('source','wikipedia','source_id',v_id,'name',v_name,
                                'item_count',v_n,'score',round(v_score::numeric,3));
    end if;
  end if;

  return null;
end $$;
grant execute on function public.df20_match_category(text, int) to anon, authenticated;

-- ── aliases for the seeded categories ─────────────────────────────────────
select public.df20_add_alias('NFL Teams', array['nfl','football teams','american football teams','pro football teams']);
select public.df20_add_alias('NBA Teams', array['nba','basketball teams','pro basketball teams']);
select public.df20_add_alias('MLB Teams', array['mlb','baseball teams','pro baseball teams']);
select public.df20_add_alias('US States', array['states','american states','fifty states','50 states']);
select public.df20_add_alias('Breakfast Cereals', array['cereal','cereals','breakfast cereal']);
select public.df20_add_alias('Fast Food Chains', array['fast food','burger chains','fast food restaurants']);
select public.df20_add_alias('Candy and Sweets', array['candy','sweets','chocolate bars','candy bars','chocolate']);
select public.df20_add_alias('Pizza Toppings', array['pizza','toppings']);
select public.df20_add_alias('Ice Cream Flavors', array['ice cream','ice cream flavours','gelato flavors']);
select public.df20_add_alias('Soft Drinks', array['soda','pop','fizzy drinks','soft drink','sodas','soda flavors']);
select public.df20_add_alias('Dog Breeds', array['dogs','breeds of dog','dog']);
select public.df20_add_alias('Board Games', array['board game','tabletop games','family games']);
select public.df20_add_alias('Video Game Franchises', array['video games','games','gaming','video game series']);
select public.df20_add_alias('Superheroes', array['superhero','comic book heroes','marvel heroes','comic heroes']);
select public.df20_add_alias('Chip Flavors', array['chips','crisps','potato chips','crisp flavours']);
select public.df20_add_alias('Football Draft', array['nfl players','football players','nfl quarterbacks']);

-- ─────────── 0013_repair_and_selfcheck.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0013 · repair create_room, and stop this class of bug
--
-- ROOT CAUSE of "function public.df20_clean_logo_url(text) does not exist":
--   create_room was rewritten in 0010 and calls df20_clean_logo_url, which was
--   defined in 0008. 0008 was never applied, so the caller existed without the
--   callee. plpgsql does not validate function bodies at creation, so the
--   migration reported success and the failure only surfaced on a real click.
--
-- Fixed three ways. The third is the one that matters.
--   1. df20_clean_logo_url now lives beside its only caller.
--   2. It returns early when there is no logo, so creating a room never
--      depends on branding machinery existing at all.
--   3. df20_selfcheck() asserts every dependency is present, so a partial
--      apply fails LOUDLY here instead of silently at click time.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── carried from 0008, which is missing on at least one live database ─────
create or replace function public.df20_rate_limit(
  p_bucket text, p_subject text, p_limit int, p_window_seconds int
) returns boolean language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_start timestamptz; v_count int;
begin
  if p_window_seconds < 1 then p_window_seconds := 60; end if;
  v_start := to_timestamp(
    floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);
  insert into public.rate_limits (bucket, subject, window_start, count)
  values (left(p_bucket, 40), left(p_subject, 100), v_start, 1)
  on conflict (bucket, subject, window_start)
  do update set count = public.rate_limits.count + 1
  returning count into v_count;
  return v_count <= p_limit;
end $$;
grant execute on function public.df20_rate_limit(text, text, int, int) to anon, authenticated;

-- ── the function that was missing, now beside its caller ──────────────────
create or replace function public.df20_clean_logo_url(p_in text)
returns text language plpgsql immutable as $$
declare v text;
begin
  -- the common case by a mile: no logo. Creating a room must not depend on
  -- any of the branding validation below being reachable.
  if p_in is null or btrim(p_in) = '' then return null; end if;

  v := public.df20_clean_text(p_in, 500);
  if v = '' then return null; end if;

  -- https, and our own storage only. Anything else is a URL a stranger
  -- controls being rendered into someone else's shareable card.
  if v !~ '^https://[A-Za-z0-9.-]+\.supabase\.co/storage/v1/object/public/brand/' then
    raise exception 'DF20_BAD_LOGO_URL';
  end if;
  return v;
end $$;

-- ── brand bucket, also from 0008 ──────────────────────────────────────────
do $$
begin
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('brand', 'brand', true, 524288, array['image/png','image/jpeg','image/webp'])
  on conflict (id) do update
    set public = true, file_size_limit = 524288,
        allowed_mime_types = array['image/png','image/jpeg','image/webp'];
exception when others then
  raise notice 'storage schema unavailable; skipping brand bucket';
end $$;

-- ── WHAT MUST EXIST FOR THE APP TO WORK ───────────────────────────────────
-- Every entry here is something an RPC calls at runtime. Postgres will not
-- check these for us, so we check them ourselves.
create or replace function public.df20_selfcheck()
returns text language plpgsql as $$
declare
  v_missing text[] := '{}';
  f text;
  v_required text[] := array[
    -- money and game loop
    'public.df20_max_legal_bid(integer,integer,integer)',
    'public.df20_open_slots(uuid,uuid)',
    'public.df20_opponent(uuid,uuid)',
    'public.df20_can_outbid(uuid,uuid,integer)',
    'public.df20_is_broke(uuid,uuid)',
    'public.df20_add_to_roster(uuid,uuid,text,integer,boolean)',
    'public.df20_resolve_lot(uuid,text)',
    'public.df20_resolve_gift(uuid,uuid)',
    'public.df20_reveal_next(uuid)',
    'public.df20_advance(uuid)',
    'public.df20_public_state(uuid)',
    'public.df20_broadcast(uuid)',
    'public.df20_touch(uuid)',
    'public.df20_gen_code()',
    -- text safety, the pair that broke
    'public.df20_clean_text(text,integer)',
    'public.df20_clean_logo_url(text)',
    -- categories
    'public.df20_norm_category(text)',
    'public.df20_token_overlap(text,text)',
    'public.df20_match_category(text,integer)',
    'public.df20_fill_pool(uuid,text,uuid)',
    'public.df20_seed_category(text,text[])',
    'public.df20_cache_wikipedia(text,text,text,text[])',
    'public.df20_looks_like_person(text)',
    'public.df20_person_oriented_category(text)',
    -- abuse control
    'public.df20_rate_limit(text,text,integer,integer)',
    'public.df20_ensure_profile()',
    -- the client API
    'public.create_room(text,integer,integer,integer,integer,text,boolean,integer,text,text,text,uuid)',
    'public.create_pending_room()',
    'public.get_setup_state(uuid)',
    'public.setup_lock_items(uuid,text,text[],integer,integer,integer,integer,integer)',
    'public.join_room(text,text)',
    'public.start_draft(text,uuid)',
    'public.offer_decide(text,uuid,text)',
    'public.place_bid(text,uuid,integer,integer)',
    'public.pass_turn(text,uuid,integer)',
    'public.expire_turn(text)',
    'public.submit_vote(text,uuid,uuid)',
    'public.get_room_state(text)',
    'public.offer_library_optin(uuid)',
    'public.submit_library_optin(uuid,boolean)'
  ];
  v_tables text[] := array['rooms','players','room_deck','room_pool','roster_entries',
                           'lots','bid_events','votes','rate_limits','category_library',
                           'category_library_items','category_library_aliases',
                           'wikipedia_cache','wikipedia_cache_items','profiles','templates'];
  t text;
begin
  foreach f in array v_required loop
    if to_regprocedure(f) is null then v_missing := v_missing || f; end if;
  end loop;
  foreach t in array v_tables loop
    if to_regclass('public.' || t) is null then v_missing := v_missing || ('table ' || t); end if;
  end loop;

  if coalesce(array_length(v_missing, 1), 0) > 0 then
    raise exception E'DF20_SELFCHECK_FAILED\nmissing:\n  %',
      array_to_string(v_missing, E'\n  ');
  end if;

  return format('ok - %s functions and %s tables present',
                array_length(v_required, 1), array_length(v_tables, 1));
end $$;
revoke all on function public.df20_selfcheck() from anon, authenticated;

-- ─────────── 0014_more_categories.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0014 · six more free categories, and the free-shelf listing
--
-- Real, factual lists of public things. Curated for PLAY, not reference: no
-- list claims to be exhaustive, they claim to be arguable.
-- ═══════════════════════════════════════════════════════════════════════════

-- Disney Animated Movies · 52 items
select public.df20_seed_category('Disney Animated Movies', string_to_array($it$Snow White and the Seven Dwarfs
Pinocchio
Fantasia
Dumbo
Bambi
Cinderella
Alice in Wonderland
Peter Pan
Lady and the Tramp
Sleeping Beauty
One Hundred and One Dalmatians
The Sword in the Stone
The Jungle Book
The Aristocats
Robin Hood
The Rescuers
The Fox and the Hound
The Black Cauldron
The Great Mouse Detective
Oliver and Company
The Little Mermaid
Beauty and the Beast
Aladdin
The Lion King
Pocahontas
The Hunchback of Notre Dame
Hercules
Mulan
Tarzan
Dinosaur
The Emperor's New Groove
Atlantis: The Lost Empire
Lilo and Stitch
Treasure Planet
Brother Bear
Home on the Range
Chicken Little
Meet the Robinsons
Bolt
The Princess and the Frog
Tangled
Winnie the Pooh
Wreck-It Ralph
Frozen
Big Hero 6
Zootopia
Moana
Ralph Breaks the Internet
Frozen II
Raya and the Last Dragon
Encanto
Wish$it$, E'\n'));
select public.df20_add_alias('Disney Animated Movies', array['disney movies','disney films','disney','animated disney movies']);

-- TV Sitcoms · 52 items
select public.df20_seed_category('TV Sitcoms', string_to_array($it$Friends
Seinfeld
The Office
Parks and Recreation
30 Rock
Cheers
Frasier
I Love Lucy
The Simpsons
Family Guy
South Park
King of the Hill
Arrested Development
Community
Brooklyn Nine-Nine
How I Met Your Mother
The Big Bang Theory
Modern Family
Scrubs
It's Always Sunny in Philadelphia
Curb Your Enthusiasm
Malcolm in the Middle
Everybody Loves Raymond
Will and Grace
The Golden Girls
Full House
Family Matters
The Fresh Prince of Bel-Air
Boy Meets World
Home Improvement
Roseanne
Married with Children
Three's Company
Happy Days
Taxi
Night Court
WKRP in Cincinnati
The Mary Tyler Moore Show
All in the Family
Sanford and Son
Good Times
The Jeffersons
Perfect Strangers
Saved by the Bell
Spin City
NewsRadio
The Good Place
Superstore
Veep
Ted Lasso
Abbott Elementary
Schitt's Creek$it$, E'\n'));
select public.df20_add_alias('TV Sitcoms', array['sitcoms','tv comedies','comedy shows','tv shows']);

-- Movie Villains · 52 items
select public.df20_seed_category('Movie Villains', string_to_array($it$Darth Vader
Hannibal Lecter
Norman Bates
The Joker
Lord Voldemort
Sauron
Freddy Krueger
Michael Myers
Jason Voorhees
Hans Gruber
Nurse Ratched
Anton Chigurh
The Terminator
Agent Smith
Scar
Ursula
Maleficent
Cruella de Vil
Jafar
Gaston
Hades
Captain Hook
The Wicked Witch of the West
Bane
Two-Face
The Penguin
Green Goblin
Doctor Octopus
Thanos
Loki
Magneto
Emperor Palpatine
Kylo Ren
Saruman
Amon Goeth
Colonel Kurtz
Annie Wilkes
Patrick Bateman
Keyser Soze
Bill the Butcher
Immortan Joe
Pennywise
Chucky
Ghostface
Leatherface
HAL 9000
Lord Farquaad
Syndrome
Randall Boggs
Shere Khan
Regina George
Nurse Mildred$it$, E'\n'));
select public.df20_add_alias('Movie Villains', array['villains','film villains','bad guys','movie bad guys']);

-- 2000s Songs · 56 items
select public.df20_seed_category('2000s Songs', string_to_array($it$Hey Ya!
Crazy in Love
Toxic
Since U Been Gone
Mr. Brightside
Seven Nation Army
Lose Yourself
In Da Club
Hot in Herre
Get the Party Started
Complicated
Beautiful Day
Clocks
Yellow
Boulevard of Broken Dreams
American Idiot
Bring Me to Life
Numb
In the End
Chop Suey!
Last Resort
The Middle
All the Small Things
Sk8er Boi
Fallin'
A Thousand Miles
Drops of Jupiter
How You Remind Me
Kryptonite
Bye Bye Bye
Oops!... I Did It Again
Survivor
Independent Women
Dilemma
Yeah!
Gold Digger
Stronger
Umbrella
Single Ladies
Poker Face
I Gotta Feeling
Boom Boom Pow
Party in the U.S.A.
Use Somebody
Viva la Vida
Chasing Cars
Hips Don't Lie
SexyBack
Promiscuous
Rehab
Take Me Out
Somebody Told Me
Float On
Maps
Feel Good Inc.
Paper Planes$it$, E'\n'));
select public.df20_add_alias('2000s Songs', array['2000s music','00s songs','2000s hits','noughties songs']);

-- 90s Songs · 55 items
select public.df20_seed_category('90s Songs', string_to_array($it$Smells Like Teen Spirit
Wonderwall
Creep
Losing My Religion
Black Hole Sun
Under the Bridge
Give It Away
Jeremy
Alive
Basket Case
When I Come Around
Longview
Come As You Are
Lithium
Heart-Shaped Box
No Rain
Bittersweet Symphony
Song 2
Common People
Live Forever
Don't Look Back in Anger
Torn
Zombie
Linger
Iris
One Headlight
Semi-Charmed Life
Everybody Hurts
Man in the Box
Would?
Interstate Love Song
Plush
1979
Today
Bullet with Butterfly Wings
Loser
Where It's At
Sabotage
Intergalactic
Killing in the Name
Bulls on Parade
I Will Always Love You
Vogue
...Baby One More Time
Wannabe
No Scrubs
Waterfalls
Gangsta's Paradise
California Love
Juicy
Big Poppa
Hypnotize
Jump Around
Groove Is in the Heart
Believe$it$, E'\n'));
select public.df20_add_alias('90s Songs', array['90s music','1990s songs','90s hits','nineties songs']);

-- Halloween Candy · 50 items
select public.df20_seed_category('Halloween Candy', string_to_array($it$Reese's Peanut Butter Cups
Snickers
Kit Kat
Twix
Milky Way
3 Musketeers
Butterfinger
Baby Ruth
Almond Joy
Mounds
Hershey's Milk Chocolate
Hershey's Kisses
M&M's
Peanut M&M's
Skittles
Starburst
Sour Patch Kids
Swedish Fish
Nerds
Laffy Taffy
Airheads
Jolly Rancher
Tootsie Roll
Tootsie Pops
Blow Pops
Dum Dums
Smarties
Sweet Tarts
Pixy Stix
Fun Dip
Candy Corn
Mellowcreme Pumpkins
Milk Duds
Whoppers
Junior Mints
Raisinets
Whatchamacallit
100 Grand
Take 5
Payday
Nestle Crunch
Rolo
York Peppermint Pattie
Werther's Original
Now and Later
Mike and Ike
Hot Tamales
Good and Plenty
Bit-O-Honey
Charleston Chew$it$, E'\n'));
select public.df20_add_alias('Halloween Candy', array['halloween sweets','trick or treat candy','halloween treats']);

-- ── the free shelf, for the picker and the Random button ──────────────────
-- Names and counts only. Items never cross this boundary, same as every other
-- read path in the app.
create or replace function public.list_free_categories()
returns jsonb language sql stable security definer
set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'id', l.id,
               'name', l.name,
               'item_count', (select count(*) from public.category_library_items i
                               where i.library_id = l.id)) as x
        from public.category_library l
    ) s
   where (x->>'item_count')::int >= 20;
$$;
grant execute on function public.list_free_categories() to anon, authenticated;

do $$
declare v_c int; v_i int;
begin
  select count(*) into v_c from public.category_library;
  select count(*) into v_i from public.category_library_items;
  raise notice 'library now holds % categories and % items', v_c, v_i;
end $$;
-- ─────────── 0015_signin_gate.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0015 · custom categories require an account
--
-- FREE, no sign-in:  Football Draft, every premade library category, Random.
-- REQUIRES SIGN-IN:  typing your own category (Wikipedia), and the setup-link
--                    handoff where a third party builds the list.
--
-- Enforced here rather than only in the UI. The anon key is public and every
-- RPC is reachable with curl, so a gate that lives in a React component is
-- decoration. This is the gate.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.create_pending_room()
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_uid uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then raise exception 'DF20_SIGNIN_REQUIRED'; end if;

  -- one host should not be able to mint setup links without limit
  if not public.df20_rate_limit('pending_room', v_uid::text, 20, 3600) then
    raise exception 'DF20_RATE_LIMITED';
  end if;

  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, host_profile_id,
                            setup_token, setup_expires_at, pool_source)
  values (null, 'Untitled draft', 5, 2000, 100, 15, v_uid,
          gen_random_uuid(), now() + interval '24 hours', 'manual')
  returning * into v_room;

  return jsonb_build_object('setup_token', v_room.setup_token,
                            'expires_at', v_room.setup_expires_at,
                            'room_id', v_room.id);
end $$;
grant execute on function public.create_pending_room() to anon, authenticated;

-- ── create_room: the wikipedia pool is the premium one ────────────────────
create or replace function public.create_room(
  p_title text, p_roster_size int, p_bankroll_cents int, p_min_bid_cents int,
  p_timer_seconds int, p_host_name text, p_is_private boolean default true,
  p_gives_per_player int default 2, p_brand_accent text default null,
  p_brand_logo_url text default null,
  p_pool_source text default 'builtin', p_pool_ref uuid default null
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_pl public.players; v_uid uuid; v_accent text; v_n int;
begin
  v_uid := public.df20_ensure_profile();   -- null when signed out, which is fine

  -- a category the host typed themselves is the premium path; the premade
  -- shelf and the built-in pool stay open to everyone
  if coalesce(p_pool_source, 'builtin') = 'wikipedia' and v_uid is null then
    raise exception 'DF20_SIGNIN_REQUIRED';
  end if;

  p_title := public.df20_clean_text(p_title, 60);
  if length(p_title) = 0 then p_title := 'Football Draft'; end if;
  p_host_name := public.df20_clean_text(p_host_name, 24);
  if length(p_host_name) = 0 then raise exception 'DF20_BAD_NAME'; end if;

  if p_roster_size is null or p_roster_size < 1 or p_roster_size > 30
    then raise exception 'DF20_BAD_ROSTER_SIZE'; end if;
  if p_bankroll_cents is null or p_bankroll_cents < 0 or p_bankroll_cents > 10000000
    then raise exception 'DF20_BAD_BANKROLL'; end if;
  if p_min_bid_cents is null or p_min_bid_cents < 0 or p_min_bid_cents > 1000000
    then raise exception 'DF20_BAD_MIN_BID'; end if;
  if p_timer_seconds is null or p_timer_seconds < 3 or p_timer_seconds > 300
    then raise exception 'DF20_BAD_TIMER'; end if;
  if p_gives_per_player is null or p_gives_per_player < 0 or p_gives_per_player > 30
    then raise exception 'DF20_BAD_GIVES'; end if;

  v_accent := public.df20_clean_text(p_brand_accent, 9);
  if v_accent = '' then v_accent := null; end if;
  if v_accent is not null and v_accent !~ '^#[0-9A-Fa-f]{6}$'
    then raise exception 'DF20_BAD_ACCENT'; end if;

  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, gives_per_player,
                            is_private, brand_accent, brand_logo_url, host_profile_id)
  values (public.df20_gen_code(), p_title, p_roster_size, p_bankroll_cents,
          p_min_bid_cents, p_timer_seconds, p_gives_per_player,
          coalesce(p_is_private, true), v_accent,
          public.df20_clean_logo_url(p_brand_logo_url), v_uid)
  returning * into v_room;

  v_n := public.df20_fill_pool(v_room.id, coalesce(p_pool_source, 'builtin'), p_pool_ref);
  if v_n < p_roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;

  insert into public.players (room_id, seat, display_name, bankroll_cents, is_host, profile_id)
  values (v_room.id, 1, p_host_name, p_bankroll_cents, true, v_uid)
  returning * into v_pl;

  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code,
                            'player_id', v_pl.id, 'session_token', v_pl.session_token,
                            'seat', 1, 'pool_size', v_n);
end $$;
grant execute on function public.create_room(text,int,int,int,int,text,boolean,int,text,text,text,uuid) to anon, authenticated;

-- ── a host's own pending setup links, so closing the tab does not lose them ─
create or replace function public.my_pending_setups()
returns jsonb language sql stable security definer
set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'setup_token', r.setup_token,
           'expires_at', r.setup_expires_at,
           'created_at', r.created_at) order by r.created_at desc), '[]'::jsonb)
    from public.rooms r
   where r.host_profile_id = (select auth.uid())
     and (select auth.uid()) is not null
     and r.setup_token is not null
     and r.setup_expires_at > now();
$$;
grant execute on function public.my_pending_setups() to authenticated;

-- ── a host's locked rooms awaiting players ────────────────────────────────
create or replace function public.my_rooms()
returns jsonb language sql stable security definer
set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'code', r.code, 'title', r.title, 'status', r.status,
           'category', r.category_name, 'pool_source', r.pool_source,
           'created_at', r.created_at) order by r.created_at desc), '[]'::jsonb)
    from public.rooms r
   where r.host_profile_id = (select auth.uid())
     and (select auth.uid()) is not null
     and r.code is not null;
$$;
grant execute on function public.my_rooms() to authenticated;

-- ── a signed-in user does not automatically have a profiles row ───────────
-- rooms.host_profile_id references profiles(id), so setting it for a brand
-- new account would violate the foreign key on their very first custom room.
-- Supabase creates the auth.users row; nothing was creating this one.
create or replace function public.df20_ensure_profile()
returns uuid language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_uid uuid; v_email text;
begin
  v_uid := auth.uid();
  if v_uid is null then return null; end if;
  -- the email is a nicety; never let looking it up be the reason a host
  -- cannot create a room
  begin
    select u.email into v_email from auth.users u where u.id = v_uid;
  exception when others then v_email := null;
  end;

  insert into public.profiles (id, email) values (v_uid, v_email)
  on conflict (id) do nothing;
  return v_uid;
end $$;
revoke all on function public.df20_ensure_profile() from anon, authenticated;

create or replace function public.create_pending_room()
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_uid uuid;
begin
  v_uid := public.df20_ensure_profile();
  if v_uid is null then raise exception 'DF20_SIGNIN_REQUIRED'; end if;

  if not public.df20_rate_limit('pending_room', v_uid::text, 20, 3600) then
    raise exception 'DF20_RATE_LIMITED';
  end if;

  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, host_profile_id,
                            setup_token, setup_expires_at, pool_source)
  values (null, 'Untitled draft', 5, 2000, 100, 15, v_uid,
          gen_random_uuid(), now() + interval '24 hours', 'manual')
  returning * into v_room;

  return jsonb_build_object('setup_token', v_room.setup_token,
                            'expires_at', v_room.setup_expires_at,
                            'room_id', v_room.id);
end $$;
grant execute on function public.create_pending_room() to anon, authenticated;

-- ─────────── 0016_email_verified.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0016 · confirmed email required for the premium paths
--
-- Deliberately NOT folded into df20_ensure_profile(): that runs on every
-- create_room including the free shelf, so raising there would lock an
-- unconfirmed account out of Football Draft too. Verification gates the
-- premium paths only.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.df20_require_verified()
returns uuid language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_uid uuid; v_confirmed timestamptz;
begin
  v_uid := public.df20_ensure_profile();
  if v_uid is null then raise exception 'DF20_SIGNIN_REQUIRED'; end if;

  -- If the project has "Confirm email" switched off, Supabase stamps this at
  -- creation and the check simply always passes.
  begin
    select u.email_confirmed_at into v_confirmed from auth.users u where u.id = v_uid;
  exception when others then
    v_confirmed := now();   -- column absent: do not invent a lockout
  end;

  if v_confirmed is null then raise exception 'DF20_EMAIL_UNVERIFIED'; end if;
  return v_uid;
end $$;
revoke all on function public.df20_require_verified() from anon, authenticated;

-- ── the setup-link handoff ────────────────────────────────────────────────
create or replace function public.create_pending_room()
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_uid uuid;
begin
  v_uid := public.df20_require_verified();

  if not public.df20_rate_limit('pending_room', v_uid::text, 20, 3600) then
    raise exception 'DF20_RATE_LIMITED';
  end if;

  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, host_profile_id,
                            setup_token, setup_expires_at, pool_source)
  values (null, 'Untitled draft', 5, 2000, 100, 15, v_uid,
          gen_random_uuid(), now() + interval '24 hours', 'manual')
  returning * into v_room;

  return jsonb_build_object('setup_token', v_room.setup_token,
                            'expires_at', v_room.setup_expires_at,
                            'room_id', v_room.id);
end $$;
grant execute on function public.create_pending_room() to anon, authenticated;

-- ── the typed-category pool ───────────────────────────────────────────────
-- Only the wikipedia branch is gated. builtin and library stay free, and an
-- unconfirmed account can still play everything on the shelf.
create or replace function public.create_room(
  p_title text, p_roster_size int, p_bankroll_cents int, p_min_bid_cents int,
  p_timer_seconds int, p_host_name text, p_is_private boolean default true,
  p_gives_per_player int default 2, p_brand_accent text default null,
  p_brand_logo_url text default null,
  p_pool_source text default 'builtin', p_pool_ref uuid default null
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_pl public.players; v_uid uuid; v_accent text; v_n int;
begin
  if coalesce(p_pool_source, 'builtin') = 'wikipedia' then
    v_uid := public.df20_require_verified();
  else
    v_uid := public.df20_ensure_profile();   -- null when signed out, which is fine
  end if;

  p_title := public.df20_clean_text(p_title, 60);
  if length(p_title) = 0 then p_title := 'Football Draft'; end if;
  p_host_name := public.df20_clean_text(p_host_name, 24);
  if length(p_host_name) = 0 then raise exception 'DF20_BAD_NAME'; end if;

  if p_roster_size is null or p_roster_size < 1 or p_roster_size > 30
    then raise exception 'DF20_BAD_ROSTER_SIZE'; end if;
  if p_bankroll_cents is null or p_bankroll_cents < 0 or p_bankroll_cents > 10000000
    then raise exception 'DF20_BAD_BANKROLL'; end if;
  if p_min_bid_cents is null or p_min_bid_cents < 0 or p_min_bid_cents > 1000000
    then raise exception 'DF20_BAD_MIN_BID'; end if;
  if p_timer_seconds is null or p_timer_seconds < 3 or p_timer_seconds > 300
    then raise exception 'DF20_BAD_TIMER'; end if;
  if p_gives_per_player is null or p_gives_per_player < 0 or p_gives_per_player > 30
    then raise exception 'DF20_BAD_GIVES'; end if;

  v_accent := public.df20_clean_text(p_brand_accent, 9);
  if v_accent = '' then v_accent := null; end if;
  if v_accent is not null and v_accent !~ '^#[0-9A-Fa-f]{6}$'
    then raise exception 'DF20_BAD_ACCENT'; end if;

  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, gives_per_player,
                            is_private, brand_accent, brand_logo_url, host_profile_id)
  values (public.df20_gen_code(), p_title, p_roster_size, p_bankroll_cents,
          p_min_bid_cents, p_timer_seconds, p_gives_per_player,
          coalesce(p_is_private, true), v_accent,
          public.df20_clean_logo_url(p_brand_logo_url), v_uid)
  returning * into v_room;

  v_n := public.df20_fill_pool(v_room.id, coalesce(p_pool_source, 'builtin'), p_pool_ref);
  if v_n < p_roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;

  insert into public.players (room_id, seat, display_name, bankroll_cents, is_host, profile_id)
  values (v_room.id, 1, p_host_name, p_bankroll_cents, true, v_uid)
  returning * into v_pl;

  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code,
                            'player_id', v_pl.id, 'session_token', v_pl.session_token,
                            'seat', 1, 'pool_size', v_n);
end $$;
grant execute on function public.create_room(text,int,int,int,int,text,boolean,int,text,text,text,uuid) to anon, authenticated;

-- ─────────── 0017_profiles.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0017 · persistent profiles, saved decks, premium status
--
-- profiles already existed (0001) and holds host branding. This adds the
-- three things the rest of v6 reads:
--
--   1. PREMIUM.  One rule, everywhere: premium_until > now(). A Stripe
--      subscription, a 24-hour Game Night Pass and a manual admin grant all
--      write the SAME field, so every gate in the app is one comparison and
--      an admin grant is indistinguishable from a paid subscription.
--      premium_source records WHICH of the three it was, for display only —
--      nothing gates on it.
--
--   2. SAVED DECKS.  A host's own reusable categories, distinct from the
--      public category_library. Deny-all like every other pool table: the
--      RPCs return names and COUNTS, never an item. A host who built a list
--      through the setup handoff has never seen it, and saving it must not
--      become the hole that shows it to them.
--
--   3. STATS.  Derived at read time from rooms / players / votes. Nothing
--      here invents a scoring system: a "win" is the existing one-tap human
--      vote on the results screen and nothing else.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── the columns ───────────────────────────────────────────────────────────
alter table public.profiles
  add column if not exists premium_until          timestamptz,
  add column if not exists premium_source         text,
  add column if not exists subscription_status    text,
  add column if not exists stripe_customer_id     text,
  add column if not exists stripe_subscription_id text,
  -- export card customisation. The watermark default is TRUE and stays TRUE
  -- for a paying account until they turn it off themselves.
  add column if not exists export_watermark boolean not null default true,
  add column if not exists export_logo_url  text,
  add column if not exists export_accent    text,
  add column if not exists export_handle    text,
  add column if not exists updated_at       timestamptz not null default now();

do $$ begin
  alter table public.profiles add constraint profiles_premium_source_chk
    check (premium_source is null or premium_source in
           ('stripe_subscription','admin_grant','game_night_pass'));
exception when duplicate_object then null; end $$;

create unique index if not exists profiles_stripe_customer_idx
  on public.profiles(stripe_customer_id) where stripe_customer_id is not null;
create index if not exists profiles_premium_until_idx
  on public.profiles(premium_until) where premium_until is not null;

-- ── THE premium check. Every gate in the app resolves to this. ────────────
-- Deliberately NOT "subscription_status = 'active'": a cancelled subscription
-- that is paid up to the end of the period keeps access until that date, and
-- a pass or an admin grant has no subscription at all. The expiry timestamp
-- is the only thing all three have in common, so it is the only thing asked.
create or replace function public.df20_premium_active(p_uid uuid)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select coalesce((select p.premium_until > now()
                     from public.profiles p where p.id = p_uid), false)
$$;
revoke all on function public.df20_premium_active(uuid) from anon, authenticated;

-- what the signed-in caller is allowed to know about their own billing
create or replace function public.my_premium()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_uid uuid; v_p public.profiles;
begin
  v_uid := auth.uid();
  if v_uid is null then
    return jsonb_build_object('signed_in', false, 'active', false);
  end if;
  select * into v_p from public.profiles where id = v_uid;
  if not found then
    return jsonb_build_object('signed_in', true, 'active', false);
  end if;
  return jsonb_build_object(
    'signed_in', true,
    'active', coalesce(v_p.premium_until > now(), false),
    'until', to_jsonb(v_p.premium_until),
    'source', v_p.premium_source,
    'status', v_p.subscription_status,
    'has_customer', v_p.stripe_customer_id is not null,
    'export', jsonb_build_object(
      'watermark', v_p.export_watermark,
      'logo_url', v_p.export_logo_url,
      'accent', v_p.export_accent,
      'handle', v_p.export_handle));
end $$;
grant execute on function public.my_premium() to anon, authenticated;

-- ── export preferences ────────────────────────────────────────────────────
-- Saved by anyone; APPLIED only while premium is active (see
-- df20_export_style below). A lapsed subscription therefore degrades to the
-- standard watermarked card with no error and nothing lost.
create or replace function public.save_export_style(
  p_watermark boolean, p_logo_url text, p_accent text, p_handle text
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_uid uuid; v_accent text; v_handle text;
begin
  v_uid := public.df20_ensure_profile();
  if v_uid is null then raise exception 'DF20_SIGNIN_REQUIRED'; end if;

  v_accent := public.df20_clean_text(p_accent, 9);
  if v_accent = '' then v_accent := null; end if;
  if v_accent is not null and v_accent !~ '^#[0-9A-Fa-f]{6}$'
    then raise exception 'DF20_BAD_ACCENT'; end if;

  v_handle := public.df20_clean_text(p_handle, 32);
  if v_handle = '' then v_handle := null; end if;

  update public.profiles
     set export_watermark = coalesce(p_watermark, true),
         -- same storage-only rule as the room logo: this file gets rendered
         -- into an image other people share
         export_logo_url  = public.df20_clean_logo_url(p_logo_url),
         export_accent    = v_accent,
         export_handle    = v_handle,
         updated_at       = now()
   where id = v_uid;

  return public.my_premium();
end $$;
grant execute on function public.save_export_style(boolean,text,text,text) to authenticated;

-- ── what the PNG route draws ──────────────────────────────────────────────
-- Resolved SERVER-SIDE from the room's host profile. The route passes a room
-- code and nothing else, so there is no parameter anywhere that turns the
-- watermark off — not a query string, not a header, not a client flag.
--
-- Watermark on unless ALL of: the room has a host account, that account has
-- active premium right now, and that account has explicitly set the toggle
-- off. Any other combination, including "premium but never touched the
-- settings", is the standard card.
create or replace function public.df20_export_style(p_code text)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_p public.profiles;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code));
  if not found or v_room.host_profile_id is null then
    return jsonb_build_object('watermark', true);
  end if;

  select * into v_p from public.profiles where id = v_room.host_profile_id;
  if not found or coalesce(v_p.premium_until > now(), false) = false then
    return jsonb_build_object('watermark', true);
  end if;

  return jsonb_build_object(
    'watermark', coalesce(v_p.export_watermark, true),
    'logo_url', v_p.export_logo_url,
    'accent', v_p.export_accent,
    'handle', v_p.export_handle);
end $$;
grant execute on function public.df20_export_style(text) to anon, authenticated;

-- ── saved decks ───────────────────────────────────────────────────────────
create table if not exists public.user_categories (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null references public.profiles(id) on delete cascade,
  name        text not null,
  source      text,
  created_at  timestamptz not null default now(),
  unique (owner_id, name)
);
create index if not exists user_categories_owner_idx on public.user_categories(owner_id);

create table if not exists public.user_category_items (
  category_id uuid not null references public.user_categories(id) on delete cascade,
  name        text not null,
  primary key (category_id, name)
);

-- 0009's lesson: a cascade drop leaves the child table standing with orphans
delete from public.user_category_items i
 where not exists (select 1 from public.user_categories c where c.id = i.category_id);

alter table public.user_categories      enable row level security;
alter table public.user_category_items  enable row level security;
revoke all on public.user_categories     from anon, authenticated;
revoke all on public.user_category_items from anon, authenticated;

-- save the pool a finished room used, by NAME and COUNT only
create or replace function public.save_room_deck(p_code text, p_name text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_uid uuid; v_room public.rooms; v_id uuid; v_n int; v_name text;
begin
  v_uid := public.df20_ensure_profile();
  if v_uid is null then raise exception 'DF20_SIGNIN_REQUIRED'; end if;

  select * into v_room from public.rooms where code = upper(btrim(p_code));
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  if v_room.host_profile_id is distinct from v_uid then raise exception 'DF20_HOST_ONLY'; end if;

  v_name := public.df20_clean_text(coalesce(p_name, v_room.category_name, v_room.title), 60);
  if length(v_name) = 0 then raise exception 'DF20_BAD_CATEGORY'; end if;

  select count(*) into v_n from public.room_pool where room_id = v_room.id;
  if v_n = 0 then raise exception 'DF20_POOL_TOO_SMALL'; end if;

  insert into public.user_categories (owner_id, name, source)
  values (v_uid, v_name, v_room.pool_source)
  on conflict (owner_id, name) do update set source = excluded.source
  returning id into v_id;

  insert into public.user_category_items (category_id, name)
  select v_id, name from public.room_pool where room_id = v_room.id
  on conflict do nothing;

  select count(*) into v_n from public.user_category_items where category_id = v_id;
  return jsonb_build_object('id', v_id, 'name', v_name, 'item_count', v_n);
end $$;
grant execute on function public.save_room_deck(text, text) to authenticated;

-- names and counts. NEVER items: the host of a handoff room has never seen
-- this list and reusing it must not be the thing that shows it to them.
create or replace function public.my_decks()
returns jsonb language sql stable security definer
set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'name', c.name, 'source', c.source,
           'created_at', c.created_at,
           'item_count', (select count(*) from public.user_category_items i
                           where i.category_id = c.id)) order by c.created_at desc), '[]'::jsonb)
    from public.user_categories c
   where c.owner_id = (select auth.uid()) and (select auth.uid()) is not null;
$$;
grant execute on function public.my_decks() to authenticated;

create or replace function public.delete_deck(p_id uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_uid uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then raise exception 'DF20_SIGNIN_REQUIRED'; end if;
  delete from public.user_categories where id = p_id and owner_id = v_uid;
  return jsonb_build_object('deleted', true);
end $$;
grant execute on function public.delete_deck(uuid) to authenticated;

-- ── the pool source 'saved' ───────────────────────────────────────────────
do $$ begin
  alter table public.rooms drop constraint rooms_pool_source_chk;
exception when undefined_object then null; end $$;
alter table public.rooms add constraint rooms_pool_source_chk
  check (pool_source is null or pool_source in
         ('builtin','library','wikipedia','manual','saved'));

-- unchanged branches, one new one. Ownership is checked by create_room
-- BEFORE this is reached, because fill_pool has no idea who is calling.
create or replace function public.df20_fill_pool(
  p_room uuid, p_source text, p_ref uuid
) returns int language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_n int; v_name text;
begin
  if p_source in ('builtin','library') then
    if p_ref is null then
      select id into p_ref from public.category_library
       where name_norm = public.df20_norm_category('Football Draft');
    end if;
    select name into v_name from public.category_library where id = p_ref;
    if v_name is null then raise exception 'DF20_NO_SUCH_CATEGORY'; end if;
    insert into public.room_pool (room_id, name)
      select p_room, i.name from public.category_library_items i where i.library_id = p_ref
      on conflict do nothing;
  elsif p_source = 'wikipedia' then
    select article_title into v_name from public.wikipedia_cache where id = p_ref;
    if v_name is null then raise exception 'DF20_NO_SUCH_CATEGORY'; end if;
    insert into public.room_pool (room_id, name)
      select p_room, i.name from public.wikipedia_cache_items i where i.cache_id = p_ref
      on conflict do nothing;
  elsif p_source = 'saved' then
    select name into v_name from public.user_categories where id = p_ref;
    if v_name is null then raise exception 'DF20_NO_SUCH_CATEGORY'; end if;
    insert into public.room_pool (room_id, name)
      select p_room, i.name from public.user_category_items i where i.category_id = p_ref
      on conflict do nothing;
  else
    raise exception 'DF20_BAD_POOL_SOURCE';
  end if;

  select count(*) into v_n from public.room_pool where room_id = p_room;
  update public.rooms
     set pool_source = p_source,
         category_name = coalesce(category_name, v_name)
   where id = p_room;
  return v_n;
end $$;
revoke all on function public.df20_fill_pool(uuid, text, uuid) from anon, authenticated;

-- ── create_room: the 0016 body, plus the 'saved' branch ───────────────────
-- Only two lines differ from 0016: a deck you did not create is not a pool
-- you may draw from, checked here because df20_fill_pool never learns who
-- the caller is.
create or replace function public.create_room(
  p_title text, p_roster_size int, p_bankroll_cents int, p_min_bid_cents int,
  p_timer_seconds int, p_host_name text, p_is_private boolean default true,
  p_gives_per_player int default 2, p_brand_accent text default null,
  p_brand_logo_url text default null,
  p_pool_source text default 'builtin', p_pool_ref uuid default null
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_pl public.players; v_uid uuid; v_accent text; v_n int;
begin
  if coalesce(p_pool_source, 'builtin') in ('wikipedia','saved') then
    v_uid := public.df20_require_verified();
  else
    v_uid := public.df20_ensure_profile();   -- null when signed out, which is fine
  end if;

  if coalesce(p_pool_source, 'builtin') = 'saved' then
    if not exists (select 1 from public.user_categories
                    where id = p_pool_ref and owner_id = v_uid) then
      raise exception 'DF20_NOT_YOUR_DECK';
    end if;
  end if;

  p_title := public.df20_clean_text(p_title, 60);
  if length(p_title) = 0 then p_title := 'Football Draft'; end if;
  p_host_name := public.df20_clean_text(p_host_name, 24);
  if length(p_host_name) = 0 then raise exception 'DF20_BAD_NAME'; end if;

  if p_roster_size is null or p_roster_size < 1 or p_roster_size > 30
    then raise exception 'DF20_BAD_ROSTER_SIZE'; end if;
  if p_bankroll_cents is null or p_bankroll_cents < 0 or p_bankroll_cents > 10000000
    then raise exception 'DF20_BAD_BANKROLL'; end if;
  if p_min_bid_cents is null or p_min_bid_cents < 0 or p_min_bid_cents > 1000000
    then raise exception 'DF20_BAD_MIN_BID'; end if;
  if p_timer_seconds is null or p_timer_seconds < 3 or p_timer_seconds > 300
    then raise exception 'DF20_BAD_TIMER'; end if;
  if p_gives_per_player is null or p_gives_per_player < 0 or p_gives_per_player > 30
    then raise exception 'DF20_BAD_GIVES'; end if;

  v_accent := public.df20_clean_text(p_brand_accent, 9);
  if v_accent = '' then v_accent := null; end if;
  if v_accent is not null and v_accent !~ '^#[0-9A-Fa-f]{6}$'
    then raise exception 'DF20_BAD_ACCENT'; end if;

  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, gives_per_player,
                            is_private, brand_accent, brand_logo_url, host_profile_id)
  values (public.df20_gen_code(), p_title, p_roster_size, p_bankroll_cents,
          p_min_bid_cents, p_timer_seconds, p_gives_per_player,
          coalesce(p_is_private, true), v_accent,
          public.df20_clean_logo_url(p_brand_logo_url), v_uid)
  returning * into v_room;

  v_n := public.df20_fill_pool(v_room.id, coalesce(p_pool_source, 'builtin'), p_pool_ref);
  if v_n < p_roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;

  insert into public.players (room_id, seat, display_name, bankroll_cents, is_host, profile_id)
  values (v_room.id, 1, p_host_name, p_bankroll_cents, true, v_uid)
  returning * into v_pl;

  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code,
                            'player_id', v_pl.id, 'session_token', v_pl.session_token,
                            'seat', 1, 'pool_size', v_n);
end $$;
grant execute on function public.create_room(text,int,int,int,int,text,boolean,int,text,text,text,uuid) to anon, authenticated;

-- ── join_room: attribute a seat to an account when there is one ──────────
-- Identical to 0010 — including the first-free-seat assignment that a
-- setup-link room depends on, since that room has no players at all until
-- somebody joins — except for profile_id. Signing in is NOT required to
-- join and never will be; this only means that if you happen to be signed
-- in, the draft counts towards your played total.
create or replace function public.join_room(p_code text, p_display_name text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_pl public.players; v_n int; v_seat int;
        v_host boolean; v_uid uuid;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  if v_room.status <> 'lobby' then raise exception 'DF20_ALREADY_STARTED'; end if;

  p_display_name := public.df20_clean_text(p_display_name, 24);
  if length(p_display_name) = 0 then raise exception 'DF20_BAD_NAME'; end if;

  select count(*) into v_n from public.players where room_id = v_room.id;
  if v_n >= 2 then raise exception 'DF20_ROOM_FULL'; end if;

  select min(s) into v_seat from generate_series(1,2) s
   where not exists (select 1 from public.players
                      where room_id = v_room.id and seat = s);

  v_host := not exists (select 1 from public.players
                         where room_id = v_room.id and is_host);

  -- never a reason to refuse a seat: a profile row that cannot be created
  -- leaves this null and the player joins anyway
  begin
    v_uid := public.df20_ensure_profile();
  exception when others then v_uid := null;
  end;

  insert into public.players (room_id, seat, display_name, bankroll_cents, is_host, profile_id)
  values (v_room.id, v_seat, p_display_name, v_room.starting_bankroll_cents, v_host, v_uid)
  returning * into v_pl;

  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);
  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code,
                            'player_id', v_pl.id, 'session_token', v_pl.session_token,
                            'seat', v_pl.seat);
end $$;
grant execute on function public.join_room(text, text) to anon, authenticated;

-- ── the manual result ─────────────────────────────────────────────────────
-- There is no algorithmic winner in this game and this does not invent one.
-- It reads the existing one-tap vote on the results screen: the player with
-- strictly more votes. Two players who disagree is a tie, and a tie is not a
-- win for anybody.
create or replace function public.df20_manual_winner(p_room uuid)
returns uuid language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_top uuid; v_top_n bigint; v_next_n bigint;
begin
  select winner_player_id, count(*) into v_top, v_top_n
    from public.votes where room_id = p_room
   group by winner_player_id order by count(*) desc, winner_player_id limit 1;
  if v_top is null then return null; end if;

  select count(*) into v_next_n
    from public.votes where room_id = p_room and winner_player_id <> v_top
   group by winner_player_id order by count(*) desc limit 1;

  if v_next_n is not null and v_next_n >= v_top_n then return null; end if;
  return v_top;
end $$;
revoke all on function public.df20_manual_winner(uuid) from anon, authenticated;

-- ── the profile page's numbers, and the badges derived from them ──────────
create or replace function public.my_profile_stats()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_uid uuid; v_p public.profiles;
  v_hosted int; v_played int; v_finished int;
  v_wins int; v_losses int; v_undecided int;
  v_decks int; v_judged int; v_badges jsonb := '[]'::jsonb;
begin
  v_uid := auth.uid();
  if v_uid is null then return jsonb_build_object('signed_in', false); end if;
  select * into v_p from public.profiles where id = v_uid;

  select count(*) into v_hosted from public.rooms r
   where r.host_profile_id = v_uid and r.code is not null
     and r.status in ('live','complete');

  select count(*) into v_played from public.rooms r
   where r.status in ('live','complete')
     and exists (select 1 from public.players p
                  where p.room_id = r.id and p.profile_id = v_uid);

  select count(*) into v_finished from public.rooms r
   where r.status = 'complete'
     and exists (select 1 from public.players p
                  where p.room_id = r.id and p.profile_id = v_uid);

  select
    count(*) filter (where w.winner = w.me),
    count(*) filter (where w.winner is not null and w.winner <> w.me),
    count(*) filter (where w.winner is null)
    into v_wins, v_losses, v_undecided
    from (select p.id as me, public.df20_manual_winner(r.id) as winner
            from public.rooms r
            join public.players p on p.room_id = r.id and p.profile_id = v_uid
           where r.status = 'complete') w;

  select count(*) into v_decks from public.user_categories where owner_id = v_uid;

  -- audience_votes arrives in 0018. A function body referencing a table that
  -- does not exist yet is exactly the failure 0013 was written about, so this
  -- asks whether the table is there rather than assuming the whole bundle ran.
  if to_regclass('public.audience_votes') is null then
    v_judged := 0;
  else
    execute $q$
      select count(distinct r.id)
        from public.rooms r
        join public.players p on p.room_id = r.id and p.profile_id = $1
       where exists (select 1 from public.audience_votes a where a.room_id = r.id)
    $q$ into v_judged using v_uid;
  end if;

  -- six thresholds, all plainly true or plainly false. No levels, no points.
  if v_hosted  >= 1  then v_badges := v_badges || '["first_room"]'::jsonb;   end if;
  if v_hosted  >= 10 then v_badges := v_badges || '["ten_rooms"]'::jsonb;    end if;
  if v_played  >= 5  then v_badges := v_badges || '["five_drafts"]'::jsonb;  end if;
  if v_decks   >= 1  then v_badges := v_badges || '["deck_builder"]'::jsonb; end if;
  if v_wins    >= 1  then v_badges := v_badges || '["first_win"]'::jsonb;    end if;
  if v_judged  >= 1  then v_badges := v_badges || '["judged"]'::jsonb;       end if;

  return jsonb_build_object(
    'signed_in', true,
    'display_name', v_p.display_name,
    'email', v_p.email,
    'logo_url', v_p.brand_logo_url,
    'created_at', to_jsonb(v_p.created_at),
    'hosted', v_hosted, 'played', v_played, 'finished', v_finished,
    'wins', v_wins, 'losses', v_losses, 'undecided', v_undecided,
    'decks', v_decks, 'judged_rooms', v_judged,
    'badges', v_badges,
    'premium', public.my_premium());
end $$;
grant execute on function public.my_profile_stats() to authenticated;

-- ─────────── 0018_content.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0018 · the OBS source link and the audience vote
--
-- Two new public read paths, both read-only by construction:
--
--   get_obs_state(obs_token)     the live board for an OBS Browser Source
--   get_audience_state(code,key) the finished board a viewer votes on
--
-- Neither takes a session token, and every mutating RPC in this app
-- authenticates from a session token. There is therefore no argument either
-- of these views could pass to act on a game — the read path is the only
-- path they have.
--
-- The audience vote is a SEPARATE table from votes. votes is the two
-- players' one-tap call on who won and feeds the win/loss record; this is
-- the internet's opinion and feeds nothing but itself.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.rooms add column if not exists obs_token uuid;
create unique index if not exists rooms_obs_token_idx
  on public.rooms(obs_token) where obs_token is not null;

-- ── the snapshot must stop carrying tokens ────────────────────────────────
-- to_jsonb(rooms) means every column added to the table lands in the payload
-- every client already reads. That was survivable while the only secret in
-- the row was a setup link; adding obs_token to the table would have handed
-- it to both players' browsers automatically. Stripped by name, so a new
-- token column is a deliberate decision rather than an accident.
create or replace function public.df20_public_state(p_room uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp set timezone = 'UTC' as $$
declare v_room public.rooms;
begin
  select * into v_room from public.rooms where id = p_room;
  if not found then return null; end if;

  return jsonb_build_object(
    'server_now', to_jsonb(now()),
    'room', to_jsonb(v_room) - 'setup_token' - 'setup_result_token' - 'obs_token',
    'deck_remaining', public.df20_deck_remaining(p_room),
    'players', coalesce((
        select jsonb_agg(
                 (to_jsonb(pl) - 'session_token')
                 || jsonb_build_object(
                      'open_slots', public.df20_open_slots(p_room, pl.id),
                      'max_legal_bid_cents', public.df20_max_legal_bid(
                          pl.bankroll_cents, v_room.min_bid_cents,
                          public.df20_open_slots(p_room, pl.id)),
                      'is_broke', public.df20_is_broke(p_room, pl.id),
                      'gives_left', greatest(v_room.gives_per_player - pl.gives_used, 0))
                 order by pl.seat)
          from public.players pl where pl.room_id = p_room), '[]'::jsonb),
    'roster', coalesce((select jsonb_agg(to_jsonb(r) order by r.player_id, r.pick_number)
                          from public.roster_entries r where r.room_id = p_room), '[]'::jsonb),
    'lot', (select to_jsonb(l) from public.lots l where l.room_id = p_room
              order by (l.status in ('offered','bidding')) desc, l.created_at desc limit 1),
    'events', coalesce((select jsonb_agg(e order by e.id)
                          from (select * from public.bid_events
                                 where room_id = p_room order by id desc limit 60) e), '[]'::jsonb),
    'votes', coalesce((select jsonb_agg(to_jsonb(v)) from public.votes v
                        where v.room_id = p_room), '[]'::jsonb)
  );
end $$;
revoke all on function public.df20_public_state(uuid) from anon, authenticated;

-- ── mint the OBS link. Host seat + active premium. ────────────────────────
-- The premium check is here rather than only on the Content tab, because the
-- tab is a React component and this RPC is reachable with curl.
create or replace function public.mint_obs_token(p_code text, p_token uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_me public.players; v_tok uuid;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;

  select * into v_me from public.players
   where room_id = v_room.id and session_token = p_token;
  if not found then raise exception 'DF20_BAD_TOKEN'; end if;
  if not v_me.is_host then raise exception 'DF20_HOST_ONLY'; end if;

  if v_room.host_profile_id is null
     or not public.df20_premium_active(v_room.host_profile_id) then
    raise exception 'DF20_PREMIUM_REQUIRED';
  end if;

  v_tok := v_room.obs_token;
  if v_tok is null then
    v_tok := gen_random_uuid();
    update public.rooms set obs_token = v_tok where id = v_room.id;
  end if;
  return jsonb_build_object('obs_token', v_tok);
end $$;
grant execute on function public.mint_obs_token(text, uuid) to anon, authenticated;

-- rotate: the old browser source goes dark, which is the point
create or replace function public.rotate_obs_token(p_code text, p_token uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_me public.players;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  select * into v_me from public.players
   where room_id = v_room.id and session_token = p_token;
  if not found then raise exception 'DF20_BAD_TOKEN'; end if;
  if not v_me.is_host then raise exception 'DF20_HOST_ONLY'; end if;
  if v_room.host_profile_id is null
     or not public.df20_premium_active(v_room.host_profile_id) then
    raise exception 'DF20_PREMIUM_REQUIRED';
  end if;

  update public.rooms set obs_token = null where id = v_room.id;
  return public.mint_obs_token(p_code, p_token);
end $$;
grant execute on function public.rotate_obs_token(text, uuid) to anon, authenticated;

-- ── the OBS read path. No login, no code, no way back to an action. ───────
create or replace function public.get_obs_state(p_obs_token uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_id uuid; v_state jsonb;
begin
  if p_obs_token is null then return null; end if;
  select id into v_id from public.rooms where obs_token = p_obs_token;
  if not found then return null; end if;

  v_state := public.df20_public_state(v_id);
  -- the room code is the capability that lets someone take an empty seat.
  -- A browser source URL ends up pasted into OBS, screenshared and posted;
  -- it has no reason to carry the code and every reason not to.
  return jsonb_set(v_state, '{room}', (v_state->'room') - 'code');
end $$;
grant execute on function public.get_obs_state(uuid) to anon, authenticated;

-- ── the audience vote ─────────────────────────────────────────────────────
-- voter_key is a random id in an httpOnly cookie set by our own route
-- handler, so refreshing, opening a second tab or editing localStorage all
-- land on the same row. The unique constraint is the enforcement; the cookie
-- is only how the browser is recognised.
create table if not exists public.audience_votes (
  room_id          uuid not null references public.rooms(id) on delete cascade,
  voter_key        text not null,
  winner_player_id uuid not null references public.players(id) on delete cascade,
  created_at       timestamptz not null default now(),
  primary key (room_id, voter_key)
);
create index if not exists audience_votes_room_idx on public.audience_votes(room_id);

alter table public.audience_votes enable row level security;
revoke all on public.audience_votes from anon, authenticated;

create or replace function public.df20_audience_tally(p_room uuid)
returns jsonb language sql stable security definer
set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'total', (select count(*) from public.audience_votes where room_id = p_room),
    'by_player', coalesce((
      select jsonb_object_agg(pl.id::text, coalesce(c.n, 0))
        from public.players pl
        left join (select winner_player_id, count(*) as n
                     from public.audience_votes where room_id = p_room
                    group by winner_player_id) c on c.winner_player_id = pl.id
       where pl.room_id = p_room), '{}'::jsonb));
$$;
revoke all on function public.df20_audience_tally(uuid) from anon, authenticated;

-- the finished board a stranger votes on. tally is null until they have.
create or replace function public.get_audience_state(p_code text, p_voter_key text)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_mine uuid;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code));
  if not found then return jsonb_build_object('status','gone'); end if;
  if v_room.status <> 'complete' then
    return jsonb_build_object('status','not_finished', 'title', v_room.title);
  end if;

  select winner_player_id into v_mine from public.audience_votes
   where room_id = v_room.id and voter_key = coalesce(p_voter_key, '');

  return jsonb_build_object(
    'status', 'open',
    'title', v_room.title,
    'category', v_room.category_name,
    'roster_size', v_room.roster_size,
    'starting_cents', v_room.starting_bankroll_cents,
    'players', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pl.id, 'seat', pl.seat, 'name', pl.display_name,
               'leftover_cents', pl.bankroll_cents,
               'spent_cents', coalesce((select sum(r.price_cents) from public.roster_entries r
                                         where r.room_id = v_room.id and r.player_id = pl.id), 0),
               'rows', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'pick', r.pick_number, 'item', r.item_name,
                          'price_cents', r.price_cents, 'gifted', r.gifted)
                        order by r.pick_number)
                   from public.roster_entries r
                  where r.room_id = v_room.id and r.player_id = pl.id), '[]'::jsonb))
             order by pl.seat)
        from public.players pl where pl.room_id = v_room.id), '[]'::jsonb),
    'your_vote', v_mine,
    -- THE BLIND RULE, enforced in the database. A viewer who has not voted
    -- is not told the numbers, so hiding them in the UI is not what is
    -- keeping the vote blind.
    'tally', case when v_mine is null then null
                  else public.df20_audience_tally(v_room.id) end);
end $$;
grant execute on function public.get_audience_state(text, text) to anon, authenticated;

create or replace function public.cast_audience_vote(
  p_code text, p_voter_key text, p_winner_player_id uuid
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_key text;
begin
  v_key := public.df20_clean_text(p_voter_key, 64);
  if length(v_key) < 16 then raise exception 'DF20_BAD_VOTE'; end if;

  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  if v_room.status <> 'complete' then raise exception 'DF20_NOT_COMPLETE'; end if;
  if not exists (select 1 from public.players
                  where id = p_winner_player_id and room_id = v_room.id)
    then raise exception 'DF20_BAD_VOTE'; end if;

  -- second guard behind the unique key: one browser churning cookies still
  -- cannot pour votes into the same room
  if not public.df20_rate_limit('aud_vote', v_key, 20, 3600) then
    raise exception 'DF20_RATE_LIMITED';
  end if;

  -- FIRST vote stands. A second attempt is not an error and does not change
  -- anything: the viewer simply sees the tally they already earned.
  insert into public.audience_votes (room_id, voter_key, winner_player_id)
  values (v_room.id, v_key, p_winner_player_id)
  on conflict (room_id, voter_key) do nothing;

  begin
    perform realtime.send(
      public.df20_audience_tally(v_room.id), 'audience',
      'room:' || v_room.id::text, false);
  exception when others then null;   -- the hub polls as well
  end;

  return public.get_audience_state(p_code, v_key);
end $$;
grant execute on function public.cast_audience_vote(text, text, uuid) to anon, authenticated;

-- the host's own hub: always shows the numbers, never needs to have voted
create or replace function public.get_audience_hub(p_code text, p_token uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_me public.players;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code));
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  select * into v_me from public.players
   where room_id = v_room.id and session_token = p_token;
  if not found then raise exception 'DF20_BAD_TOKEN'; end if;

  return jsonb_build_object(
    'complete', v_room.status = 'complete',
    'tally', public.df20_audience_tally(v_room.id),
    'players', coalesce((select jsonb_agg(jsonb_build_object(
                                  'id', pl.id, 'seat', pl.seat, 'name', pl.display_name)
                                order by pl.seat)
                           from public.players pl where pl.room_id = v_room.id), '[]'::jsonb));
end $$;
grant execute on function public.get_audience_hub(text, uuid) to anon, authenticated;

-- ─────────── 0019_billing.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0019 · billing writes, and the manual grant
--
-- Stripe never talks to Postgres. Our webhook route verifies Stripe's
-- signature, works out what changed, and calls ONE function here with a
-- shared secret. That keeps the service-role key out of the project (see the
-- README: it is not used by this app and must not be added) while still
-- letting a request with no user session write to somebody's profile.
--
-- The secret is generated by this migration, lives in df20_config, and is
-- copied into DF20_BILLING_SECRET on the server. It can only move a
-- subscription date. Leaking it costs a wrongly-granted month, not a
-- database.
-- ═══════════════════════════════════════════════════════════════════════════

insert into public.df20_config (key, value)
values ('billing_write_secret', encode(gen_random_bytes(24), 'hex'))
on conflict (key) do nothing;

-- Stripe retries. Extending a Game Night Pass by 24 hours is the one
-- operation here that is not naturally idempotent, so every event is
-- recorded by id and a repeat is a no-op.
create table if not exists public.billing_events (
  event_id     text primary key,
  kind         text,
  processed_at timestamptz not null default now()
);
alter table public.billing_events enable row level security;
revoke all on public.billing_events from anon, authenticated;

-- ── the only write path Stripe has ────────────────────────────────────────
create or replace function public.df20_apply_billing_event(
  p_secret          text,
  p_event_id        text,
  p_user_id         uuid,
  p_customer_id     text,
  p_subscription_id text,
  p_status          text,
  p_premium_until   timestamptz,
  p_source          text,
  p_extend_hours    int default null
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_expected text; v_id uuid; v_until timestamptz; v_rows int;
begin
  select value into v_expected from public.df20_config where key = 'billing_write_secret';
  if v_expected is null or p_secret is null or p_secret <> v_expected then
    raise exception 'DF20_NOT_AUTHORISED';
  end if;

  if p_source is not null and p_source not in
     ('stripe_subscription','admin_grant','game_night_pass') then
    raise exception 'DF20_BAD_SOURCE';
  end if;

  -- who this is about: the id we put in the checkout session first, the
  -- customer we stored second. Never an email — those change.
  if p_user_id is not null then
    select id into v_id from public.profiles where id = p_user_id;
  end if;
  if v_id is null and p_customer_id is not null then
    select id into v_id from public.profiles where stripe_customer_id = p_customer_id;
  end if;
  if v_id is null then
    return jsonb_build_object('matched', false);
  end if;

  if p_event_id is not null then
    insert into public.billing_events (event_id, kind)
    values (p_event_id, coalesce(p_source, 'stripe'))
    on conflict (event_id) do nothing;
    get diagnostics v_rows = row_count;
    if v_rows = 0 then
      return jsonb_build_object('matched', true, 'duplicate', true);
    end if;
  end if;

  if p_extend_hours is not null then
    -- a pass bought while a subscription is running adds to the end of it,
    -- rather than throwing away time already paid for
    select greatest(coalesce(premium_until, now()), now())
             + make_interval(hours => p_extend_hours)
      into v_until from public.profiles where id = v_id;
  else
    v_until := p_premium_until;
  end if;

  update public.profiles
     set premium_until          = coalesce(v_until, premium_until),
         premium_source         = coalesce(p_source, premium_source),
         subscription_status    = coalesce(p_status, subscription_status),
         stripe_customer_id     = coalesce(p_customer_id, stripe_customer_id),
         stripe_subscription_id = coalesce(p_subscription_id, stripe_subscription_id),
         updated_at             = now()
   where id = v_id;

  return jsonb_build_object('matched', true, 'user_id', v_id,
                            'premium_until', to_jsonb(v_until));
end $$;
revoke all on function public.df20_apply_billing_event(text,text,uuid,text,text,text,timestamptz,text,int)
  from anon, authenticated;

-- revoke outright: a subscription deleted mid-period, a chargeback
create or replace function public.df20_revoke_premium(
  p_secret text, p_event_id text, p_customer_id text, p_status text
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_expected text; v_id uuid;
begin
  select value into v_expected from public.df20_config where key = 'billing_write_secret';
  if v_expected is null or p_secret is null or p_secret <> v_expected then
    raise exception 'DF20_NOT_AUTHORISED';
  end if;

  select id into v_id from public.profiles where stripe_customer_id = p_customer_id;
  if v_id is null then return jsonb_build_object('matched', false); end if;

  if p_event_id is not null then
    insert into public.billing_events (event_id, kind) values (p_event_id, 'revoke')
    on conflict (event_id) do nothing;
  end if;

  -- an admin grant is not Stripe's to cancel
  update public.profiles
     set premium_until = case when premium_source = 'admin_grant' then premium_until else now() end,
         subscription_status = coalesce(p_status, 'canceled'),
         updated_at = now()
   where id = v_id;
  return jsonb_build_object('matched', true, 'user_id', v_id);
end $$;
revoke all on function public.df20_revoke_premium(text,text,text,text) from anon, authenticated;

-- what the checkout route needs before it calls Stripe
create or replace function public.df20_billing_profile(p_secret text, p_user_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_expected text; v_p public.profiles;
begin
  select value into v_expected from public.df20_config where key = 'billing_write_secret';
  if v_expected is null or p_secret is null or p_secret <> v_expected then
    raise exception 'DF20_NOT_AUTHORISED';
  end if;
  select * into v_p from public.profiles where id = p_user_id;
  if not found then return jsonb_build_object('found', false); end if;
  return jsonb_build_object('found', true, 'email', v_p.email,
                            'customer_id', v_p.stripe_customer_id,
                            'premium_until', to_jsonb(v_p.premium_until));
end $$;
revoke all on function public.df20_billing_profile(text, uuid) from anon, authenticated;

-- ── the manual grant, and the small admin screen over it ──────────────────
-- Nobody is an admin until a uuid is put in this row BY HAND. With the row
-- absent, which is how it ships, df20_is_admin() is false for every caller
-- including the person who wrote this, and /admin renders nothing.
create or replace function public.df20_is_admin()
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.df20_config c,
                  unnest(string_to_array(c.value, ',')) u
     where c.key = 'admin_user_ids'
       and (select auth.uid()) is not null
       and btrim(u) = (select auth.uid())::text)
$$;
grant execute on function public.df20_is_admin() to anon, authenticated;

create or replace function public.admin_list_profiles(p_query text default null)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_q text;
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  v_q := lower(btrim(coalesce(p_query, '')));

  return coalesce((
    select jsonb_agg(x order by x->>'created_at' desc) from (
      select jsonb_build_object(
               'id', p.id, 'email', p.email, 'display_name', p.display_name,
               'created_at', p.created_at,
               'premium_until', p.premium_until,
               'premium_source', p.premium_source,
               'subscription_status', p.subscription_status,
               'active', coalesce(p.premium_until > now(), false)) as x
        from public.profiles p
       where v_q = ''
          or lower(coalesce(p.email, '')) like '%' || v_q || '%'
          or lower(coalesce(p.display_name, '')) like '%' || v_q || '%'
       order by p.created_at desc
       limit 100) s), '[]'::jsonb);
end $$;
grant execute on function public.admin_list_profiles(text) to authenticated;

-- p_days <= 0 revokes. Everything else is identical to what a paid
-- subscription writes, which is the whole point: the app cannot tell them
-- apart because it only ever reads premium_until.
create or replace function public.admin_set_premium(p_user_id uuid, p_days int)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_until timestamptz;
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  if p_days is null then raise exception 'DF20_BAD_INPUT'; end if;

  if p_days <= 0 then
    update public.profiles
       set premium_until = null, premium_source = null,
           subscription_status = null, updated_at = now()
     where id = p_user_id;
    return jsonb_build_object('user_id', p_user_id, 'active', false);
  end if;

  v_until := now() + make_interval(days => least(p_days, 3650));
  update public.profiles
     set premium_until = v_until, premium_source = 'admin_grant',
         subscription_status = 'admin', updated_at = now()
   where id = p_user_id;
  return jsonb_build_object('user_id', p_user_id, 'active', true,
                            'premium_until', to_jsonb(v_until));
end $$;
grant execute on function public.admin_set_premium(uuid, int) to authenticated;

-- ─────────── 0020_selfcheck.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0020 · what must exist for v6 to work
--
-- Same job as 0013, extended. plpgsql still does not validate function
-- bodies at creation, so a half-applied bundle still reports success and
-- still fails on a real click. This is the thing that makes it fail loudly
-- here instead. KEEP IT UPDATED WHEN YOU ADD AN RPC.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.df20_selfcheck()
returns text language plpgsql as $$
declare
  v_missing text[] := '{}';
  f text;
  v_required text[] := array[
    -- money and game loop
    'public.df20_max_legal_bid(integer,integer,integer)',
    'public.df20_open_slots(uuid,uuid)',
    'public.df20_opponent(uuid,uuid)',
    'public.df20_can_outbid(uuid,uuid,integer)',
    'public.df20_is_broke(uuid,uuid)',
    'public.df20_add_to_roster(uuid,uuid,text,integer,boolean)',
    'public.df20_resolve_lot(uuid,text)',
    'public.df20_resolve_gift(uuid,uuid)',
    'public.df20_reveal_next(uuid)',
    'public.df20_advance(uuid)',
    'public.df20_public_state(uuid)',
    'public.df20_broadcast(uuid)',
    'public.df20_touch(uuid)',
    'public.df20_gen_code()',
    -- text safety
    'public.df20_clean_text(text,integer)',
    'public.df20_clean_logo_url(text)',
    -- categories
    'public.df20_norm_category(text)',
    'public.df20_token_overlap(text,text)',
    'public.df20_match_category(text,integer)',
    'public.df20_fill_pool(uuid,text,uuid)',
    'public.df20_seed_category(text,text[])',
    'public.df20_cache_wikipedia(text,text,text,text[])',
    'public.df20_looks_like_person(text)',
    'public.df20_person_oriented_category(text)',
    'public.list_free_categories()',
    -- abuse control and accounts
    'public.df20_rate_limit(text,text,integer,integer)',
    'public.df20_ensure_profile()',
    'public.df20_require_verified()',
    -- the client API
    'public.create_room(text,integer,integer,integer,integer,text,boolean,integer,text,text,text,uuid)',
    'public.create_pending_room()',
    'public.get_setup_state(uuid)',
    'public.setup_lock_items(uuid,text,text[],integer,integer,integer,integer,integer)',
    'public.join_room(text,text)',
    'public.start_draft(text,uuid)',
    'public.offer_decide(text,uuid,text)',
    'public.place_bid(text,uuid,integer,integer)',
    'public.pass_turn(text,uuid,integer)',
    'public.expire_turn(text)',
    'public.submit_vote(text,uuid,uuid)',
    'public.get_room_state(text)',
    'public.offer_library_optin(uuid)',
    'public.submit_library_optin(uuid,boolean)',
    -- v6: profiles, decks, premium
    'public.df20_premium_active(uuid)',
    'public.my_premium()',
    'public.my_profile_stats()',
    'public.df20_manual_winner(uuid)',
    'public.save_export_style(boolean,text,text,text)',
    'public.df20_export_style(text)',
    'public.save_room_deck(text,text)',
    'public.my_decks()',
    'public.delete_deck(uuid)',
    -- v6: content tab
    'public.mint_obs_token(text,uuid)',
    'public.rotate_obs_token(text,uuid)',
    'public.get_obs_state(uuid)',
    'public.df20_audience_tally(uuid)',
    'public.get_audience_state(text,text)',
    'public.cast_audience_vote(text,text,uuid)',
    'public.get_audience_hub(text,uuid)',
    -- v6: billing
    'public.df20_apply_billing_event(text,text,uuid,text,text,text,timestamptz,text,integer)',
    'public.df20_revoke_premium(text,text,text,text)',
    'public.df20_billing_profile(text,uuid)',
    'public.df20_is_admin()',
    'public.admin_list_profiles(text)',
    'public.admin_set_premium(uuid,integer)'
  ];
  v_tables text[] := array['rooms','players','room_deck','room_pool','roster_entries',
                           'lots','bid_events','votes','rate_limits','category_library',
                           'category_library_items','category_library_aliases',
                           'wikipedia_cache','wikipedia_cache_items','profiles','templates',
                           'df20_config','user_categories','user_category_items',
                           'audience_votes','billing_events'];
  v_columns text[] := array['profiles.premium_until','profiles.premium_source',
                            'profiles.subscription_status','profiles.stripe_customer_id',
                            'profiles.export_watermark','rooms.obs_token'];
  t text; c text;
begin
  foreach f in array v_required loop
    if to_regprocedure(f) is null then v_missing := v_missing || f; end if;
  end loop;
  foreach t in array v_tables loop
    if to_regclass('public.' || t) is null then v_missing := v_missing || ('table ' || t); end if;
  end loop;
  foreach c in array v_columns loop
    if not exists (select 1 from information_schema.columns
                    where table_schema = 'public'
                      and table_name = split_part(c, '.', 1)
                      and column_name = split_part(c, '.', 2))
    then v_missing := v_missing || ('column ' || c); end if;
  end loop;

  if coalesce(array_length(v_missing, 1), 0) > 0 then
    raise exception E'DF20_SELFCHECK_FAILED\nmissing:\n  %',
      array_to_string(v_missing, E'\n  ');
  end if;

  return format('ok - %s functions, %s tables and %s columns present',
                array_length(v_required, 1), array_length(v_tables, 1),
                array_length(v_columns, 1));
end $$;
revoke all on function public.df20_selfcheck() from anon, authenticated;

-- the watermark default is a product decision, so it is asserted, not assumed
do $$
declare v_default text;
begin
  select column_default into v_default from information_schema.columns
   where table_schema = 'public' and table_name = 'profiles'
     and column_name = 'export_watermark';
  if v_default is null or v_default not like 'true%' then
    raise exception 'DF20_WATERMARK_DEFAULT_WRONG: profiles.export_watermark defaults to %', v_default;
  end if;
end $$;

-- ─────────── 0021_timer.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0021 · a custom clock, and no clock at all
--
-- timer_seconds = 0 means NO LIMIT: the counter-bid window stays open until
-- somebody raises or passes. Everything else about the clock is unchanged.
--
-- The four functions below are reproduced from 0005 and 0010 BYTE FOR BYTE
-- except that every
--     now() + make_interval(secs => v_room.timer_seconds)
-- is now
--     public.df20_turn_deadline(v_room.timer_seconds)
-- which returns NULL at zero. No money rule, no validation and no state
-- transition is touched — the diff is one expression in four places, which is
-- the only reason it is safe to restate functions this important.
--
-- Everything downstream already treats a null deadline correctly, which is
-- why this works at all:
--   · place_bid's  "now() > v_lot.turn_expires_at + 400ms"  is NULL, and
--     plpgsql treats a NULL condition as false, so a bid is never late.
--   · expire_turn returns early on a null deadline, so the idempotent
--     expiry call is a no-op.
--   · df20_sweep_expired's "turn_expires_at < now() - 2s" never matches a
--     null, so the pg_cron backstop skips these rooms.
--   · the client's expiry driver bails on a null expires_at, so nothing is
--     scheduled in the browser either.
-- ═══════════════════════════════════════════════════════════════════════════

-- the whole feature, in one function
create or replace function public.df20_turn_deadline(p_seconds int)
returns timestamptz language sql stable as $$
  select case when coalesce(p_seconds, 0) <= 0
              then null
              else now() + make_interval(secs => p_seconds) end
$$;
revoke all on function public.df20_turn_deadline(int) from anon, authenticated;

-- ── the clock bound is now "0, or 3 to 300" ───────────────────────────────
do $$ begin
  alter table public.rooms drop constraint rooms_timer_seconds_check;
exception when undefined_object then null; end $$;
alter table public.rooms
  add constraint rooms_timer_seconds_check
  check (timer_seconds = 0 or (timer_seconds between 3 and 300));

-- ── df20_reveal_next ────────────────────────────────────────────────
create or replace function public.df20_reveal_next(p_room uuid)
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_room public.rooms; v_p1 public.players; v_p2 public.players;
  v_o1 int; v_o2 int; v_opener public.players; v_card record; v_lot uuid;
begin
  select * into v_room from public.rooms where id = p_room;
  select * into v_p1 from public.players where room_id = p_room and seat = 1;
  select * into v_p2 from public.players where room_id = p_room and seat = 2;
  v_o1 := public.df20_open_slots(p_room, v_p1.id);
  v_o2 := public.df20_open_slots(p_room, v_p2.id);

  if v_o1 = 0 and v_o2 = 0 then
    update public.rooms
       set phase = 'complete', status = 'complete',
           completed_at = coalesce(completed_at, now())
     where id = p_room;
    return;
  end if;

  if v_o1 > 0 and v_o2 > 0 then
    v_opener := case when v_room.opener_seat = 1 then v_p1 else v_p2 end;
  elsif v_o1 > 0 then v_opener := v_p1;
  else                v_opener := v_p2;
  end if;

  select d.position as pos, d.item_name as nm into v_card
    from public.room_deck d
   where d.room_id = p_room and d.revealed_at is null
   order by d.position limit 1;

  if not found then
    update public.rooms
       set phase = 'complete', status = 'complete',
           completed_at = coalesce(completed_at, now())
     where id = p_room;
    return;
  end if;

  update public.room_deck set revealed_at = now()
   where room_id = p_room and position = v_card.pos;

  insert into public.lots
    (room_id, item_name, opener_player_id, status,
     current_bid_cents, high_bidder_player_id, on_the_clock_player_id,
     turn_expires_at, turn_seq)
  values
    (p_room, v_card.nm, v_opener.id, 'offered',
     v_room.min_bid_cents, v_opener.id, v_opener.id,
     public.df20_turn_deadline(v_room.timer_seconds), 1)
  returning id into v_lot;

  insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
  values (p_room, v_lot, null, 'reveal', v_room.min_bid_cents, 1);

  update public.rooms set phase = 'offering' where id = p_room;
end $$;

-- ── offer_decide ────────────────────────────────────────────────
create or replace function public.offer_decide(p_code text, p_token uuid, p_choice text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_room public.rooms; v_me public.players; v_lot public.lots;
  v_opp uuid; v_max int; v_can_take boolean; v_can_give boolean;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  select * into v_me from public.players
   where room_id = v_room.id and session_token = p_token;
  if not found then raise exception 'DF20_BAD_TOKEN'; end if;

  select * into v_lot from public.lots
   where room_id = v_room.id and status = 'offered' for update;
  if not found then raise exception 'DF20_NO_LIVE_LOT'; end if;
  if v_room.phase <> 'offering' then raise exception 'DF20_WRONG_PHASE'; end if;
  if v_lot.opener_player_id is distinct from v_me.id
    then raise exception 'DF20_NOT_YOUR_TURN'; end if;

  v_opp := public.df20_opponent(v_room.id, v_me.id);
  v_max := public.df20_max_legal_bid(v_me.bankroll_cents, v_room.min_bid_cents,
                                     public.df20_open_slots(v_room.id, v_me.id));
  v_can_take := v_max >= v_room.min_bid_cents
                and public.df20_open_slots(v_room.id, v_me.id) > 0;
  v_can_give := public.df20_open_slots(v_room.id, v_opp) > 0
                and v_me.gives_used < v_room.gives_per_player;

  if p_choice = 'take' then
    if not v_can_take then raise exception 'DF20_CANNOT_AFFORD'; end if;

    insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
    values (v_room.id, v_lot.id, v_me.id, 'offer_take', v_room.min_bid_cents, v_lot.turn_seq);

    if public.df20_can_outbid(v_room.id, v_opp, v_room.min_bid_cents) then
      update public.lots
         set status = 'bidding', on_the_clock_player_id = v_opp,
             turn_expires_at = public.df20_turn_deadline(v_room.timer_seconds),
             turn_seq = turn_seq + 1
       where id = v_lot.id;
      update public.rooms set phase = 'bidding' where id = v_room.id;
    else
      perform public.df20_resolve_lot(v_lot.id, 'won');
    end if;

  elsif p_choice = 'give' then
    if public.df20_open_slots(v_room.id, v_opp) <= 0 then raise exception 'DF20_THEY_ARE_FULL'; end if;
    if v_me.gives_used >= v_room.gives_per_player then raise exception 'DF20_NO_GIVES_LEFT'; end if;
    perform public.df20_resolve_gift(v_lot.id, v_me.id);

  elsif p_choice = 'discard' then
    -- only legal when the opener genuinely cannot do anything else
    if v_can_take or v_can_give then raise exception 'DF20_MUST_TAKE_OR_GIVE'; end if;
    perform public.df20_discard_lot(v_lot.id);

  else
    raise exception 'DF20_BAD_CHOICE';
  end if;

  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);
  return public.df20_public_state(v_room.id);
end $$;

-- ── place_bid ────────────────────────────────────────────────
create or replace function public.place_bid(
  p_code text, p_token uuid, p_amount_cents int, p_expected_turn_seq int
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_me public.players; v_lot public.lots; v_opp uuid; v_max int;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  select * into v_me from public.players
   where room_id = v_room.id and session_token = p_token;
  if not found then raise exception 'DF20_BAD_TOKEN'; end if;
  select * into v_lot from public.lots
   where room_id = v_room.id and status = 'bidding' for update;
  if not found then raise exception 'DF20_NO_LIVE_LOT'; end if;

  if v_room.phase <> 'bidding'                       then raise exception 'DF20_WRONG_PHASE'; end if;
  if v_lot.on_the_clock_player_id is distinct from v_me.id
                                                     then raise exception 'DF20_NOT_YOUR_TURN'; end if;
  if v_lot.turn_seq <> p_expected_turn_seq           then raise exception 'DF20_STALE'; end if;
  if now() > v_lot.turn_expires_at + interval '400 milliseconds'
                                                     then raise exception 'DF20_EXPIRED'; end if;
  if p_amount_cents is null or p_amount_cents <= v_lot.current_bid_cents
                                                     then raise exception 'DF20_TOO_LOW'; end if;
  if public.df20_open_slots(v_room.id, v_me.id) <= 0 then raise exception 'DF20_ROSTER_FULL'; end if;

  -- HARD CAP + RESERVE RULE against the bankroll as it is RIGHT NOW
  v_max := public.df20_max_legal_bid(v_me.bankroll_cents, v_room.min_bid_cents,
                                     public.df20_open_slots(v_room.id, v_me.id));
  if p_amount_cents > v_me.bankroll_cents then raise exception 'DF20_OVER_BANKROLL'; end if;
  if p_amount_cents > v_max               then raise exception 'DF20_OVER_RESERVE'; end if;

  v_opp := public.df20_opponent(v_room.id, v_me.id);
  update public.lots
     set current_bid_cents = p_amount_cents, high_bidder_player_id = v_me.id,
         on_the_clock_player_id = v_opp,
         turn_expires_at = public.df20_turn_deadline(v_room.timer_seconds),
         turn_seq = turn_seq + 1
   where id = v_lot.id
  returning * into v_lot;

  insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
  values (v_room.id, v_lot.id, v_me.id, 'raise', p_amount_cents, v_lot.turn_seq);

  if not public.df20_can_outbid(v_room.id, v_opp, p_amount_cents) then
    perform public.df20_resolve_lot(v_lot.id, 'blocked_win');
  end if;

  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);
  return public.df20_public_state(v_room.id);
end $$;

-- ── expire_turn ────────────────────────────────────────────────
create or replace function public.expire_turn(p_code text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_lot public.lots; v_opener public.players;
        v_opp uuid; v_max int;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;

  select * into v_lot from public.lots
   where room_id = v_room.id and status in ('offered','bidding') for update;
  if not found then return public.df20_public_state(v_room.id); end if;
  if v_lot.turn_expires_at is null or now() <= v_lot.turn_expires_at then
    return public.df20_public_state(v_room.id);          -- not expired: no-op
  end if;

  if v_lot.status = 'offered' then
    -- Timing out on an offer defaults to TAKE: you are out the minimum bid, not
    -- a roster spot. It never auto-spends a give, because giving is a weapon
    -- with a budget and nobody should lose one by looking away.
    select * into v_opener from public.players where id = v_lot.opener_player_id;
    v_max := public.df20_max_legal_bid(v_opener.bankroll_cents, v_room.min_bid_cents,
                                       public.df20_open_slots(v_room.id, v_opener.id));
    if v_max >= v_room.min_bid_cents then
      insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
      values (v_room.id, v_lot.id, v_opener.id, 'offer_take', v_room.min_bid_cents, v_lot.turn_seq);

      v_opp := public.df20_opponent(v_room.id, v_opener.id);
      if public.df20_can_outbid(v_room.id, v_opp, v_room.min_bid_cents) then
        update public.lots
           set status = 'bidding', on_the_clock_player_id = v_opp,
               turn_expires_at = public.df20_turn_deadline(v_room.timer_seconds),
               turn_seq = turn_seq + 1
         where id = v_lot.id;
        update public.rooms set phase = 'bidding' where id = v_room.id;
      else
        perform public.df20_resolve_lot(v_lot.id, 'won');
      end if;
    else
      perform public.df20_discard_lot(v_lot.id);
    end if;
  else
    insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
    values (v_room.id, v_lot.id, v_lot.on_the_clock_player_id, 'timeout_pass',
            v_lot.current_bid_cents, v_lot.turn_seq);
    perform public.df20_resolve_lot(v_lot.id, 'won');
  end if;

  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);
  return public.df20_public_state(v_room.id);
end $$;


-- ── the two places a timer is validated ───────────────────────────────────
-- Both restated from 0017 / 0010 with one guard widened and nothing else
-- changed.

create or replace function public.create_room(
  p_title text, p_roster_size int, p_bankroll_cents int, p_min_bid_cents int,
  p_timer_seconds int, p_host_name text, p_is_private boolean default true,
  p_gives_per_player int default 2, p_brand_accent text default null,
  p_brand_logo_url text default null,
  p_pool_source text default 'builtin', p_pool_ref uuid default null
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_pl public.players; v_uid uuid; v_accent text; v_n int;
begin
  if coalesce(p_pool_source, 'builtin') in ('wikipedia','saved') then
    v_uid := public.df20_require_verified();
  else
    v_uid := public.df20_ensure_profile();   -- null when signed out, which is fine
  end if;

  if coalesce(p_pool_source, 'builtin') = 'saved' then
    if not exists (select 1 from public.user_categories
                    where id = p_pool_ref and owner_id = v_uid) then
      raise exception 'DF20_NOT_YOUR_DECK';
    end if;
  end if;

  p_title := public.df20_clean_text(p_title, 60);
  if length(p_title) = 0 then p_title := 'Football Draft'; end if;
  p_host_name := public.df20_clean_text(p_host_name, 24);
  if length(p_host_name) = 0 then raise exception 'DF20_BAD_NAME'; end if;

  if p_roster_size is null or p_roster_size < 1 or p_roster_size > 30
    then raise exception 'DF20_BAD_ROSTER_SIZE'; end if;
  if p_bankroll_cents is null or p_bankroll_cents < 0 or p_bankroll_cents > 10000000
    then raise exception 'DF20_BAD_BANKROLL'; end if;
  if p_min_bid_cents is null or p_min_bid_cents < 0 or p_min_bid_cents > 1000000
    then raise exception 'DF20_BAD_MIN_BID'; end if;
  -- 0 is the no-limit sentinel; 1 and 2 seconds are still nonsense
  if p_timer_seconds is null
     or not (p_timer_seconds = 0 or p_timer_seconds between 3 and 300)
    then raise exception 'DF20_BAD_TIMER'; end if;
  if p_gives_per_player is null or p_gives_per_player < 0 or p_gives_per_player > 30
    then raise exception 'DF20_BAD_GIVES'; end if;

  v_accent := public.df20_clean_text(p_brand_accent, 9);
  if v_accent = '' then v_accent := null; end if;
  if v_accent is not null and v_accent !~ '^#[0-9A-Fa-f]{6}$'
    then raise exception 'DF20_BAD_ACCENT'; end if;

  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, gives_per_player,
                            is_private, brand_accent, brand_logo_url, host_profile_id)
  values (public.df20_gen_code(), p_title, p_roster_size, p_bankroll_cents,
          p_min_bid_cents, p_timer_seconds, p_gives_per_player,
          coalesce(p_is_private, true), v_accent,
          public.df20_clean_logo_url(p_brand_logo_url), v_uid)
  returning * into v_room;

  v_n := public.df20_fill_pool(v_room.id, coalesce(p_pool_source, 'builtin'), p_pool_ref);
  if v_n < p_roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;

  insert into public.players (room_id, seat, display_name, bankroll_cents, is_host, profile_id)
  values (v_room.id, 1, p_host_name, p_bankroll_cents, true, v_uid)
  returning * into v_pl;

  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code,
                            'player_id', v_pl.id, 'session_token', v_pl.session_token,
                            'seat', 1, 'pool_size', v_n);
end $$;
grant execute on function public.create_room(text,int,int,int,int,text,boolean,int,text,text,text,uuid) to anon, authenticated;

create or replace function public.setup_lock_items(
  p_setup_token uuid, p_category text, p_items text[],
  p_roster_size int, p_bankroll_cents int, p_min_bid_cents int,
  p_timer_seconds int, p_gives_per_player int default 2
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; s text; v_clean text; v_n int; v_result uuid; v_code text;
begin
  select * into v_room from public.rooms where setup_token = p_setup_token for update;
  if not found then raise exception 'DF20_SETUP_LINK_SPENT'; end if;
  if v_room.setup_expires_at < now() then raise exception 'DF20_SETUP_LINK_EXPIRED'; end if;

  p_category := public.df20_clean_text(p_category, 60);
  if length(p_category) = 0 then raise exception 'DF20_BAD_CATEGORY'; end if;

  if p_roster_size is null or p_roster_size < 1 or p_roster_size > 30
    then raise exception 'DF20_BAD_ROSTER_SIZE'; end if;
  if p_bankroll_cents is null or p_bankroll_cents < 0 or p_bankroll_cents > 10000000
    then raise exception 'DF20_BAD_BANKROLL'; end if;
  if p_min_bid_cents is null or p_min_bid_cents < 0 or p_min_bid_cents > 1000000
    then raise exception 'DF20_BAD_MIN_BID'; end if;
  -- 0 is the no-limit sentinel; 1 and 2 seconds are still nonsense
  if p_timer_seconds is null
     or not (p_timer_seconds = 0 or p_timer_seconds between 3 and 300)
    then raise exception 'DF20_BAD_TIMER'; end if;

  -- sanitise, length-check and de-duplicate case-insensitively
  foreach s in array coalesce(p_items, '{}'::text[]) loop
    v_clean := public.df20_clean_text(s, 60);
    if length(v_clean) >= 1 then
      if exists (select 1 from public.room_pool
                  where room_id = v_room.id and lower(name) = lower(v_clean)) then
        raise exception 'DF20_DUPLICATE_ITEM';
      end if;
      insert into public.room_pool (room_id, name) values (v_room.id, v_clean);
    end if;
  end loop;

  select count(*) into v_n from public.room_pool where room_id = v_room.id;
  if v_n < p_roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;
  if v_n > 500 then raise exception 'DF20_POOL_TOO_BIG'; end if;

  v_code   := public.df20_gen_code();
  v_result := gen_random_uuid();

  update public.rooms
     set code = v_code, title = p_category, category_name = p_category,
         roster_size = p_roster_size, starting_bankroll_cents = p_bankroll_cents,
         min_bid_cents = p_min_bid_cents, timer_seconds = p_timer_seconds,
         gives_per_player = coalesce(p_gives_per_player, 2),
         pool_source = 'manual',
         setup_locked_at = now(),
         setup_token = null,             -- the link is GONE, not read-only
         setup_result_token = v_result
   where id = v_room.id;

  return jsonb_build_object('code', v_code, 'item_count', v_n,
                            'setup_result_token', v_result);
end $$;
grant execute on function public.setup_lock_items(uuid,text,text[],int,int,int,int,int) to anon, authenticated;

-- ─────────── 0022_scouting.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0022 · the Scouting Report
--
-- Four numbers describing HOW somebody drafts, aggregated from what the game
-- already writes down. Nothing new is tracked and nothing new is recorded:
--
--   roster_entries  what you won, what you paid, whether it was a gift
--   bid_events      every raise, with who made it
--   lots            who ended up winning each one
--   players         the bankroll you finished with
--   rooms           the minimum bid and starting bankroll that give the
--                   other four numbers a scale
--
-- FREE accounts see the last 5 completed drafts. PREMIUM sees everything.
-- That window is applied HERE, not in the UI, because the anon key is public.
--
-- Gifted cards are excluded from Sniper and Whale. A card handed to you for
-- nothing is not a purchase and says nothing about how you bid; leaving them
-- in would make a player who was dumped on look like a bargain hunter.
-- They stay in the roster counts, which is where they belong.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.my_scouting_report()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_uid uuid; v_premium boolean; v_limit int; v_total int;
  v_drafts int; v_bought int; v_gifts int; v_snipes int; v_lost_raises int;
  v_avg_price numeric; v_avg_leftover numeric; v_avg_leftover_pct numeric;
  v_even_price numeric; v_sniper_pct numeric; v_raises_per_draft numeric;
  v_s_sniper int; v_s_whale int; v_s_instigator int; v_s_hoarder int;
  v_title text; v_top int; v_second int;
begin
  v_uid := auth.uid();
  if v_uid is null then return jsonb_build_object('signed_in', false); end if;

  v_premium := public.df20_premium_active(v_uid);
  -- null means "no limit" to Postgres, which is exactly what premium buys
  v_limit := case when v_premium then null else 5 end;

  select count(*) into v_total
    from public.players p join public.rooms r on r.id = p.room_id
   where p.profile_id = v_uid and r.status = 'complete';

  -- One statement, no temp table: PostgREST runs a `stable` function inside a
  -- READ ONLY transaction, where creating one would fail.
  with picked as (
    select p.id as player_id, p.room_id,
           p.bankroll_cents as leftover, r.min_bid_cents as min_bid,
           r.starting_bankroll_cents as starting, r.roster_size as roster
      from public.players p
      join public.rooms r on r.id = p.room_id
     where p.profile_id = v_uid and r.status = 'complete'
     order by r.completed_at desc nulls last
     limit v_limit
  ),
  per_draft as (
    select k.leftover, k.starting, k.roster,
           (select count(*) from public.roster_entries e
             where e.room_id = k.room_id and e.player_id = k.player_id
               and not e.gifted) as bought,
           (select count(*) from public.roster_entries e
             where e.room_id = k.room_id and e.player_id = k.player_id
               and e.gifted) as gifts,
           (select coalesce(sum(e.price_cents), 0) from public.roster_entries e
             where e.room_id = k.room_id and e.player_id = k.player_id) as spend,
           -- THE SNIPER: bought at exactly the room's minimum
           (select count(*) from public.roster_entries e
             where e.room_id = k.room_id and e.player_id = k.player_id
               and not e.gifted and e.price_cents = k.min_bid) as snipes,
           -- THE INSTIGATOR: a raise you made on a lot somebody else won.
           -- Every raise counts, not every lot: pushing the same card three
           -- times and walking away is three acts of instigation.
           (select count(*) from public.bid_events b
              join public.lots l on l.id = b.lot_id
             where b.room_id = k.room_id and b.player_id = k.player_id
               and b.action = 'raise'
               and l.winner_player_id is distinct from k.player_id) as lost_raises
      from picked k
  )
  select count(*), coalesce(sum(bought), 0), coalesce(sum(gifts), 0),
         coalesce(sum(snipes), 0), coalesce(sum(lost_raises), 0),
         -- THE WHALE: average price per card BOUGHT, averaged per draft so
         -- one twelve-slot marathon does not drown out ten short games
         avg(case when bought > 0 then spend::numeric / bought end),
         avg(leftover),
         avg(case when starting > 0 then 100.0 * leftover / starting end),
         avg(case when roster > 0 then starting::numeric / roster end)
    into v_drafts, v_bought, v_gifts, v_snipes, v_lost_raises,
         v_avg_price, v_avg_leftover, v_avg_leftover_pct, v_even_price
    from per_draft;

  if v_drafts = 0 then
    return jsonb_build_object('signed_in', true, 'drafts', 0,
      'window', jsonb_build_object('premium', v_premium, 'counted', 0,
                                   'total', v_total, 'cap', v_limit));
  end if;

  v_sniper_pct := case when v_bought > 0 then 100.0 * v_snipes / v_bought else 0 end;
  v_raises_per_draft := v_lost_raises::numeric / v_drafts;

  -- ── the four axes, all 0-100 so they can share one chart ───────────────
  -- Sniper and Hoarder are already percentages of something real. Whale and
  -- Instigator need a scale, so each is pinned to a defensible landmark:
  --   Whale       100 = paying twice the even split (bankroll / roster)
  --   Instigator  100 = five losing raises per draft
  v_s_sniper     := least(100, greatest(0, round(v_sniper_pct)))::int;
  v_s_whale      := least(100, greatest(0, round(
                      case when coalesce(v_even_price, 0) > 0
                           then 50.0 * coalesce(v_avg_price, 0) / v_even_price
                           else 0 end)))::int;
  v_s_instigator := least(100, greatest(0, round(v_raises_per_draft * 20)))::int;
  v_s_hoarder    := least(100, greatest(0, round(coalesce(v_avg_leftover_pct, 0))))::int;

  -- ── the title ──────────────────────────────────────────────────────────
  -- Deliberately hard to earn: two drafts of tape minimum, the leading axis
  -- has to clear 40, and it has to be 8 clear of the next one. A title that
  -- everybody has is not a title.
  select max(v), (array_agg(v order by v desc))[2]
    into v_top, v_second
    from unnest(array[v_s_sniper, v_s_whale, v_s_instigator, v_s_hoarder]) v;

  if v_drafts < 2 then
    v_title := 'unread';
  elsif v_top < 40 or (v_top - coalesce(v_second, 0)) < 8 then
    v_title := 'allrounder';
  elsif v_top = v_s_sniper     then v_title := 'sniper';
  elsif v_top = v_s_whale      then v_title := 'whale';
  elsif v_top = v_s_instigator then v_title := 'instigator';
  else                              v_title := 'hoarder';
  end if;

  return jsonb_build_object(
    'signed_in', true,
    'drafts', v_drafts,
    'title', v_title,
    'window', jsonb_build_object('premium', v_premium, 'counted', v_drafts,
                                 'total', v_total, 'cap', v_limit),
    'axes', jsonb_build_array(
      jsonb_build_object('key','sniper','label','Sniper','score',v_s_sniper,
        'raw', round(v_sniper_pct)::int, 'unit','%',
        'note','bought at the minimum'),
      jsonb_build_object('key','whale','label','Whale','score',v_s_whale,
        'raw', round(coalesce(v_avg_price, 0))::int, 'unit','cents',
        'note','average price per card bought'),
      jsonb_build_object('key','instigator','label','Instigator','score',v_s_instigator,
        'raw', v_lost_raises, 'unit','raises',
        'note','raises on cards somebody else won'),
      jsonb_build_object('key','hoarder','label','Hoarder','score',v_s_hoarder,
        'raw', round(coalesce(v_avg_leftover, 0))::int, 'unit','cents',
        'note','average bankroll left at the end')),
    'totals', jsonb_build_object(
      'cards_bought', v_bought, 'cards_gifted', v_gifts,
      'min_bid_buys', v_snipes, 'losing_raises', v_lost_raises,
      'avg_price_cents', round(coalesce(v_avg_price, 0))::int,
      'avg_leftover_cents', round(coalesce(v_avg_leftover, 0))::int));
end $$;
grant execute on function public.my_scouting_report() to authenticated;

-- ─────────── 0023_content_mode.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0023 · Content Creator is a property of the room
--
-- It used to be a tab you could find inside a room you had already started.
-- It is now a decision made at creation, stored on the room, and never
-- changed afterwards — because it decides the entire layout, and a layout
-- that can flip mid-draft is a layout that flips while somebody is live.
--
-- 'creator' requires active premium, checked HERE. The setup screen shows a
-- padlock, but the setup screen is a React component and this is the gate.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.rooms
  add column if not exists content_mode text not null default 'standard';

do $$ begin
  alter table public.rooms add constraint rooms_content_mode_chk
    check (content_mode in ('standard','creator'));
exception when duplicate_object then null; end $$;

-- ── create_room, now mode-aware ───────────────────────────────────────────
-- Every earlier signature has to go first. The new one adds a defaulted
-- argument, and leaving an old overload standing makes a positional call
-- ambiguous rather than resolving to the newest definition — the exact trap
-- 0010 documents.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'create_room'
  loop
    execute 'drop function if exists ' || r.sig || ' cascade';
  end loop;
end $$;

create or replace function public.create_room(
  p_title text, p_roster_size int, p_bankroll_cents int, p_min_bid_cents int,
  p_timer_seconds int, p_host_name text, p_is_private boolean default true,
  p_gives_per_player int default 2, p_brand_accent text default null,
  p_brand_logo_url text default null,
  p_pool_source text default 'builtin', p_pool_ref uuid default null,
  p_content_mode text default 'standard'
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_pl public.players; v_uid uuid; v_accent text; v_n int;
begin
  if coalesce(p_pool_source, 'builtin') in ('wikipedia','saved') then
    v_uid := public.df20_require_verified();
  else
    v_uid := public.df20_ensure_profile();   -- null when signed out, which is fine
  end if;

  if coalesce(p_pool_source, 'builtin') = 'saved' then
    if not exists (select 1 from public.user_categories
                    where id = p_pool_ref and owner_id = v_uid) then
      raise exception 'DF20_NOT_YOUR_DECK';
    end if;
  end if;

  -- CONTENT CREATOR is chosen here, at creation, and never changes. The
  -- room's whole layout is decided by this column, so letting it be flipped
  -- mid-draft would mean re-laying-out a board somebody is streaming.
  p_content_mode := coalesce(nullif(btrim(lower(p_content_mode)), ''), 'standard');
  if p_content_mode not in ('standard', 'creator') then
    raise exception 'DF20_BAD_CONTENT_MODE';
  end if;
  if p_content_mode = 'creator'
     and (v_uid is null or not public.df20_premium_active(v_uid)) then
    raise exception 'DF20_PREMIUM_REQUIRED';
  end if;

  p_title := public.df20_clean_text(p_title, 60);
  if length(p_title) = 0 then p_title := 'Football Draft'; end if;
  p_host_name := public.df20_clean_text(p_host_name, 24);
  if length(p_host_name) = 0 then raise exception 'DF20_BAD_NAME'; end if;

  if p_roster_size is null or p_roster_size < 1 or p_roster_size > 30
    then raise exception 'DF20_BAD_ROSTER_SIZE'; end if;
  if p_bankroll_cents is null or p_bankroll_cents < 0 or p_bankroll_cents > 10000000
    then raise exception 'DF20_BAD_BANKROLL'; end if;
  if p_min_bid_cents is null or p_min_bid_cents < 0 or p_min_bid_cents > 1000000
    then raise exception 'DF20_BAD_MIN_BID'; end if;
  -- 0 is the no-limit sentinel; 1 and 2 seconds are still nonsense
  if p_timer_seconds is null
     or not (p_timer_seconds = 0 or p_timer_seconds between 3 and 300)
    then raise exception 'DF20_BAD_TIMER'; end if;
  if p_gives_per_player is null or p_gives_per_player < 0 or p_gives_per_player > 30
    then raise exception 'DF20_BAD_GIVES'; end if;

  v_accent := public.df20_clean_text(p_brand_accent, 9);
  if v_accent = '' then v_accent := null; end if;
  if v_accent is not null and v_accent !~ '^#[0-9A-Fa-f]{6}$'
    then raise exception 'DF20_BAD_ACCENT'; end if;

  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, gives_per_player,
                            is_private, brand_accent, brand_logo_url, host_profile_id,
                            content_mode)
  values (public.df20_gen_code(), p_title, p_roster_size, p_bankroll_cents,
          p_min_bid_cents, p_timer_seconds, p_gives_per_player,
          coalesce(p_is_private, true), v_accent,
          public.df20_clean_logo_url(p_brand_logo_url), v_uid,
          p_content_mode)
  returning * into v_room;

  v_n := public.df20_fill_pool(v_room.id, coalesce(p_pool_source, 'builtin'), p_pool_ref);
  if v_n < p_roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;

  insert into public.players (room_id, seat, display_name, bankroll_cents, is_host, profile_id)
  values (v_room.id, 1, p_host_name, p_bankroll_cents, true, v_uid)
  returning * into v_pl;

  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code,
                            'player_id', v_pl.id, 'session_token', v_pl.session_token,
                            'seat', 1, 'pool_size', v_n,
                            'content_mode', v_room.content_mode);
end $$;
grant execute on function public.create_room(text,int,int,int,int,text,boolean,int,text,text,text,uuid,text) to anon, authenticated;

-- ── the handoff room picks its mode up front too ──────────────────────────
-- The third party building the list decides the numbers; the HOST decides
-- how their own room looks, so the mode is set when the link is minted.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'create_pending_room'
  loop
    execute 'drop function if exists ' || r.sig || ' cascade';
  end loop;
end $$;

create or replace function public.create_pending_room(p_content_mode text default 'standard')
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_uid uuid;
begin
  v_uid := public.df20_require_verified();

  if not public.df20_rate_limit('pending_room', v_uid::text, 20, 3600) then
    raise exception 'DF20_RATE_LIMITED';
  end if;

  p_content_mode := coalesce(nullif(btrim(lower(p_content_mode)), ''), 'standard');
  if p_content_mode not in ('standard', 'creator') then
    raise exception 'DF20_BAD_CONTENT_MODE';
  end if;
  if p_content_mode = 'creator' and not public.df20_premium_active(v_uid) then
    raise exception 'DF20_PREMIUM_REQUIRED';
  end if;

  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, host_profile_id,
                            setup_token, setup_expires_at, pool_source, content_mode)
  values (null, 'Untitled draft', 5, 2000, 100, 15, v_uid,
          gen_random_uuid(), now() + interval '24 hours', 'manual', p_content_mode)
  returning * into v_room;

  return jsonb_build_object('setup_token', v_room.setup_token,
                            'expires_at', v_room.setup_expires_at,
                            'room_id', v_room.id,
                            'content_mode', v_room.content_mode);
end $$;
grant execute on function public.create_pending_room(text) to anon, authenticated;

-- ── the vote link resolves a code OR a room id ────────────────────────────
-- The canonical URL is /vote/<something>. A room code is what somebody can
-- read out on a stream, so that is what gets shared; the uuid resolves too,
-- because the spec asks for /vote/[room-id] and both should land.
create or replace function public.get_audience_state(p_code text, p_voter_key text)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_mine uuid; v_key text;
begin
  v_key := btrim(coalesce(p_code, ''));
  if v_key ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into v_room from public.rooms where id = v_key::uuid;
  else
    select * into v_room from public.rooms where code = upper(v_key);
  end if;
  if not found then return jsonb_build_object('status','gone'); end if;

  if v_room.status <> 'complete' then
    return jsonb_build_object('status','not_finished', 'title', v_room.title,
                              'room_id', v_room.id, 'code', v_room.code);
  end if;

  select winner_player_id into v_mine from public.audience_votes
   where room_id = v_room.id and voter_key = coalesce(p_voter_key, '');

  return jsonb_build_object(
    'status', 'open',
    -- the realtime channel is keyed on the room id, so a voter needs it to
    -- subscribe. The draft is over by definition here; there is no live
    -- board left for it to reveal.
    'room_id', v_room.id,
    'code', v_room.code,
    'title', v_room.title,
    'category', v_room.category_name,
    'roster_size', v_room.roster_size,
    'starting_cents', v_room.starting_bankroll_cents,
    'players', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pl.id, 'seat', pl.seat, 'name', pl.display_name,
               'leftover_cents', pl.bankroll_cents,
               'spent_cents', coalesce((select sum(r.price_cents) from public.roster_entries r
                                         where r.room_id = v_room.id and r.player_id = pl.id), 0),
               'rows', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'pick', r.pick_number, 'item', r.item_name,
                          'price_cents', r.price_cents, 'gifted', r.gifted)
                        order by r.pick_number)
                   from public.roster_entries r
                  where r.room_id = v_room.id and r.player_id = pl.id), '[]'::jsonb))
             order by pl.seat)
        from public.players pl where pl.room_id = v_room.id), '[]'::jsonb),
    'your_vote', v_mine,
    -- THE BLIND RULE, enforced in the database. A viewer who has not voted
    -- is not told the numbers, so hiding them in the UI is not what is
    -- keeping the vote blind.
    'tally', case when v_mine is null then null
                  else public.df20_audience_tally(v_room.id) end);
end $$;
grant execute on function public.get_audience_state(text, text) to anon, authenticated;

-- and casting a vote resolves the same two forms
create or replace function public.cast_audience_vote(
  p_code text, p_voter_key text, p_winner_player_id uuid
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_key text; v_ref text;
begin
  v_key := public.df20_clean_text(p_voter_key, 64);
  if length(v_key) < 16 then raise exception 'DF20_BAD_VOTE'; end if;

  v_ref := btrim(coalesce(p_code, ''));
  if v_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into v_room from public.rooms where id = v_ref::uuid for update;
  else
    select * into v_room from public.rooms where code = upper(v_ref) for update;
  end if;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  if v_room.status <> 'complete' then raise exception 'DF20_NOT_COMPLETE'; end if;
  if not exists (select 1 from public.players
                  where id = p_winner_player_id and room_id = v_room.id)
    then raise exception 'DF20_BAD_VOTE'; end if;

  if not public.df20_rate_limit('aud_vote', v_key, 20, 3600) then
    raise exception 'DF20_RATE_LIMITED';
  end if;

  -- FIRST vote stands. A second attempt is not an error and does not change
  -- anything: the viewer simply sees the tally they already earned.
  insert into public.audience_votes (room_id, voter_key, winner_player_id)
  values (v_room.id, v_key, p_winner_player_id)
  on conflict (room_id, voter_key) do nothing;

  -- the push that makes every open tally move at once
  begin
    perform realtime.send(
      public.df20_audience_tally(v_room.id), 'audience',
      'room:' || v_room.id::text, false);
  exception when others then null;   -- subscribers also poll
  end;

  return public.get_audience_state(v_room.id::text, v_key);
end $$;
grant execute on function public.cast_audience_vote(text, text, uuid) to anon, authenticated;

-- ─────────── 0024_admin.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0024 · the operator's console
--
-- Scope discipline: this covers things only this app knows. Revenue, MRR and
-- churn live in the Stripe dashboard; query health and table contents live in
-- the Supabase dashboard. Rebuilding either here would be a worse copy that
-- goes stale, so the admin page links out to them instead.
--
-- Every function below refuses everyone unless df20_is_admin() is true, which
-- reads a list of uuids from df20_config that no migration ever creates. With
-- that row absent — which is how this ships — there is no admin.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── the moderation queue exists, so accepting no longer publishes ─────────
do $$ begin
  alter table public.rooms drop constraint rooms_optin_chk;
exception when undefined_object then null; end $$;
alter table public.rooms add constraint rooms_optin_chk
  check (library_optin_state in
         ('none','eligible','ineligible','accepted','declined','pending','rejected'));

-- A host opting in is now a SUBMISSION, not a publication. The items still
-- pass the real-name heuristics first; a human then looks at them before
-- anything reaches a shelf every future room can draw from.
create or replace function public.submit_library_optin(
  p_result_token uuid, p_accept boolean
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_check jsonb;
begin
  select * into v_room from public.rooms where setup_result_token = p_result_token;
  if not found then raise exception 'DF20_NO_ROOM'; end if;

  if not coalesce(p_accept, false) then
    update public.rooms set library_optin_state = 'declined' where id = v_room.id;
    return jsonb_build_object('status','declined');
  end if;

  -- re-run eligibility at submit time; never trust the earlier answer
  v_check := public.offer_library_optin(p_result_token);
  if v_check->>'status' <> 'eligible' then
    return jsonb_build_object('status', v_check->>'status');
  end if;

  update public.rooms set library_optin_state = 'pending' where id = v_room.id;
  return jsonb_build_object('status','pending');
end $$;
grant execute on function public.submit_library_optin(uuid, boolean) to anon, authenticated;

-- ── the queue ─────────────────────────────────────────────────────────────
-- This is the ONE place room_pool items cross the boundary, and it is the
-- whole job: you cannot moderate a list you are not allowed to read. Admins
-- only, capped, and it never touches a room that is still being played.
create or replace function public.admin_library_queue()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'room_id', r.id,
             'category', r.category_name,
             'submitted_at', r.completed_at,
             'item_count', (select count(*) from public.room_pool p where p.room_id = r.id),
             'items', coalesce((select jsonb_agg(p.name order by p.name)
                                  from (select name from public.room_pool
                                         where room_id = r.id order by name limit 200) p),
                               '[]'::jsonb),
             'already_public', exists (
               select 1 from public.category_library l
                where l.name_norm = public.df20_norm_category(r.category_name)))
           order by r.completed_at desc)
      from public.rooms r
     where r.library_optin_state = 'pending'), '[]'::jsonb);
end $$;
grant execute on function public.admin_library_queue() to authenticated;

create or replace function public.admin_review_library(p_room uuid, p_approve boolean)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_id uuid; v_n int;
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;

  select * into v_room from public.rooms where id = p_room for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  if v_room.library_optin_state <> 'pending' then
    return jsonb_build_object('status', v_room.library_optin_state);
  end if;

  if not coalesce(p_approve, false) then
    update public.rooms set library_optin_state = 'rejected' where id = p_room;
    return jsonb_build_object('status','rejected');
  end if;

  insert into public.category_library (name, name_norm)
  values (v_room.category_name, public.df20_norm_category(v_room.category_name))
  on conflict (name_norm) do nothing
  returning id into v_id;

  if v_id is null then
    update public.rooms set library_optin_state = 'rejected' where id = p_room;
    return jsonb_build_object('status','already_exists');
  end if;

  -- name and items only. no room, no player, no timing.
  insert into public.category_library_items (library_id, name)
  select v_id, name from public.room_pool where room_id = p_room
  on conflict do nothing;

  select count(*) into v_n from public.category_library_items where library_id = v_id;
  update public.rooms set library_optin_state = 'accepted' where id = p_room;
  return jsonb_build_object('status','accepted', 'library_id', v_id, 'item_count', v_n);
end $$;
grant execute on function public.admin_review_library(uuid, boolean) to authenticated;

-- ── what is already on the public shelf ───────────────────────────────────
create or replace function public.admin_library_list()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', l.id, 'name', l.name, 'created_at', l.created_at,
             'item_count', (select count(*) from public.category_library_items i
                             where i.library_id = l.id))
           order by l.name)
      from public.category_library l), '[]'::jsonb);
end $$;
grant execute on function public.admin_library_list() to authenticated;

create or replace function public.admin_library_remove(p_id uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_name text;
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  select name into v_name from public.category_library where id = p_id;
  if v_name is null then return jsonb_build_object('removed', false); end if;
  -- rooms copy their pool at creation, so pulling a category from the shelf
  -- never disturbs a draft that is already using it
  delete from public.category_library where id = p_id;
  return jsonb_build_object('removed', true, 'name', v_name);
end $$;
grant execute on function public.admin_library_remove(uuid) to authenticated;

-- ── the user table ────────────────────────────────────────────────────────
-- Same signature as 0019, more columns. "last seat" is the last time this
-- account sat down in a room; players.last_seen_at is only ever the row's
-- creation time, so quoting it as live presence would be a lie.
create or replace function public.admin_list_profiles(p_query text default null)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_q text;
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  v_q := lower(btrim(coalesce(p_query, '')));

  return coalesce((
    select jsonb_agg(x order by x->>'created_at' desc) from (
      select jsonb_build_object(
               'id', p.id, 'email', p.email, 'display_name', p.display_name,
               'created_at', p.created_at,
               'premium_until', p.premium_until,
               'premium_source', p.premium_source,
               'subscription_status', p.subscription_status,
               'active', coalesce(p.premium_until > now(), false),
               'hosted', (select count(*) from public.rooms r
                           where r.host_profile_id = p.id and r.code is not null
                             and r.status in ('live','complete')),
               'played', (select count(distinct pl.room_id) from public.players pl
                           where pl.profile_id = p.id),
               'last_seat', (select max(pl.created_at) from public.players pl
                              where pl.profile_id = p.id),
               'decks', (select count(*) from public.user_categories c
                          where c.owner_id = p.id)) as x
        from public.profiles p
       where v_q = ''
          or lower(coalesce(p.email, '')) like '%' || v_q || '%'
          or lower(coalesce(p.display_name, '')) like '%' || v_q || '%'
       order by p.created_at desc
       limit 200) s), '[]'::jsonb);
end $$;
grant execute on function public.admin_list_profiles(text) to authenticated;

-- ── activity ──────────────────────────────────────────────────────────────
create or replace function public.admin_activity()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;

  return jsonb_build_object(
    'rooms', jsonb_build_object(
      'total',  (select count(*) from public.rooms where code is not null),
      'today',  (select count(*) from public.rooms
                  where code is not null and created_at >= date_trunc('day', now())),
      'week',   (select count(*) from public.rooms
                  where code is not null and created_at >= now() - interval '7 days'),
      'live',   (select count(*) from public.rooms where status = 'live'),
      'complete',(select count(*) from public.rooms where status = 'complete')),

    -- fourteen days of bars for the chart
    'daily', coalesce((
      select jsonb_agg(jsonb_build_object('day', d::date, 'rooms', n) order by d)
        from (select g.d, (select count(*) from public.rooms r
                            where r.code is not null
                              and r.created_at >= g.d and r.created_at < g.d + interval '1 day') as n
                from generate_series(date_trunc('day', now()) - interval '13 days',
                                     date_trunc('day', now()), interval '1 day') g(d)) s),
      '[]'::jsonb),

    -- the built-in pool against everything else somebody chose
    'categories', jsonb_build_object(
      'football', (select count(*) from public.rooms
                    where code is not null and category_name = 'Football Draft'),
      'other_library', (select count(*) from public.rooms
                         where code is not null and pool_source in ('builtin','library')
                           and coalesce(category_name,'') <> 'Football Draft'),
      'wikipedia', (select count(*) from public.rooms
                     where code is not null and pool_source = 'wikipedia'),
      'manual', (select count(*) from public.rooms
                  where code is not null and pool_source = 'manual'),
      'saved', (select count(*) from public.rooms
                 where code is not null and pool_source = 'saved')),

    'modes', jsonb_build_object(
      'standard', (select count(*) from public.rooms
                    where code is not null and content_mode = 'standard'),
      'creator', (select count(*) from public.rooms
                   where code is not null and content_mode = 'creator')),

    -- Only completed drafts have a duration worth quoting, and the sample
    -- count comes from the SAME subquery as the averages. Two predicates that
    -- can drift apart is how a page ends up claiming an average over two
    -- drafts and then showing no average.
    'duration', (
      select jsonb_build_object(
               'sample', count(*),
               'avg_seconds', round(avg(secs)),
               'median_seconds', round(percentile_cont(0.5) within group (order by secs)))
        from (select extract(epoch from (completed_at - started_at)) as secs
                from public.rooms
               where status = 'complete'
                 and started_at is not null and completed_at is not null
                 and completed_at > started_at
                 and completed_at - started_at < interval '12 hours') d),

    'library', jsonb_build_object(
      'public', (select count(*) from public.category_library),
      'pending', (select count(*) from public.rooms where library_optin_state = 'pending'),
      'saved_decks', (select count(*) from public.user_categories)),

    'audience', jsonb_build_object(
      'votes', (select count(*) from public.audience_votes),
      'rooms_voted_on', (select count(distinct room_id) from public.audience_votes)),

    'premium', jsonb_build_object(
      'active', (select count(*) from public.profiles where premium_until > now()),
      'by_source', coalesce((select jsonb_object_agg(coalesce(premium_source,'none'), n)
                               from (select premium_source, count(*) as n
                                       from public.profiles
                                      where premium_until > now()
                                      group by premium_source) s), '{}'::jsonb)));
end $$;
grant execute on function public.admin_activity() to authenticated;

-- ── webhook events, including the ones that went wrong ────────────────────
-- billing_events already existed for idempotency. Two columns turn it into
-- the only error surface this app has, which is a fair trade against
-- standing up error tracking nobody asked for. Everything else worth seeing
-- is in Vercel's logs, which the page links to rather than mirrors.
alter table public.billing_events
  add column if not exists status text not null default 'ok',
  add column if not exists detail text;

create or replace function public.df20_log_billing_failure(
  p_secret text, p_event_id text, p_kind text, p_detail text
) returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_expected text;
begin
  select value into v_expected from public.df20_config where key = 'billing_write_secret';
  if v_expected is null or p_secret is null or p_secret <> v_expected then
    raise exception 'DF20_NOT_AUTHORISED';
  end if;

  insert into public.billing_events (event_id, kind, status, detail)
  values (coalesce(nullif(p_event_id, ''), 'unidentified-' || gen_random_uuid()::text),
          left(coalesce(p_kind, 'unknown'), 60), 'failed', left(coalesce(p_detail, ''), 500))
  on conflict (event_id) do update
    set status = 'failed', detail = excluded.detail, processed_at = now();
end $$;
revoke all on function public.df20_log_billing_failure(text,text,text,text) from anon, authenticated;

create or replace function public.admin_recent_events(p_limit int default 40)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'event_id', e.event_id, 'kind', e.kind, 'status', e.status,
             'detail', e.detail, 'at', e.processed_at) order by e.processed_at desc)
      from (select * from public.billing_events
             order by processed_at desc
             limit least(greatest(coalesce(p_limit, 40), 1), 200)) e), '[]'::jsonb);
end $$;
grant execute on function public.admin_recent_events(int) to authenticated;

-- ─────────── 0025_selfcheck.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0025 · what must exist for v7 to work
--
-- Same job as 0013 and 0020, extended again. plpgsql still does not validate function
-- bodies at creation, so a half-applied bundle still reports success and
-- still fails on a real click. This is the thing that makes it fail loudly
-- here instead. KEEP IT UPDATED WHEN YOU ADD AN RPC.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.df20_selfcheck()
returns text language plpgsql as $$
declare
  v_missing text[] := '{}';
  f text;
  v_required text[] := array[
    -- money and game loop
    'public.df20_max_legal_bid(integer,integer,integer)',
    'public.df20_open_slots(uuid,uuid)',
    'public.df20_opponent(uuid,uuid)',
    'public.df20_can_outbid(uuid,uuid,integer)',
    'public.df20_is_broke(uuid,uuid)',
    'public.df20_add_to_roster(uuid,uuid,text,integer,boolean)',
    'public.df20_resolve_lot(uuid,text)',
    'public.df20_resolve_gift(uuid,uuid)',
    'public.df20_reveal_next(uuid)',
    'public.df20_advance(uuid)',
    'public.df20_public_state(uuid)',
    'public.df20_broadcast(uuid)',
    'public.df20_touch(uuid)',
    'public.df20_gen_code()',
    -- text safety
    'public.df20_clean_text(text,integer)',
    'public.df20_clean_logo_url(text)',
    -- categories
    'public.df20_norm_category(text)',
    'public.df20_token_overlap(text,text)',
    'public.df20_match_category(text,integer)',
    'public.df20_fill_pool(uuid,text,uuid)',
    'public.df20_seed_category(text,text[])',
    'public.df20_cache_wikipedia(text,text,text,text[],text,text)',
    'public.df20_looks_like_person(text)',
    'public.df20_person_oriented_category(text)',
    'public.list_free_categories()',
    -- abuse control and accounts
    'public.df20_rate_limit(text,text,integer,integer)',
    'public.df20_ensure_profile()',
    'public.df20_require_verified()',
    -- the client API
    'public.create_room(text,integer,integer,integer,integer,text,boolean,integer,text,text,text,uuid,text)',
    'public.create_pending_room(text)',
    'public.get_setup_state(uuid)',
    'public.setup_lock_items(uuid,text,text[],integer,integer,integer,integer,integer)',
    'public.join_room(text,text)',
    'public.start_draft(text,uuid)',
    'public.offer_decide(text,uuid,text)',
    'public.place_bid(text,uuid,integer,integer)',
    'public.pass_turn(text,uuid,integer)',
    'public.expire_turn(text)',
    'public.submit_vote(text,uuid,uuid)',
    'public.get_room_state(text)',
    'public.offer_library_optin(uuid)',
    'public.submit_library_optin(uuid,boolean)',
    -- v6: profiles, decks, premium
    'public.df20_premium_active(uuid)',
    'public.my_premium()',
    'public.my_profile_stats()',
    'public.df20_manual_winner(uuid)',
    'public.save_export_style(boolean,text,text,text)',
    'public.df20_export_style(text)',
    -- 0042: the only write path to profiles. `authenticated` holds no write
    -- grant on that table, so if this function goes missing the profile page
    -- fails shut rather than quietly falling back to a direct upsert.
    'public.save_profile(text,text,text)',
    -- 0042: asserts what must NOT be reachable, next to selfcheck's what
    -- must exist. Run by the bundle footer.
    'public.df20_grant_check()',
    'public.save_room_deck(text,text)',
    'public.my_decks()',
    'public.delete_deck(uuid)',
    -- v6: content tab
    'public.mint_obs_token(text,uuid)',
    'public.rotate_obs_token(text,uuid)',
    'public.get_obs_state(uuid)',
    'public.df20_audience_tally(uuid)',
    'public.get_audience_state(text,text)',
    'public.cast_audience_vote(text,text,uuid)',
    'public.get_audience_hub(text,uuid)',
    -- v6: billing
    'public.df20_apply_billing_event(text,text,uuid,text,text,text,timestamptz,text,integer)',
    'public.df20_revoke_premium(text,text,text,text)',
    'public.df20_billing_profile(text,uuid)',
    'public.df20_is_admin()',
    'public.admin_list_profiles(text)',
    'public.admin_set_premium(uuid,integer)',
    -- v7: the clock, the scouting report, the console
    'public.df20_turn_deadline(integer)',
    'public.my_scouting_report()',
    'public.admin_library_queue()',
    'public.admin_review_library(uuid,boolean)',
    'public.admin_library_list()',
    'public.admin_library_remove(uuid)',
    'public.admin_activity()',
    'public.admin_recent_events(integer)',
    'public.df20_log_billing_failure(text,text,text,text)',
    'public.leave_room(text,uuid)',
    -- v9: admin as a role, and the public handle
    'public.df20_admin_count()',
    'public.admin_set_admin(uuid,boolean)',
    'public.admin_audit_log(integer)',
    'public.df20_gen_handle()',
    'public.set_my_handle(text)',
    'public.my_handle()',
    -- v10: the verification gate reaches billing and admin
    'public.df20_email_verified(uuid)',
    'public.my_verification()',
    -- bot signals
    'public.df20_record_signup(text,uuid,text,text,text,text,text)',
    'public.admin_user_signals(text,text)'
  ];
  v_tables text[] := array['rooms','players','room_deck','room_pool','roster_entries',
                           'lots','bid_events','votes','rate_limits','category_library',
                           'category_library_items','category_library_aliases',
                           'wikipedia_cache','wikipedia_cache_items','profiles','templates',
                           'df20_config','user_categories','user_category_items',
                           'audience_votes','billing_events','signup_signals','disposable_domains','admin_audit'];
  v_columns text[] := array['profiles.premium_until','profiles.premium_source',
                            'profiles.subscription_status','profiles.stripe_customer_id',
                            'profiles.export_watermark','rooms.obs_token',
                            'rooms.content_mode','billing_events.status',
                            'rooms.abandoned_by','category_library.source',
                            'wikipedia_cache.source','profiles.is_admin',
                            'profiles.handle'];
  t text; c text;
begin
  foreach f in array v_required loop
    if to_regprocedure(f) is null then v_missing := v_missing || f; end if;
  end loop;
  foreach t in array v_tables loop
    if to_regclass('public.' || t) is null then v_missing := v_missing || ('table ' || t); end if;
  end loop;
  foreach c in array v_columns loop
    if not exists (select 1 from information_schema.columns
                    where table_schema = 'public'
                      and table_name = split_part(c, '.', 1)
                      and column_name = split_part(c, '.', 2))
    then v_missing := v_missing || ('column ' || c); end if;
  end loop;

  if coalesce(array_length(v_missing, 1), 0) > 0 then
    raise exception E'DF20_SELFCHECK_FAILED\nmissing:\n  %',
      array_to_string(v_missing, E'\n  ');
  end if;

  return format('ok - %s functions, %s tables and %s columns present',
                array_length(v_required, 1), array_length(v_tables, 1),
                array_length(v_columns, 1));
end $$;
revoke all on function public.df20_selfcheck() from anon, authenticated;

-- two defaults that are product decisions rather than implementation detail,
-- so they are asserted rather than assumed
do $$
declare v_default text;
begin
  select column_default into v_default from information_schema.columns
   where table_schema = 'public' and table_name = 'profiles'
     and column_name = 'export_watermark';
  if v_default is null or v_default not like 'true%' then
    raise exception 'DF20_WATERMARK_DEFAULT_WRONG: profiles.export_watermark defaults to %', v_default;
  end if;
end $$;

do $$
declare v_default text;
begin
  select column_default into v_default from information_schema.columns
   where table_schema = 'public' and table_name = 'rooms'
     and column_name = 'content_mode';
  if v_default is null or v_default not like '''standard''%' then
    raise exception 'DF20_CONTENT_MODE_DEFAULT_WRONG: rooms.content_mode defaults to %', v_default;
  end if;
end $$;

-- ─────────── 0026_leave.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0026 · leaving a draft
--
-- `abandoned` has been a legal value in rooms.status since 0001 and NOTHING
-- HAS EVER SET IT. Closing the tab mid-draft left the other player watching a
-- clock that would tick forever: expire_turn keeps resolving lots on their
-- behalf, the deck keeps dealing, and the room only really ends when the
-- 90-day purge deletes it.
--
-- This is the minimal honest version of leaving:
--   · the room is marked abandoned, with WHO left and WHEN
--   · any open lot is voided, so nobody is left on the clock
--   · the state is broadcast, so the other client finds out immediately
--
-- Deliberately NOT here: no forfeit, no scoring, no winner. Somebody walking
-- out is not a result, and inventing one would be inventing a rule the game
-- does not have.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.rooms
  add column if not exists abandoned_by uuid references public.players(id) on delete set null,
  add column if not exists abandoned_at timestamptz;

create or replace function public.leave_room(p_code text, p_token uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_me public.players;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;

  select * into v_me from public.players
   where room_id = v_room.id and session_token = p_token;
  if not found then raise exception 'DF20_BAD_TOKEN'; end if;

  -- a finished draft has nothing left to abandon; leaving is just navigation
  if v_room.status = 'complete' then
    return jsonb_build_object('status', 'complete', 'left', false);
  end if;
  if v_room.status = 'abandoned' then
    return jsonb_build_object('status', 'abandoned', 'left', false);
  end if;

  -- nobody should be sitting on a clock in a room that is over
  update public.lots
     set status = 'void', on_the_clock_player_id = null,
         turn_expires_at = null, resolved_at = now()
   where room_id = v_room.id and status in ('offered','bidding');

  update public.rooms
     set status = 'abandoned',
         phase = 'complete',
         abandoned_by = v_me.id,
         abandoned_at = now(),
         completed_at = coalesce(completed_at, now())
   where id = v_room.id;

  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);

  return jsonb_build_object('status', 'abandoned', 'left', true,
                            'by', v_me.display_name);
end $$;
grant execute on function public.leave_room(text, uuid) to anon, authenticated;

-- ─────────── 0027_provenance.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0027 · where a library category came from
--
-- category_library has never recorded its own provenance, and that is what
-- made the cache re-filtering question unanswerable last time: a hand-curated
-- shelf entry and a parsed Wikipedia list are the same row shape, so any bulk
-- re-filter would have gutted the curated ones along with the junk.
--
-- DELIBERATELY NOT BACKFILLED. Every row that exists right now stays null,
-- because the honest answer for them is "unknown" and a guess would be worse
-- than a blank — the whole point of the column is to be trustworthy enough to
-- run destructive bulk operations against.
--
-- wikipedia_cache also learns a source, so the Wikidata step can share the
-- one cache table rather than standing up a parallel one.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.category_library
  add column if not exists source text;

do $$ begin
  alter table public.category_library add constraint category_library_source_chk
    check (source is null or source in
           ('admin_curated','wikipedia_cache','wikidata_cache','user_submitted'));
exception when duplicate_object then null; end $$;

comment on column public.category_library.source is
  'How this entry was created. NULL means it predates 0027 and is genuinely '
  'unknown — never guess, and never treat NULL as any particular source.';

-- ── the shared cache learns which service answered ────────────────────────
alter table public.wikipedia_cache
  add column if not exists source text not null default 'wikipedia',
  add column if not exists entity_id text;          -- the Wikidata Q-id, when it was Wikidata

do $$ begin
  alter table public.wikipedia_cache add constraint wikipedia_cache_source_chk
    check (source in ('wikipedia','wikidata'));
exception when duplicate_object then null; end $$;

-- ── df20_seed_category is deliberately NOT touched ────────────────────────
-- Adding a defaulted third parameter to it creates a second overload, and
-- 0011 both defines the two-argument version AND calls it, as does 0014. On
-- the second run of this bundle the old arity is recreated beside the new one
-- and 0011's own seed calls become "function is not unique" — the bundle dies
-- halfway through, which is precisely the re-runnability rule this project
-- lives by. Curated lists get their provenance from the admin path that
-- writes the column directly, not from the shared seed helper.

-- ── the moderation queue publishes USER SUBMISSIONS ───────────────────────
-- Same body as 0024 apart from the one column: a host opting their list into
-- the public shelf is the user_submitted path by definition.
create or replace function public.admin_review_library(p_room uuid, p_approve boolean)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_id uuid; v_n int;
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;

  select * into v_room from public.rooms where id = p_room for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  if v_room.library_optin_state <> 'pending' then
    return jsonb_build_object('status', v_room.library_optin_state);
  end if;

  if not coalesce(p_approve, false) then
    update public.rooms set library_optin_state = 'rejected' where id = p_room;
    return jsonb_build_object('status','rejected');
  end if;

  insert into public.category_library (name, name_norm, source)
  values (v_room.category_name, public.df20_norm_category(v_room.category_name),
          'user_submitted')
  on conflict (name_norm) do nothing
  returning id into v_id;

  if v_id is null then
    update public.rooms set library_optin_state = 'rejected' where id = p_room;
    return jsonb_build_object('status','already_exists');
  end if;

  insert into public.category_library_items (library_id, name)
  select v_id, name from public.room_pool where room_id = p_room
  on conflict do nothing;

  select count(*) into v_n from public.category_library_items where library_id = v_id;
  update public.rooms set library_optin_state = 'accepted' where id = p_room;
  return jsonb_build_object('status','accepted', 'library_id', v_id, 'item_count', v_n);
end $$;
grant execute on function public.admin_review_library(uuid, boolean) to authenticated;

-- ── caching a lookup, whichever service answered ──────────────────────────
-- 0010 defines the four-argument version and this adds two defaulted ones,
-- which would leave two overloads standing. Nothing calls it with four
-- arguments — only the resolve route calls it at all, now with six — so the
-- old signature is dropped here, AFTER 0010 has recreated it on this run.
-- That ordering is what keeps the bundle re-runnable.
drop function if exists public.df20_cache_wikipedia(text, text, text, text[]);

create or replace function public.df20_cache_wikipedia(
  p_secret text, p_query text, p_title text, p_items text[],
  p_source text default 'wikipedia', p_entity_id text default null
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_q text; v_id uuid; v_n int; s text; v_clean text; v_expected text;
begin
  select value into v_expected from public.df20_config where key = 'wiki_write_secret';
  if v_expected is null or p_secret is null or p_secret <> v_expected then
    raise exception 'DF20_NOT_AUTHORISED';
  end if;
  if coalesce(p_source, 'wikipedia') not in ('wikipedia','wikidata') then
    raise exception 'DF20_BAD_SOURCE';
  end if;

  v_q := public.df20_norm_category(p_query);
  if length(v_q) = 0 then raise exception 'DF20_BAD_CATEGORY'; end if;

  insert into public.wikipedia_cache (query_norm, article_title, source, entity_id)
  values (v_q, public.df20_clean_text(p_title, 120),
          coalesce(p_source, 'wikipedia'), p_entity_id)
  on conflict (query_norm) do update set article_title = excluded.article_title,
                                         source = excluded.source,
                                         entity_id = excluded.entity_id,
                                         fetched_at = now()
  returning id into v_id;

  delete from public.wikipedia_cache_items where cache_id = v_id;
  foreach s in array coalesce(p_items, '{}'::text[]) loop
    v_clean := public.df20_clean_text(s, 60);
    if length(v_clean) >= 2 then
      insert into public.wikipedia_cache_items (cache_id, name)
      values (v_id, v_clean) on conflict do nothing;
    end if;
  end loop;

  select count(*) into v_n from public.wikipedia_cache_items where cache_id = v_id;
  return jsonb_build_object('source', coalesce(p_source, 'wikipedia'),
                            'source_id', v_id, 'name', p_title, 'item_count', v_n);
end $$;
grant execute on function public.df20_cache_wikipedia(text,text,text,text[],text,text)
  to anon, authenticated;

-- ─────────── 0028_admin_roles.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0028 · admin as a role, not a config string
--
-- Admin has been a comma-separated list of uuids in df20_config since 0019.
-- That was fine for one person editing a table by hand and is wrong for a UI
-- toggle: string surgery to revoke, no way to count admins, nowhere to record
-- who did it.
--
-- This moves the truth to profiles.is_admin and BACKFILLS from the config row
-- — a backfill that is safe precisely because the source is known and exact,
-- unlike the provenance column in 0027 which was left null for that reason.
--
-- df20_is_admin() accepts EITHER source afterwards. That is deliberate: if the
-- backfill misses for any reason, the operator is not locked out of the panel
-- that grants admin, which is the one lockout with no way back.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.profiles
  add column if not exists is_admin boolean not null default false;

-- carry the existing admins across
update public.profiles p
   set is_admin = true
  from public.df20_config c,
       lateral unnest(string_to_array(c.value, ',')) u
 where c.key = 'admin_user_ids'
   and btrim(u) = p.id::text
   and p.is_admin = false;

create index if not exists profiles_is_admin_idx on public.profiles(id) where is_admin;

-- ── a permission this sensitive gets a paper trail ────────────────────────
-- Nothing general-purpose existed to log into: billing_events is billing.
-- Five columns is not new infrastructure, and "who made whom an admin" is not
-- a question to answer from memory.
create table if not exists public.admin_audit (
  id         bigserial primary key,
  actor_id   uuid references public.profiles(id) on delete set null,
  action     text not null,
  target_id  uuid references public.profiles(id) on delete set null,
  detail     text,
  at         timestamptz not null default now()
);
create index if not exists admin_audit_at_idx on public.admin_audit(at desc);
alter table public.admin_audit enable row level security;
revoke all on public.admin_audit from anon, authenticated;

-- ── either source counts ──────────────────────────────────────────────────
create or replace function public.df20_is_admin()
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select (select auth.uid()) is not null
     and (
       exists (select 1 from public.profiles p
                where p.id = (select auth.uid()) and p.is_admin)
       or exists (select 1 from public.df20_config c,
                       lateral unnest(string_to_array(c.value, ',')) u
                   where c.key = 'admin_user_ids'
                     and btrim(u) = (select auth.uid())::text)
     )
$$;
grant execute on function public.df20_is_admin() to anon, authenticated;

-- how many admins would remain if this one were removed
create or replace function public.df20_admin_count()
returns int language sql stable security definer
set search_path = public, pg_temp as $$
  select count(distinct id)::int from (
    select p.id from public.profiles p where p.is_admin
    union
    select p.id from public.profiles p, public.df20_config c,
           lateral unnest(string_to_array(c.value, ',')) u
     where c.key = 'admin_user_ids' and btrim(u) = p.id::text
  ) s
$$;
revoke all on function public.df20_admin_count() from anon, authenticated;

-- ── grant and revoke ──────────────────────────────────────────────────────
create or replace function public.admin_set_admin(p_user_id uuid, p_grant boolean)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_actor uuid; v_target public.profiles; v_remaining int; v_legacy boolean;
begin
  -- server-side, because hiding a button is not a permission check
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  v_actor := auth.uid();

  select * into v_target from public.profiles where id = p_user_id for update;
  if not found then raise exception 'DF20_NO_SUCH_USER'; end if;

  if coalesce(p_grant, false) then
    update public.profiles set is_admin = true, updated_at = now() where id = p_user_id;
    insert into public.admin_audit (actor_id, action, target_id, detail)
    values (v_actor, 'admin_granted', p_user_id, v_target.email);
    return jsonb_build_object('user_id', p_user_id, 'is_admin', true);
  end if;

  -- THE LAST ADMIN CANNOT BE REMOVED. An app with zero admins has no way
  -- back in through its own UI; the only repair is a hand-edit in the
  -- Supabase table editor, which is exactly what this feature replaced.
  v_remaining := public.df20_admin_count();
  if v_remaining <= 1 then
    raise exception 'DF20_LAST_ADMIN';
  end if;

  update public.profiles set is_admin = false, updated_at = now() where id = p_user_id;

  -- a uuid left in the legacy config row would silently re-grant on the next
  -- df20_is_admin() call, so revoking has to clear both sources
  select exists (select 1 from public.df20_config c,
                      lateral unnest(string_to_array(c.value, ',')) u
                  where c.key = 'admin_user_ids' and btrim(u) = p_user_id::text)
    into v_legacy;
  if v_legacy then
    update public.df20_config
       set value = coalesce((select string_agg(btrim(u), ',')
                               from unnest(string_to_array(value, ',')) u
                              where btrim(u) <> p_user_id::text and btrim(u) <> ''), '')
     where key = 'admin_user_ids';
    -- string_agg over an empty set is NULL, and value is NOT NULL. Removing
    -- the only listed uuid therefore has to remove the row, which is also the
    -- documented "row absent means nobody is an admin" state rather than an
    -- empty string nobody expects.
    delete from public.df20_config where key = 'admin_user_ids' and btrim(value) = '';
  end if;

  insert into public.admin_audit (actor_id, action, target_id, detail)
  values (v_actor, 'admin_revoked', p_user_id,
          v_target.email || case when v_legacy then ' (also cleared from df20_config)' else '' end);

  return jsonb_build_object('user_id', p_user_id, 'is_admin', false);
end $$;
grant execute on function public.admin_set_admin(uuid, boolean) to authenticated;

-- ── the audit trail, readable by admins ───────────────────────────────────
create or replace function public.admin_audit_log(p_limit int default 50)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'at', a.at, 'action', a.action, 'detail', a.detail,
             'actor', (select coalesce(x.display_name, x.email, x.id::text)
                         from public.profiles x where x.id = a.actor_id),
             'target', (select coalesce(x.display_name, x.email, x.id::text)
                          from public.profiles x where x.id = a.target_id))
           order by a.at desc)
      from (select * from public.admin_audit
             order by at desc
             limit least(greatest(coalesce(p_limit, 50), 1), 200)) a), '[]'::jsonb);
end $$;
grant execute on function public.admin_audit_log(int) to authenticated;


-- ─────────── 0029_handles.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0029 · a public handle that is not an email address
--
-- profiles.email is the login credential and has been standing in as the
-- display identity, which means any surface that names an account leaks one.
-- This adds a handle that is safe to show.
--
-- GENERATED, NOT CHOSEN, at creation. A chosen handle needs a uniqueness
-- check inside the signup flow, a taken-name error state, and a decision
-- about what happens when someone abandons signup halfway — for a value whose
-- only job today is "something to display instead of an email". Everyone gets
-- one immediately, and set_my_handle() lets anyone who cares pick their own
-- afterwards, with the validation in one place rather than in the signup path.
--
-- admin_list_profiles is redefined HERE, not in 0028, because it reads this
-- column: a caller and its dependency in different files is the failure 0013
-- exists to prevent.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.profiles
  add column if not exists handle text;

create unique index if not exists profiles_handle_idx
  on public.profiles(lower(handle)) where handle is not null;

-- no i/l/o/0/1: a handle gets read aloud and typed back in
create or replace function public.df20_gen_handle()
returns text language plpgsql security definer
set search_path = public, pg_temp as $$
declare a text := 'abcdefghjkmnpqrstuvwxyz23456789'; v text; i int;
begin
  loop
    v := '';
    for i in 1..8 loop
      v := v || substr(a, 1 + floor(random() * length(a))::int, 1);
    end loop;
    exit when not exists (select 1 from public.profiles where lower(handle) = v);
  end loop;
  return v;
end $$;
revoke all on function public.df20_gen_handle() from anon, authenticated;

-- everyone who already has an account gets one now
do $$
declare r record;
begin
  for r in select id from public.profiles where handle is null loop
    update public.profiles set handle = public.df20_gen_handle() where id = r.id;
  end loop;
end $$;

-- ── every new account gets one at creation ────────────────────────────────
-- Same body as 0015 plus the handle. Still never a reason to refuse a room:
-- a handle that cannot be minted leaves the column null rather than raising.
create or replace function public.df20_ensure_profile()
returns uuid language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_uid uuid; v_email text;
begin
  v_uid := auth.uid();
  if v_uid is null then return null; end if;
  begin
    select u.email into v_email from auth.users u where u.id = v_uid;
  exception when others then v_email := null;
  end;

  insert into public.profiles (id, email, handle)
  values (v_uid, v_email, public.df20_gen_handle())
  on conflict (id) do nothing;

  -- an account that predates this column, or one whose insert raced
  update public.profiles set handle = public.df20_gen_handle()
   where id = v_uid and handle is null;

  return v_uid;
end $$;
revoke all on function public.df20_ensure_profile() from anon, authenticated;

-- ── or pick your own ──────────────────────────────────────────────────────
create or replace function public.set_my_handle(p_handle text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_uid uuid; v_h text;
begin
  v_uid := public.df20_ensure_profile();
  if v_uid is null then raise exception 'DF20_SIGNIN_REQUIRED'; end if;

  v_h := lower(btrim(coalesce(p_handle, '')));
  if v_h !~ '^[a-z0-9_-]{3,20}$' then raise exception 'DF20_BAD_HANDLE'; end if;
  -- words that would let one account be mistaken for the service itself
  if v_h ~ '^(admin|administrator|draftfor20|df20|support|help|root|system|mod|moderator|staff|official)$'
    then raise exception 'DF20_RESERVED_HANDLE'; end if;

  if exists (select 1 from public.profiles
              where lower(handle) = v_h and id <> v_uid) then
    raise exception 'DF20_HANDLE_TAKEN';
  end if;

  update public.profiles set handle = v_h, updated_at = now() where id = v_uid;
  return jsonb_build_object('handle', v_h);
end $$;
grant execute on function public.set_my_handle(text) to authenticated;

-- ── the admin table, now with the handle and the admin flag ───────────────
create or replace function public.admin_list_profiles(p_query text default null)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_q text;
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  v_q := lower(btrim(coalesce(p_query, '')));

  return coalesce((
    select jsonb_agg(x order by x->>'created_at' desc) from (
      select jsonb_build_object(
               'id', p.id, 'email', p.email, 'display_name', p.display_name,
               'handle', p.handle, 'created_at', p.created_at,
               'premium_until', p.premium_until,
               'premium_source', p.premium_source,
               'subscription_status', p.subscription_status,
               'active', coalesce(p.premium_until > now(), false),
               'is_admin', p.is_admin,
               'hosted', (select count(*) from public.rooms r
                           where r.host_profile_id = p.id and r.code is not null
                             and r.status in ('live','complete')),
               'played', (select count(distinct pl.room_id) from public.players pl
                           where pl.profile_id = p.id),
               'last_seat', (select max(pl.created_at) from public.players pl
                              where pl.profile_id = p.id),
               'decks', (select count(*) from public.user_categories c
                          where c.owner_id = p.id)) as x
        from public.profiles p
       where v_q = ''
          or lower(coalesce(p.email, '')) like '%' || v_q || '%'
          or lower(coalesce(p.display_name, '')) like '%' || v_q || '%'
          or lower(coalesce(p.handle, '')) like '%' || v_q || '%'
       order by p.created_at desc
       limit 200) s), '[]'::jsonb);
end $$;
grant execute on function public.admin_list_profiles(text) to authenticated;

-- ── the owner sees their own handle ───────────────────────────────────────
create or replace function public.my_handle()
returns jsonb language sql stable security definer
set search_path = public, pg_temp as $$
  select jsonb_build_object('handle', (select handle from public.profiles
                                        where id = (select auth.uid())))
$$;
grant execute on function public.my_handle() to authenticated;

-- ─────────── 0030_verify_gates.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0030 · the verification gate reaches the paths it claimed to
--
-- 0016 added df20_require_verified() and wired it to the custom-category
-- paths. It was never wired to the other two things the policy names:
--
--   custom categories  gated since 0016          ✓
--   premium purchase   never checked             ✗
--   admin functions    never checked             ✗
--
-- Both are fixed here. df20_is_admin() gaining a verification requirement is
-- the risky one — it is the check that guards the panel used to grant admin —
-- so the helper is DEFENSIVE in exactly the way 0016 is: an auth.users row it
-- cannot read counts as verified. The only way to lose admin is an explicit
-- null email_confirmed_at, never a permissions hiccup reading the table.
--
-- NOTE FOR WHOEVER READS THIS NEXT: with the project's "Confirm email"
-- setting OFF, Supabase stamps email_confirmed_at at signup and every check
-- here passes for everyone. These gates only start biting once that setting
-- is turned on in the dashboard. The code cannot turn it on.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.df20_email_verified(p_uid uuid)
returns boolean language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_confirmed timestamptz;
begin
  if p_uid is null then return false; end if;
  begin
    select u.email_confirmed_at into v_confirmed from auth.users u where u.id = p_uid;
  exception when others then
    return true;   -- column or table unreadable: do not invent a lockout
  end;
  return v_confirmed is not null;
end $$;
revoke all on function public.df20_email_verified(uuid) from anon, authenticated;

-- ── admin now requires a confirmed address ────────────────────────────────
create or replace function public.df20_is_admin()
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select (select auth.uid()) is not null
     and public.df20_email_verified((select auth.uid()))
     and (
       exists (select 1 from public.profiles p
                where p.id = (select auth.uid()) and p.is_admin)
       or exists (select 1 from public.df20_config c,
                       lateral unnest(string_to_array(c.value, ',')) u
                   where c.key = 'admin_user_ids'
                     and btrim(u) = (select auth.uid())::text)
     )
$$;
grant execute on function public.df20_is_admin() to anon, authenticated;

-- ── what the billing route asks before it opens a checkout session ───────
-- Answered here rather than read off the JWT so there is one definition of
-- "verified" in the system, and it is the database's.
create or replace function public.my_verification()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_uid uuid;
begin
  v_uid := auth.uid();
  if v_uid is null then
    return jsonb_build_object('signed_in', false, 'verified', false);
  end if;
  return jsonb_build_object('signed_in', true,
                            'verified', public.df20_email_verified(v_uid));
end $$;
grant execute on function public.my_verification() to anon, authenticated;

-- ─────────── 0031_lock_handle.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0031 · the user ID is assigned, not chosen
--
-- 0029 let an account rename its own handle. That is now the wrong shape: it
-- is a USER ID, it identifies the account wherever an email must not appear,
-- and an identifier people can swap around is a poor one — it breaks any
-- reference anybody wrote down.
--
-- Enforced by removing the grant rather than hiding the button, because the
-- anon key is public and set_my_handle was reachable with curl. The function
-- itself stays: it is how an operator fixes a genuinely bad handle from the
-- SQL editor, which is the only place that should be possible.
-- ═══════════════════════════════════════════════════════════════════════════

-- PUBLIC holds EXECUTE on every function by default, so revoking from anon
-- and authenticated alone changes nothing — the privilege comes in through
-- PUBLIC. That default grant is the one that has to go.
revoke all on function public.set_my_handle(text) from public;
revoke all on function public.set_my_handle(text) from anon, authenticated;

comment on function public.set_my_handle(text) is
  'Operator-only since 0031. The handle is a user ID: assigned at signup and '
  'not user-changeable. Callable from the SQL editor to correct one by hand.';

-- ─────────── 0032_profile_on_signup.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0032 · a profile exists from the moment the account does
--
-- THE BUG THIS FIXES, which had two faces:
--
--   profiles rows were only ever created by df20_ensure_profile(), and that
--   runs on create_room / join_room / save_* — things a person DOES. Signing
--   up created an auth.users row and nothing else. So an account that signed
--   up and went straight to checkout had no profile, and:
--
--     · admin_list_profiles reads profiles, so it never saw them
--     · df20_apply_billing_event looks the buyer up in profiles, found
--       nothing, returned {matched:false} and wrote NOTHING — Stripe took
--       the money and the grant silently never happened
--
-- The trigger is the real fix. The backfill catches everyone already in that
-- state. The webhook change is belt and braces: taking money and writing
-- nothing is the one failure this system must not have, so it now creates the
-- profile itself rather than shrugging, and records a failure when it truly
-- cannot identify the buyer.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1. every new account gets a profile, immediately ──────────────────────
create or replace function public.df20_on_auth_user_created()
returns trigger language plpgsql security definer
set search_path = public, pg_temp as $$
begin
  insert into public.profiles (id, email, handle)
  values (new.id, new.email, public.df20_gen_handle())
  on conflict (id) do nothing;
  return new;
exception when others then
  -- a profile that cannot be written must never block the signup itself;
  -- df20_ensure_profile() still backstops on the next authenticated action
  return new;
end $$;

drop trigger if exists df20_on_auth_user_created on auth.users;

do $$
begin
  create trigger df20_on_auth_user_created
    after insert on auth.users
    for each row execute function public.df20_on_auth_user_created();
  raise notice 'trigger installed: every new account now gets a profile row';
exception when insufficient_privilege then
  raise exception
    'DF20_TRIGGER_DENIED: could not create the trigger on auth.users. Run this '
    'migration from the Supabase SQL editor (which runs as postgres), not from '
    'a pooled application connection.';
end $$;

-- ── 2. everyone already stranded without one ──────────────────────────────
do $$
declare v_n int;
begin
  insert into public.profiles (id, email, handle)
  select u.id, u.email, public.df20_gen_handle()
    from auth.users u
    left join public.profiles p on p.id = u.id
   where p.id is null
  on conflict (id) do nothing;
  get diagnostics v_n = row_count;
  raise notice 'backfilled % account(s) that had no profile row', v_n;
end $$;

-- any profile that predates the handle column still needs one
update public.profiles
   set handle = public.df20_gen_handle()
 where handle is null;

-- ── 3. the webhook stops being able to fail silently ──────────────────────
create or replace function public.df20_apply_billing_event(
  p_secret          text,
  p_event_id        text,
  p_user_id         uuid,
  p_customer_id     text,
  p_subscription_id text,
  p_status          text,
  p_premium_until   timestamptz,
  p_source          text,
  p_extend_hours    int default null
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_expected text; v_id uuid; v_until timestamptz; v_rows int;
begin
  select value into v_expected from public.df20_config where key = 'billing_write_secret';
  if v_expected is null or p_secret is null or p_secret <> v_expected then
    raise exception 'DF20_NOT_AUTHORISED';
  end if;

  if p_source is not null and p_source not in
     ('stripe_subscription','admin_grant','game_night_pass') then
    raise exception 'DF20_BAD_SOURCE';
  end if;

  if p_user_id is not null then
    select id into v_id from public.profiles where id = p_user_id;
  end if;
  if v_id is null and p_customer_id is not null then
    select id into v_id from public.profiles where stripe_customer_id = p_customer_id;
  end if;

  -- Checkout carried a real account id but no profile row exists for it.
  -- Create it: somebody has paid, and refusing to record that because a row
  -- is missing is how money goes missing.
  if v_id is null and p_user_id is not null
     and exists (select 1 from auth.users u where u.id = p_user_id) then
    insert into public.profiles (id, email, handle)
    select u.id, u.email, public.df20_gen_handle()
      from auth.users u where u.id = p_user_id
    on conflict (id) do nothing;
    select id into v_id from public.profiles where id = p_user_id;
  end if;

  if v_id is null then
    -- genuinely cannot tell who paid. Record it so it surfaces in the console
    -- instead of vanishing into a 200 nobody reads.
    if p_event_id is not null then
      insert into public.billing_events (event_id, kind, status, detail)
      values (p_event_id, coalesce(p_source, 'stripe'), 'failed',
              'no profile matched: user_id=' || coalesce(p_user_id::text, 'null')
              || ' customer=' || coalesce(p_customer_id, 'null'))
      on conflict (event_id) do update
        set status = 'failed', detail = excluded.detail, processed_at = now();
    end if;
    return jsonb_build_object('matched', false);
  end if;

  if p_event_id is not null then
    insert into public.billing_events (event_id, kind)
    values (p_event_id, coalesce(p_source, 'stripe'))
    on conflict (event_id) do nothing;
    get diagnostics v_rows = row_count;
    if v_rows = 0 then
      return jsonb_build_object('matched', true, 'duplicate', true);
    end if;
  end if;

  if p_extend_hours is not null then
    select greatest(coalesce(premium_until, now()), now())
             + make_interval(hours => p_extend_hours)
      into v_until from public.profiles where id = v_id;
  else
    v_until := p_premium_until;
  end if;

  update public.profiles
     set premium_until          = coalesce(v_until, premium_until),
         premium_source         = coalesce(p_source, premium_source),
         subscription_status    = coalesce(p_status, subscription_status),
         stripe_customer_id     = coalesce(p_customer_id, stripe_customer_id),
         stripe_subscription_id = coalesce(p_subscription_id, stripe_subscription_id),
         updated_at             = now()
   where id = v_id;

  return jsonb_build_object('matched', true, 'user_id', v_id,
                            'premium_until', to_jsonb(v_until));
end $$;
revoke all on function public.df20_apply_billing_event(text,text,uuid,text,text,text,timestamptz,text,int)
  from public;
revoke all on function public.df20_apply_billing_event(text,text,uuid,text,text,text,timestamptz,text,int)
  from anon, authenticated;

-- ─────────── 0033_premium_line.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0033 · free is the shelf, everything else is premium
--
-- The line moves. Previously custom categories cost an account and the
-- audience vote was free on purpose (it is the acquisition loop). Both are
-- now premium, by decision.
--
--   FREE      the premade shelf: builtin and library pools, signed in or not.
--             Playing, the results card, the watermarked PNG, joining a room.
--   PREMIUM   any pool the host supplies — typed (wikipedia), handed off
--             (manual), or reused (saved) — Content Creator rooms, the OBS
--             source, record mode, card branding, the full scouting report,
--             and now the audience vote.
--
-- Gated HERE, not in the UI. A padlock in React is decoration; the anon key
-- is public and every one of these RPCs is reachable with curl.
--
-- The audience vote checks the HOST's premium, not the voter's. Voters are
-- strangers with no account and never need one — the feature belongs to the
-- person who ran the draft.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.create_room(
  p_title text, p_roster_size int, p_bankroll_cents int, p_min_bid_cents int,
  p_timer_seconds int, p_host_name text, p_is_private boolean default true,
  p_gives_per_player int default 2, p_brand_accent text default null,
  p_brand_logo_url text default null,
  p_pool_source text default 'builtin', p_pool_ref uuid default null,
  p_content_mode text default 'standard'
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_pl public.players; v_uid uuid; v_accent text; v_n int;
begin
  if coalesce(p_pool_source, 'builtin') in ('wikipedia','saved') then
    v_uid := public.df20_require_verified();
  else
    v_uid := public.df20_ensure_profile();   -- null when signed out, which is fine
  end if;

  if coalesce(p_pool_source, 'builtin') = 'saved' then
    if not exists (select 1 from public.user_categories
                    where id = p_pool_ref and owner_id = v_uid) then
      raise exception 'DF20_NOT_YOUR_DECK';
    end if;
  end if;

  -- FREE IS THE SHELF. builtin and library stay open to everyone, signed in
  -- or not; anything the host supplies themselves is premium.
  if coalesce(p_pool_source, 'builtin') not in ('builtin', 'library')
     and (v_uid is null or not public.df20_premium_active(v_uid)) then
    raise exception 'DF20_PREMIUM_REQUIRED';
  end if;

  -- CONTENT CREATOR is chosen here, at creation, and never changes. The
  -- room's whole layout is decided by this column, so letting it be flipped
  -- mid-draft would mean re-laying-out a board somebody is streaming.
  p_content_mode := coalesce(nullif(btrim(lower(p_content_mode)), ''), 'standard');
  if p_content_mode not in ('standard', 'creator') then
    raise exception 'DF20_BAD_CONTENT_MODE';
  end if;
  if p_content_mode = 'creator'
     and (v_uid is null or not public.df20_premium_active(v_uid)) then
    raise exception 'DF20_PREMIUM_REQUIRED';
  end if;

  p_title := public.df20_clean_text(p_title, 60);
  if length(p_title) = 0 then p_title := 'Football Draft'; end if;
  p_host_name := public.df20_clean_text(p_host_name, 24);
  if length(p_host_name) = 0 then raise exception 'DF20_BAD_NAME'; end if;

  if p_roster_size is null or p_roster_size < 1 or p_roster_size > 30
    then raise exception 'DF20_BAD_ROSTER_SIZE'; end if;
  if p_bankroll_cents is null or p_bankroll_cents < 0 or p_bankroll_cents > 10000000
    then raise exception 'DF20_BAD_BANKROLL'; end if;
  if p_min_bid_cents is null or p_min_bid_cents < 0 or p_min_bid_cents > 1000000
    then raise exception 'DF20_BAD_MIN_BID'; end if;
  -- 0 is the no-limit sentinel; 1 and 2 seconds are still nonsense
  if p_timer_seconds is null
     or not (p_timer_seconds = 0 or p_timer_seconds between 3 and 300)
    then raise exception 'DF20_BAD_TIMER'; end if;
  if p_gives_per_player is null or p_gives_per_player < 0 or p_gives_per_player > 30
    then raise exception 'DF20_BAD_GIVES'; end if;

  v_accent := public.df20_clean_text(p_brand_accent, 9);
  if v_accent = '' then v_accent := null; end if;
  if v_accent is not null and v_accent !~ '^#[0-9A-Fa-f]{6}$'
    then raise exception 'DF20_BAD_ACCENT'; end if;

  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, gives_per_player,
                            is_private, brand_accent, brand_logo_url, host_profile_id,
                            content_mode)
  values (public.df20_gen_code(), p_title, p_roster_size, p_bankroll_cents,
          p_min_bid_cents, p_timer_seconds, p_gives_per_player,
          coalesce(p_is_private, true), v_accent,
          public.df20_clean_logo_url(p_brand_logo_url), v_uid,
          p_content_mode)
  returning * into v_room;

  v_n := public.df20_fill_pool(v_room.id, coalesce(p_pool_source, 'builtin'), p_pool_ref);
  if v_n < p_roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;

  insert into public.players (room_id, seat, display_name, bankroll_cents, is_host, profile_id)
  values (v_room.id, 1, p_host_name, p_bankroll_cents, true, v_uid)
  returning * into v_pl;

  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code,
                            'player_id', v_pl.id, 'session_token', v_pl.session_token,
                            'seat', 1, 'pool_size', v_n,
                            'content_mode', v_room.content_mode);
end $$;

create or replace function public.create_pending_room(p_content_mode text default 'standard')
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_uid uuid;
begin
  v_uid := public.df20_require_verified();

  if not public.df20_rate_limit('pending_room', v_uid::text, 20, 3600) then
    raise exception 'DF20_RATE_LIMITED';
  end if;

  p_content_mode := coalesce(nullif(btrim(lower(p_content_mode)), ''), 'standard');
  if p_content_mode not in ('standard', 'creator') then
    raise exception 'DF20_BAD_CONTENT_MODE';
  end if;
  if p_content_mode = 'creator' and not public.df20_premium_active(v_uid) then
    raise exception 'DF20_PREMIUM_REQUIRED';
  end if;

  -- a setup link exists to build a category by hand, which is the premium
  -- path whatever mode the room is in
  if not public.df20_premium_active(v_uid) then
    raise exception 'DF20_PREMIUM_REQUIRED';
  end if;

  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, host_profile_id,
                            setup_token, setup_expires_at, pool_source, content_mode)
  values (null, 'Untitled draft', 5, 2000, 100, 15, v_uid,
          gen_random_uuid(), now() + interval '24 hours', 'manual', p_content_mode)
  returning * into v_room;

  return jsonb_build_object('setup_token', v_room.setup_token,
                            'expires_at', v_room.setup_expires_at,
                            'room_id', v_room.id,
                            'content_mode', v_room.content_mode);
end $$;
grant execute on function public.create_room(text,int,int,int,int,text,boolean,int,text,text,text,uuid,text) to anon, authenticated;
grant execute on function public.create_pending_room(text) to anon, authenticated;

-- ── does this room's host still pay for the audience vote? ────────────────
create or replace function public.df20_room_vote_enabled(p_room uuid)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select coalesce((select public.df20_premium_active(r.host_profile_id)
                     from public.rooms r where r.id = p_room), false)
$$;
revoke all on function public.df20_room_vote_enabled(uuid) from public;
revoke all on function public.df20_room_vote_enabled(uuid) from anon, authenticated;

-- ── the vote page ─────────────────────────────────────────────────────────
-- 'locked' is a distinct answer from 'gone': the voter should be told the
-- draft is real and the host has not unlocked voting, not that the link is
-- broken. It is also the one place a stranger meets the paywall, so it is
-- worth being honest rather than blank.
create or replace function public.get_audience_state(p_code text, p_voter_key text)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_mine uuid; v_key text;
begin
  v_key := btrim(coalesce(p_code, ''));
  if v_key ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into v_room from public.rooms where id = v_key::uuid;
  else
    select * into v_room from public.rooms where code = upper(v_key);
  end if;
  if not found then return jsonb_build_object('status','gone'); end if;

  if v_room.status <> 'complete' then
    return jsonb_build_object('status','not_finished', 'title', v_room.title,
                              'room_id', v_room.id, 'code', v_room.code);
  end if;

  if not public.df20_room_vote_enabled(v_room.id) then
    return jsonb_build_object('status','locked', 'title', v_room.title,
                              'code', v_room.code);
  end if;

  select winner_player_id into v_mine from public.audience_votes
   where room_id = v_room.id and voter_key = coalesce(p_voter_key, '');

  return jsonb_build_object(
    'status', 'open',
    'room_id', v_room.id,
    'code', v_room.code,
    'title', v_room.title,
    'category', v_room.category_name,
    'roster_size', v_room.roster_size,
    'starting_cents', v_room.starting_bankroll_cents,
    'players', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pl.id, 'seat', pl.seat, 'name', pl.display_name,
               'leftover_cents', pl.bankroll_cents,
               'spent_cents', coalesce((select sum(r.price_cents) from public.roster_entries r
                                         where r.room_id = v_room.id and r.player_id = pl.id), 0),
               'rows', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'pick', r.pick_number, 'item', r.item_name,
                          'price_cents', r.price_cents, 'gifted', r.gifted)
                        order by r.pick_number)
                   from public.roster_entries r
                  where r.room_id = v_room.id and r.player_id = pl.id), '[]'::jsonb))
             order by pl.seat)
        from public.players pl where pl.room_id = v_room.id), '[]'::jsonb),
    'your_vote', v_mine,
    'tally', case when v_mine is null then null
                  else public.df20_audience_tally(v_room.id) end);
end $$;
grant execute on function public.get_audience_state(text, text) to anon, authenticated;

-- ── and the vote itself ───────────────────────────────────────────────────
create or replace function public.cast_audience_vote(
  p_code text, p_voter_key text, p_winner_player_id uuid
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_key text; v_ref text;
begin
  v_key := public.df20_clean_text(p_voter_key, 64);
  if length(v_key) < 16 then raise exception 'DF20_BAD_VOTE'; end if;

  v_ref := btrim(coalesce(p_code, ''));
  if v_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into v_room from public.rooms where id = v_ref::uuid for update;
  else
    select * into v_room from public.rooms where code = upper(v_ref) for update;
  end if;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  if v_room.status <> 'complete' then raise exception 'DF20_NOT_COMPLETE'; end if;
  if not public.df20_room_vote_enabled(v_room.id) then
    raise exception 'DF20_PREMIUM_REQUIRED';
  end if;
  if not exists (select 1 from public.players
                  where id = p_winner_player_id and room_id = v_room.id)
    then raise exception 'DF20_BAD_VOTE'; end if;

  if not public.df20_rate_limit('aud_vote', v_key, 20, 3600) then
    raise exception 'DF20_RATE_LIMITED';
  end if;

  insert into public.audience_votes (room_id, voter_key, winner_player_id)
  values (v_room.id, v_key, p_winner_player_id)
  on conflict (room_id, voter_key) do nothing;

  begin
    perform realtime.send(
      public.df20_audience_tally(v_room.id), 'audience',
      'room:' || v_room.id::text, false);
  exception when others then null;
  end;

  return public.get_audience_state(v_room.id::text, v_key);
end $$;
grant execute on function public.cast_audience_vote(text, text, uuid) to anon, authenticated;

-- ─────────── 0034_free_vote.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0034 · the audience vote goes back to free
--
-- 0033 put it behind the paywall. That was the wrong lever: the vote link is
-- how somebody who has never heard of this app meets it. A stranger opens it,
-- argues about two rosters, and is asked whether they could draft better —
-- which is the only path here that reaches people with no prior contact.
-- Charging the host for it converts a few and costs all the reach.
--
-- The split that survives is the honest one:
--
--   FREE     the public vote link, the blind tally, the call to action
--   PREMIUM  the HOST's live dashboard — watching the tally move in the
--            Content tab while it happens. That is a production tool, not
--            distribution, and it stays behind the line.
--
-- Everything else 0033 did stands: host-supplied categories are still premium.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.get_audience_state(p_code text, p_voter_key text)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_mine uuid; v_key text;
begin
  v_key := btrim(coalesce(p_code, ''));
  if v_key ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into v_room from public.rooms where id = v_key::uuid;
  else
    select * into v_room from public.rooms where code = upper(v_key);
  end if;
  if not found then return jsonb_build_object('status','gone'); end if;

  if v_room.status <> 'complete' then
    return jsonb_build_object('status','not_finished', 'title', v_room.title,
                              'room_id', v_room.id, 'code', v_room.code);
  end if;

  select winner_player_id into v_mine from public.audience_votes
   where room_id = v_room.id and voter_key = coalesce(p_voter_key, '');

  return jsonb_build_object(
    'status', 'open',
    'room_id', v_room.id,
    'code', v_room.code,
    'title', v_room.title,
    'category', v_room.category_name,
    'roster_size', v_room.roster_size,
    'starting_cents', v_room.starting_bankroll_cents,
    'players', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', pl.id, 'seat', pl.seat, 'name', pl.display_name,
               'leftover_cents', pl.bankroll_cents,
               'spent_cents', coalesce((select sum(r.price_cents) from public.roster_entries r
                                         where r.room_id = v_room.id and r.player_id = pl.id), 0),
               'rows', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'pick', r.pick_number, 'item', r.item_name,
                          'price_cents', r.price_cents, 'gifted', r.gifted)
                        order by r.pick_number)
                   from public.roster_entries r
                  where r.room_id = v_room.id and r.player_id = pl.id), '[]'::jsonb))
             order by pl.seat)
        from public.players pl where pl.room_id = v_room.id), '[]'::jsonb),
    'your_vote', v_mine,
    'tally', case when v_mine is null then null
                  else public.df20_audience_tally(v_room.id) end);
end $$;

create or replace function public.cast_audience_vote(
  p_code text, p_voter_key text, p_winner_player_id uuid
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_key text; v_ref text;
begin
  v_key := public.df20_clean_text(p_voter_key, 64);
  if length(v_key) < 16 then raise exception 'DF20_BAD_VOTE'; end if;

  v_ref := btrim(coalesce(p_code, ''));
  if v_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into v_room from public.rooms where id = v_ref::uuid for update;
  else
    select * into v_room from public.rooms where code = upper(v_ref) for update;
  end if;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  if v_room.status <> 'complete' then raise exception 'DF20_NOT_COMPLETE'; end if;
  if not exists (select 1 from public.players
                  where id = p_winner_player_id and room_id = v_room.id)
    then raise exception 'DF20_BAD_VOTE'; end if;

  if not public.df20_rate_limit('aud_vote', v_key, 20, 3600) then
    raise exception 'DF20_RATE_LIMITED';
  end if;

  insert into public.audience_votes (room_id, voter_key, winner_player_id)
  values (v_room.id, v_key, p_winner_player_id)
  on conflict (room_id, voter_key) do nothing;

  begin
    perform realtime.send(
      public.df20_audience_tally(v_room.id), 'audience',
      'room:' || v_room.id::text, false);
  exception when others then null;
  end;

  return public.get_audience_state(v_room.id::text, v_key);
end $$;

grant execute on function public.get_audience_state(text, text) to anon, authenticated;
grant execute on function public.cast_audience_vote(text, text, uuid) to anon, authenticated;

-- nothing gates on this any more, and a dead gate is worse than none: the
-- next person to read it would assume the vote is still paid for
drop function if exists public.df20_room_vote_enabled(uuid);

-- ─────────── 0035_load_indexes.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0035 · the indexes a spike needs
--
-- Measured, not guessed. On a 20k-room / 40k-player copy of this schema the
-- plans before these indexes were:
--
--   players by profile_id      Seq Scan, 40,000 rows read to return 60   2.28ms
--   rooms by host_profile_id   Seq Scan, 20,000 rows read to return 25   0.96ms
--   rooms by created_at        Seq Scan                                  2.20ms
--
-- Small numbers on a laptop with warm cache and no concurrency. The problem
-- is the SHAPE: every one is O(table), so they degrade linearly with growth
-- while the request rate is climbing at the same time.
--
-- Where they are on a hot path:
--   players.profile_id       my_profile_stats + my_scouting_report — every
--                            profile page load, twice
--   rooms.host_profile_id    df20_export_style — EVERY results card render,
--                            which is the image a viral post embeds
--   rooms.created_at         admin_activity, fourteen times per page load
--
-- The bid path was already correct: session_token lookup is an index scan on
-- players_token_idx, so the hottest write in the app never needed this.
-- ═══════════════════════════════════════════════════════════════════════════

-- partial: a room with no host account, or an anonymous seat, is not something
-- anybody looks up BY that column
create index if not exists players_profile_idx
  on public.players(profile_id) where profile_id is not null;

create index if not exists rooms_host_profile_idx
  on public.rooms(host_profile_id) where host_profile_id is not null;

create index if not exists rooms_created_idx
  on public.rooms(created_at);

-- the tally is the viral query: one room, thousands of rows, aggregated on
-- every spectator poll. Covering (room_id, winner_player_id) lets it group
-- without touching the heap.
create index if not exists audience_votes_tally_idx
  on public.audience_votes(room_id, winner_player_id);

-- admin_activity counts by status; cheap to serve from an index
create index if not exists rooms_status_idx
  on public.rooms(status) where code is not null;

-- ─────────── 0036_tally_poll.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0036 · a tally a spectator can poll without breaking the blind
--
-- The vote page opens a realtime connection PER VIEWER. One popular link can
-- therefore consume more realtime connections on its own than every live game
-- combined — during exactly the spike this is meant to survive. Polling is the
-- right trade for a number that changes every few seconds.
--
-- But polling needs an endpoint, and the obvious one breaks the blind rule:
-- a public "give me the tally" RPC hands the answer to anyone who never voted,
-- and the anon key is in every browser.
--
-- So the rule stays in the database. This returns the tally ONLY to a voter
-- key that has actually voted in that room. Calling it directly with the anon
-- key gets you nothing you had not already earned.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.get_audience_tally_for_voter(
  p_code text, p_voter_key text
) returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_ref text;
begin
  v_ref := btrim(coalesce(p_code, ''));
  if v_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into v_room from public.rooms where id = v_ref::uuid;
  else
    select * into v_room from public.rooms where code = upper(v_ref);
  end if;
  if not found or v_room.status <> 'complete' then
    return jsonb_build_object('status','gone');
  end if;

  -- THE BLIND RULE, still enforced here and not in the route
  if not exists (select 1 from public.audience_votes
                  where room_id = v_room.id
                    and voter_key = coalesce(p_voter_key, '')) then
    return jsonb_build_object('status','not_voted');
  end if;

  return jsonb_build_object('status','open',
                            'tally', public.df20_audience_tally(v_room.id));
end $$;
grant execute on function public.get_audience_tally_for_voter(text, text) to anon, authenticated;

-- ─────────── 0037_circuit_breaker.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0037 · a global budget for somebody else's API
--
-- The per-account limit (10 lookups/hour) protects US from one user. It does
-- nothing about a thousand hosts each making their first perfectly legitimate
-- lookup during a spike — every one within its own budget, all of it landing
-- on Wikimedia at once. Getting the app's egress IP throttled or blocked by
-- Wikidata is a self-inflicted outage that no per-account rule can prevent.
--
-- So there is a second, GLOBAL budget on top. When aggregate lookups exceed
-- it in a short window, the category chain stops calling out and falls
-- straight to the manual-setup path — which already exists, already works,
-- and is a far better outcome than being blocked for a day.
--
-- Reuses df20_rate_limit: same fixed-window table, same failure posture
-- (fails OPEN, because a broken limiter must not take down room creation).
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.df20_external_budget(p_service text)
returns boolean language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_limit int; v_window int := 60;
begin
  -- Per MINUTE, aggregate across every account. Wikimedia's published
  -- courtesy guidance is well above these; the point is to stay obviously
  -- polite under a surge, not to run near any documented ceiling.
  v_limit := case p_service
               when 'wikidata'  then 30   -- SPARQL is the expensive one
               when 'wikipedia' then 60
               when 'pageviews' then 60
               else 30
             end;

  return public.df20_rate_limit('global_' || p_service, 'all', v_limit, v_window);
end $$;
grant execute on function public.df20_external_budget(text) to anon, authenticated;

-- ─────────── 0038_signup_signals.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0038 · signals for a human to read, not a verdict to act on
--
-- Every column here is EVIDENCE, not a judgement. A shared IP is a household,
-- a school, or a coffee shop far more often than it is a bot farm. A
-- disposable address is somebody who does not trust us yet. Verifying in four
-- seconds is a password manager. None of it proves anything on its own, and
-- nothing in this schema flags, suspends, or revokes: there is no status
-- column to set, deliberately, so no future code can quietly start acting on
-- a guess.
--
-- The rule this encodes: a false positive against a real player costs more
-- than a slow manual review.
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.signup_signals (
  profile_id  uuid primary key references public.profiles(id) on delete cascade,
  ip          text,
  user_agent  text,
  referrer    text,
  email_domain text,
  disposable  boolean not null default false,
  -- 'passed' | 'skipped' (no keys configured) | 'failed'
  turnstile   text not null default 'skipped',
  created_at  timestamptz not null default now()
);

create index if not exists signup_signals_ip_idx on public.signup_signals(ip) where ip is not null;
create index if not exists signup_signals_created_idx on public.signup_signals(created_at);

alter table public.signup_signals enable row level security;
revoke all on public.signup_signals from anon, authenticated;

comment on table public.signup_signals is
  'Signup-time evidence for manual admin review. Deliberately has no verdict '
  'or status column: nothing automated may act on these.';

-- ── the disposable-domain list ────────────────────────────────────────────
-- A signal, never a block. Somebody using a burner address is usually just
-- cautious, and the list is always out of date in both directions.
create table if not exists public.disposable_domains (
  domain text primary key
);
alter table public.disposable_domains enable row level security;
revoke all on public.disposable_domains from anon, authenticated;

insert into public.disposable_domains (domain) values
  ('mailinator.com'),('guerrillamail.com'),('guerrillamail.net'),('10minutemail.com'),
  ('tempmail.com'),('temp-mail.org'),('throwawaymail.com'),('yopmail.com'),
  ('sharklasers.com'),('grr.la'),('trashmail.com'),('getnada.com'),('dispostable.com'),
  ('maildrop.cc'),('fakeinbox.com'),('mailnesia.com'),('mytemp.email'),('moakt.com'),
  ('emailondeck.com'),('tempr.email'),('spamgourmet.com'),('mohmal.com'),
  ('burnermail.io'),('anonaddy.me'),('mailsac.com'),('inboxkitten.com'),
  ('tempmailo.com'),('minuteinbox.com'),('luxusmail.org'),('vomoto.com')
on conflict (domain) do nothing;

-- ── the write path ────────────────────────────────────────────────────────
-- Called by the signup route with the shared secret, same posture as the
-- billing and wiki writers: no service-role key anywhere in this project.
create or replace function public.df20_record_signup(
  p_secret text, p_profile_id uuid, p_ip text, p_user_agent text,
  p_referrer text, p_email text, p_turnstile text
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_expected text; v_domain text; v_disposable boolean;
begin
  select value into v_expected from public.df20_config where key = 'wiki_write_secret';
  if v_expected is null or p_secret is null or p_secret <> v_expected then
    raise exception 'DF20_NOT_AUTHORISED';
  end if;
  if p_profile_id is null then return jsonb_build_object('recorded', false); end if;

  v_domain := lower(split_part(coalesce(p_email, ''), '@', 2));
  v_disposable := v_domain <> ''
    and exists (select 1 from public.disposable_domains d where d.domain = v_domain);

  insert into public.signup_signals
    (profile_id, ip, user_agent, referrer, email_domain, disposable, turnstile)
  values (p_profile_id,
          nullif(left(coalesce(p_ip, ''), 45), ''),
          nullif(left(coalesce(p_user_agent, ''), 400), ''),
          nullif(left(coalesce(p_referrer, ''), 300), ''),
          nullif(v_domain, ''),
          v_disposable,
          case when p_turnstile in ('passed','failed','skipped') then p_turnstile else 'skipped' end)
  on conflict (profile_id) do nothing;

  return jsonb_build_object('recorded', true, 'disposable', v_disposable);
end $$;
revoke all on function public.df20_record_signup(text,uuid,text,text,text,text,text) from public;
revoke all on function public.df20_record_signup(text,uuid,text,text,text,text,text) from anon, authenticated;

-- ─────────── 0039_admin_signals.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0039 · the trust-signals view, for an admin to read
--
-- Everything behavioural is DERIVED at read time rather than stored: time to
-- verify, time to first action, how many accounts share an IP. Storing them
-- would mean a number that silently goes stale and, worse, a number that
-- looks like a fact. Computing on read means what an admin sees is what is
-- true when they look at it.
--
-- There is no score. Deliberately. A single number invites acting on the
-- number instead of reading the evidence, and the whole point of this table
-- is that no single signal is proof. `worth_review` exists as the mildest
-- possible nudge — it counts how many signals are present, and an admin who
-- disagrees with it can ignore it with no consequence.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.admin_user_signals(
  p_query text default null,
  p_filter text default 'all'
) returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_q text; v_f text;
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  v_q := lower(btrim(coalesce(p_query, '')));
  v_f := coalesce(nullif(btrim(lower(p_filter)), ''), 'all');

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select
        p.id,
        p.email,
        p.handle,
        p.created_at,
        coalesce(p.premium_until > now(), false) as premium,
        s.ip,
        s.user_agent,
        s.referrer,
        s.disposable,
        s.turnstile,

        -- how many OTHER accounts signed up from this address. Shared IPs are
        -- households and schools far more often than anything else, so this
        -- is a count to read, not a threshold to trip.
        case when s.ip is null then null else (
          select count(*) - 1 from public.signup_signals o where o.ip = s.ip
        ) end as ip_shared_with,

        -- confirmed in a couple of seconds is a password manager as often as
        -- it is a script; never confirmed is usually somebody who lost interest
        -- measured from profiles.created_at, not auth.users.created_at: the
        -- trigger creates them in the same transaction, and this keeps the
        -- function independent of the auth schema's shape
        (select extract(epoch from (u.email_confirmed_at - p.created_at))::int
           from auth.users u where u.id = p.id) as seconds_to_verify,

        -- the strongest single signal here, and still not proof: an account
        -- that confirmed an address and then never played anything
        -- least() ignores NULLs in Postgres, so an account with no players
        -- row and no hosted room yields NULL rather than a sentinel — and
        -- NULL is exactly what "never did anything" should read as. An
        -- earlier version used 'infinity' here and threw "cannot convert
        -- infinity to integer" on precisely the accounts this feature exists
        -- to surface.
        (select extract(epoch from (least(
                  (select min(pl.created_at) from public.players pl
                    where pl.profile_id = p.id),
                  (select min(r.created_at) from public.rooms r
                    where r.host_profile_id = p.id)
                ) - p.created_at))::int) as seconds_to_first_action,

        -- rate limiting the app already does elsewhere, surfaced here rather
        -- than left in a table nobody reads
        (select coalesce(sum(rl.count), 0) from public.rate_limits rl
          where rl.subject = p.id::text) as rate_limit_hits

      from public.profiles p
      left join public.signup_signals s on s.profile_id = p.id
      where (v_q = ''
             or lower(coalesce(p.email, '')) like '%' || v_q || '%'
             or lower(coalesce(p.handle, '')) like '%' || v_q || '%'
             or coalesce(s.ip, '') like '%' || v_q || '%')
      order by p.created_at desc
      limit 300
    ) x
    where case v_f
      when 'disposable' then (x.disposable is true)
      when 'shared_ip'  then coalesce(x.ip_shared_with, 0) > 0
      when 'no_action'  then x.seconds_to_first_action is null
      when 'unverified' then x.seconds_to_verify is null
      when 'fast_verify' then coalesce(x.seconds_to_verify, 99999) < 15
      else true
    end), '[]'::jsonb);
end $$;
grant execute on function public.admin_user_signals(text, text) to authenticated;

-- ─────────── 0040_signal_sanity.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0040 · absence of evidence is not evidence
--
-- 0039 flagged essentially every account, including the creator's. Two bugs,
-- both the same mistake in different clothes: treating MISSING DATA as a
-- SIGNAL.
--
--   1. NEGATIVE DURATIONS. seconds_to_verify is measured from
--      profiles.created_at, but 0032 backfilled profile rows for accounts
--      that already existed — so the profile row is NEWER than the
--      confirmation it is being compared against, and the difference comes
--      out negative. Negative then trivially satisfies "< 15 seconds", so the
--      oldest and most legitimate accounts in the system — the creator's
--      first of all — got flagged as "verified instantly". A negative
--      duration does not mean somebody verified before signing up. It means
--      the two timestamps are not comparable, which is not a signal at all.
--
--   2. NO SIGNUP RECORD AT ALL. Every account created before 0038 has no
--      signup_signals row. That is not suspicious, it is chronology. These
--      now report has_signup_record = false so the UI can say so plainly
--      instead of rendering blanks as findings.
--
-- The rule this restores: a signal has to be something we OBSERVED, not
-- something we failed to observe.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.admin_user_signals(
  p_query text default null,
  p_filter text default 'all'
) returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_q text; v_f text;
begin
  if not public.df20_is_admin() then raise exception 'DF20_NOT_AUTHORISED'; end if;
  v_q := lower(btrim(coalesce(p_query, '')));
  v_f := coalesce(nullif(btrim(lower(p_filter)), ''), 'all');

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select
        p.id, p.email, p.handle, p.created_at,
        coalesce(p.premium_until > now(), false) as premium,
        s.ip, s.user_agent, s.referrer, s.disposable, s.turnstile,

        -- chronology, not suspicion
        (s.profile_id is not null) as has_signup_record,

        case when s.ip is null then null else (
          select count(*) - 1 from public.signup_signals o where o.ip = s.ip
        ) end as ip_shared_with,

        -- a negative gap means the profile row was backfilled after the
        -- confirmation it is measured against; report unknown, not "instant"
        (select case when v >= 0 then v end from (
           select extract(epoch from (u.email_confirmed_at - p.created_at))::int as v
             from auth.users u where u.id = p.id) q) as seconds_to_verify,

        (select case when v >= 0 then v end from (
           select extract(epoch from (least(
                    (select min(pl.created_at) from public.players pl
                      where pl.profile_id = p.id),
                    (select min(r.created_at) from public.rooms r
                      where r.host_profile_id = p.id)
                  ) - p.created_at))::int as v) q) as seconds_to_first_action,

        -- did they ever actually do anything, independent of WHEN. This is
        -- the honest version of "never played": a fact about activity, not a
        -- byproduct of two timestamps that may not line up.
        (exists (select 1 from public.players pl where pl.profile_id = p.id)
         or exists (select 1 from public.rooms r where r.host_profile_id = p.id))
          as has_played,

        (select coalesce(sum(rl.count), 0) from public.rate_limits rl
          where rl.subject = p.id::text) as rate_limit_hits

      from public.profiles p
      left join public.signup_signals s on s.profile_id = p.id
      where (v_q = ''
             or lower(coalesce(p.email, '')) like '%' || v_q || '%'
             or lower(coalesce(p.handle, '')) like '%' || v_q || '%'
             or coalesce(s.ip, '') like '%' || v_q || '%')
      order by p.created_at desc
      limit 300
    ) x
    where case v_f
      when 'disposable'  then (x.disposable is true)
      when 'shared_ip'   then coalesce(x.ip_shared_with, 0) > 0
      when 'no_action'   then x.has_played = false
      when 'unverified'  then x.seconds_to_verify is null and x.has_signup_record
      when 'fast_verify' then coalesce(x.seconds_to_verify, 99999) < 15
      else true
    end), '[]'::jsonb);
end $$;
grant execute on function public.admin_user_signals(text, text) to authenticated;

-- ─────────── 0041_profiles_grant_hardening.sql ───────────

-- 0041_profiles_grant_hardening.sql
--
-- profiles and templates were left with blanket table grants to anon and
-- authenticated. RLS is what actually holds them shut, and for anon it does:
-- there is no anon policy, so every read and write is denied. For a SIGNED-IN
-- caller it does not, because profiles_update_own permits any update to the
-- caller's own row -- and premium_until lives on that row.
--
-- The gap: PATCH /rest/v1/profiles?id=eq.<own uid>
--           {"premium_until":"2099-01-01T00:00:00Z"}
-- grants the caller permanent premium. df20_premium_active() reads that column
-- and nothing else, exactly as designed, so every gate in the app opens.
--
-- The fix is column-scoped grants. The app only ever writes the five identity
-- and branding columns (HostClient.tsx saveProfile); premium_until,
-- premium_source, subscription_status and the stripe_* columns are written
-- solely by df20_apply_billing_event / df20_revoke_premium / admin_set_premium,
-- which are SECURITY DEFINER and bypass grants. export_* is written by
-- save_export_style, likewise SECURITY DEFINER. So nothing legitimate loses a
-- write path here.
--
-- Re-runnable. Grants are idempotent and revokes on already-revoked
-- privileges are a no-op.

-- anon has no policy on either table and therefore no legitimate access at all
revoke all on public.profiles  from anon;
revoke all on public.templates from anon;

-- drop the blanket write grants before re-issuing them per column
revoke insert, update, delete, truncate, references on public.profiles from authenticated;

-- what the app genuinely writes, and nothing else
grant select on public.profiles to authenticated;
grant insert (id, email, display_name, brand_accent, brand_logo_url)
  on public.profiles to authenticated;
grant update (email, display_name, brand_accent, brand_logo_url)
  on public.profiles to authenticated;

-- templates carries no privileged column, but it does not need DDL-adjacent
-- privileges either
revoke truncate, references on public.templates from authenticated;

-- Assert the hole is actually shut, both ways round, the way v6_premium.sql
-- asserts the watermark. A blanket re-grant on profiles (a future
-- "grant all on all tables in schema public to authenticated" would do it)
-- silently reopens permanent free premium for every signed-in user, so this
-- fails loudly rather than waiting to be noticed.
do $$
declare v_bad text[] := '{}';
begin
  -- privileged columns must NOT be writable by a signed-in caller
  if has_column_privilege('authenticated','public.profiles','premium_until','UPDATE')
    then v_bad := v_bad || 'authenticated can UPDATE profiles.premium_until'; end if;
  if has_column_privilege('authenticated','public.profiles','premium_source','UPDATE')
    then v_bad := v_bad || 'authenticated can UPDATE profiles.premium_source'; end if;
  if has_column_privilege('authenticated','public.profiles','subscription_status','UPDATE')
    then v_bad := v_bad || 'authenticated can UPDATE profiles.subscription_status'; end if;
  if has_column_privilege('authenticated','public.profiles','stripe_customer_id','UPDATE')
    then v_bad := v_bad || 'authenticated can UPDATE profiles.stripe_customer_id'; end if;
  if has_table_privilege('anon','public.profiles','SELECT')
    then v_bad := v_bad || 'anon can SELECT profiles'; end if;

  -- NO assertion here that the branding columns are still writable. 0042
  -- revokes every write grant on this table and moves the write behind
  -- save_profile(), so asserting the grants this file just issued would be
  -- asserting an intermediate state that the very next migration removes on
  -- purpose. df20_grant_check() in 0042 is the assertion that describes the
  -- end state; this one only has to say the privileged columns are shut.

  if coalesce(array_length(v_bad,1),0) > 0 then
    raise exception E'DF20_PROFILE_GRANTS_WRONG\n  %', array_to_string(v_bad, E'\n  ');
  end if;
  raise notice 'profiles grants ok - premium columns are RPC-only';
end $$;

-- ─────────── 0042_write_paths_and_grant_check.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0042 · the last direct table write, and a check that keeps
--                     0041 from silently coming undone
--
-- 0041 scoped the grants on public.profiles to the columns the app actually
-- writes. That closed the escalation, but it also broke the one place that
-- still wrote the table directly: HostClient.saveProfile() used a PostgREST
-- upsert, and PostgREST compiles an upsert to
--
--     insert ... on conflict (id) do update set id = excluded.id, ...
--
-- which needs UPDATE on `id`. Granting that back would work and would even be
-- safe (profiles_update_own's WITH CHECK pins id to auth.uid(), so the column
-- cannot be pointed at anyone else) — but it would leave the client holding a
-- write grant on a table that carries premium_until and stripe_customer_id,
-- and the next column added to that table would be exposed by default. That
-- is the shape of the bug 0041 just fixed.
--
-- So the write moves behind a SECURITY DEFINER function instead, exactly like
-- save_export_style, and `authenticated` keeps no write grant on profiles at
-- all. SELECT stays: RLS already scopes it to the caller's own row and two
-- pages read their own branding back.
--
-- Re-runnable.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── the profile write, as an RPC ──────────────────────────────────────────
-- Same validation the room branding already goes through: an accent must be
-- a hex colour, and a logo must live in our own storage bucket, because both
-- are rendered into an image other people end up looking at.
create or replace function public.save_profile(
  p_display_name text, p_brand_accent text, p_brand_logo_url text
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_uid uuid; v_name text; v_accent text;
begin
  -- creates the row on first save, and returns null when signed out
  v_uid := public.df20_ensure_profile();
  if v_uid is null then raise exception 'DF20_SIGNIN_REQUIRED'; end if;

  v_name := public.df20_clean_text(p_display_name, 40);
  if v_name = '' then v_name := null; end if;

  v_accent := public.df20_clean_text(p_brand_accent, 9);
  if v_accent = '' then v_accent := null; end if;
  if v_accent is not null and v_accent !~ '^#[0-9A-Fa-f]{6}$'
    then raise exception 'DF20_BAD_ACCENT'; end if;

  update public.profiles
     set display_name    = v_name,
         brand_accent    = v_accent,
         -- raises DF20_BAD_LOGO_URL on anything outside our storage bucket
         brand_logo_url  = public.df20_clean_logo_url(p_brand_logo_url),
         updated_at      = now()
   where id = v_uid;

  -- email is NOT taken from the caller. df20_ensure_profile reads it from
  -- auth.users, which is the only place it is authoritative.
  return (select jsonb_build_object(
                   'display_name', p.display_name,
                   'brand_accent', p.brand_accent,
                   'brand_logo_url', p.brand_logo_url)
            from public.profiles p where p.id = v_uid);
end $$;
grant execute on function public.save_profile(text, text, text) to authenticated;

-- ── nothing writes profiles directly any more ─────────────────────────────
revoke insert, update, delete, truncate, references on public.profiles from anon, authenticated;
revoke all on public.profiles from anon;
grant select on public.profiles to authenticated;

-- ── the assertion that keeps this fixed ───────────────────────────────────
-- df20_selfcheck() asserts that things EXIST. This asserts that things are
-- NOT reachable, which is the half that was missing when profiles shipped
-- with a blanket grant. Called from the end of the bundle next to selfcheck.
create or replace function public.df20_grant_check()
returns text language plpgsql stable as $$
declare
  v_bad text[] := '{}';
  c text;
  -- columns a signed-in caller must never be able to write to their own row.
  -- premium_until IS the premium gate; stripe_customer_id is the identity the
  -- billing portal opens a session for.
  v_locked text[] := array['premium_until','premium_source','subscription_status',
                           'stripe_customer_id','stripe_subscription_id',
                           'export_watermark','export_logo_url','export_accent',
                           'export_handle','id','created_at'];
begin
  foreach c in array v_locked loop
    if has_column_privilege('authenticated', 'public.profiles', c, 'UPDATE') then
      v_bad := v_bad || ('authenticated can UPDATE profiles.' || c);
    end if;
  end loop;

  if has_table_privilege('authenticated', 'public.profiles', 'INSERT') then
    v_bad := v_bad || 'authenticated can INSERT profiles (use save_profile)';
  end if;

  foreach c in array array['SELECT','INSERT','UPDATE','DELETE'] loop
    if has_table_privilege('anon', 'public.profiles', c) then
      v_bad := v_bad || ('anon can ' || c || ' profiles');
    end if;
    if has_table_privilege('anon', 'public.templates', c) then
      v_bad := v_bad || ('anon can ' || c || ' templates');
    end if;
  end loop;

  -- the read path the whole deck-secrecy rule rests on
  if has_table_privilege('anon', 'public.room_deck', 'SELECT')
     or has_table_privilege('authenticated', 'public.room_deck', 'SELECT') then
    v_bad := v_bad || 'room_deck is directly readable';
  end if;

  if coalesce(array_length(v_bad, 1), 0) > 0 then
    raise exception E'DF20_GRANT_CHECK_FAILED\n  %', array_to_string(v_bad, E'\n  ');
  end if;

  return format('ok - %s locked columns, anon shut out of profiles/templates, deck sealed',
                array_length(v_locked, 1));
end $$;
revoke all on function public.df20_grant_check() from anon, authenticated;

-- ── pin search_path on every remaining df20_ function ─────────────────────
-- All of these are SECURITY INVOKER, so none of them was the classic definer
-- hijack. Pinning them anyway costs nothing and clears the advisor, and means
-- a function that later becomes SECURITY DEFINER does not have to remember.
-- Generated rather than listed: a hardcoded signature list is the thing that
-- goes stale.
--
-- RUNS LAST, deliberately: it pins whatever exists at the time it runs, so
-- putting it above df20_grant_check() would skip the function this migration
-- had just created. That is exactly how the first pass left two behind.
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname like 'df20\_%'
              and p.proconfig is null
              and p.prokind = 'f'
  loop
    execute format('alter function %s set search_path = public, pg_temp', r.sig);
  end loop;
end $$;

-- ─────────── 0043_item_images.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0043 · a picture on the card being auctioned
--
-- Carries an image the whole length of the existing chain:
--
--   wikipedia_cache_items ─┐
--   category_library_items ├─> room_pool ─> room_deck ─> lots ─> public_state
--   user_category_items   ─┘
--
-- THE LEAK RULE STILL GOVERNS. An image URL identifies an item as surely as
-- its name does, so it travels exactly where the name travels and no further:
-- into `lots` at reveal, never into any pre-deal projection. `room_deck`
-- keeps it hidden until dealt, and df20_public_state only ever counts
-- unrevealed deck rows.
--
-- NULL image_url is not a failure. It means "no picture was found", and the
-- client draws a generated card from the item name instead — deterministic,
-- always available, and free of the storage cost of stashing a data: URI on
-- every row. Only real remote URLs are stored here.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── a stored URL is rendered into an <img> later, so it is validated on the
--    way in, exactly as brand logos are by df20_clean_logo_url ─────────────
--
-- Allowlist rather than a scheme check: https alone would happily accept an
-- attacker-controlled host, and every source we actually use is known. A URL
-- that fails returns null, which degrades to a generated card rather than
-- failing the draft.
create or replace function public.df20_clean_image_url(p_in text)
returns text language plpgsql immutable
set search_path = public, pg_temp as $$
declare v text;
begin
  v := btrim(coalesce(p_in, ''));
  if length(v) = 0 or length(v) > 600 then return null; end if;
  if v !~ '^https://' then return null; end if;
  if v !~* '^https://(upload\.wikimedia\.org|commons\.wikimedia\.org|coverartarchive\.org|covers\.openlibrary\.org)/' then
    return null;
  end if;
  -- no control characters, no quote that could break out of an attribute
  if v ~ '[[:cntrl:]"''<>]' then return null; end if;
  return v;
end $$;

-- ── columns ───────────────────────────────────────────────────────────────
alter table public.wikipedia_cache_items
  add column if not exists image_url     text,
  add column if not exists image_license text;
alter table public.category_library_items
  add column if not exists image_url     text,
  add column if not exists image_license text;
alter table public.room_pool
  add column if not exists image_url     text,
  add column if not exists image_license text;
alter table public.room_deck
  add column if not exists image_url     text,
  add column if not exists image_license text;
alter table public.lots
  add column if not exists image_url     text,
  add column if not exists image_license text;

do $$ begin
  alter table public.user_category_items
    add column if not exists image_url     text,
    add column if not exists image_license text;
exception when undefined_table then null; end $$;

-- 'generated' is never stored: a generated card has no URL, so it is a null
-- image_url and a null licence. Only fetched images carry a label.
do $$ begin
  alter table public.wikipedia_cache_items add constraint wci_license_chk
    check (image_license is null or image_license in ('free','nonfree'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.room_deck add constraint room_deck_license_chk
    check (image_license is null or image_license in ('free','nonfree'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.lots add constraint lots_license_chk
    check (image_license is null or image_license in ('free','nonfree'));
exception when duplicate_object then null; end $$;

-- ── cache the images alongside the names ──────────────────────────────────
-- The six-argument form is the implementation and takes NO defaults, so the
-- four-argument form below can survive as a real function rather than being
-- shadowed — a defaulted overload would make every four-argument call
-- ambiguous instead of resolving.
--
-- Keeping the old signature alive is not politeness: df20_selfcheck()
-- asserts `df20_cache_wikipedia(text,text,text,text[])` in four places across
-- the bundle, and dropping it would fail the selfcheck everywhere.
create or replace function public.df20_cache_wikipedia(
  p_secret text, p_query text, p_title text, p_items text[],
  p_images text[], p_licenses text[]
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_q text; v_id uuid; v_n int; v_clean text; v_expected text;
        v_img text; v_lic text; i int;
begin
  select value into v_expected from public.df20_config where key = 'wiki_write_secret';
  if v_expected is null or p_secret is null or p_secret <> v_expected then
    raise exception 'DF20_NOT_AUTHORISED';
  end if;

  v_q := public.df20_norm_category(p_query);
  if length(v_q) = 0 then raise exception 'DF20_BAD_CATEGORY'; end if;

  insert into public.wikipedia_cache (query_norm, article_title)
  values (v_q, public.df20_clean_text(p_title, 120))
  on conflict (query_norm) do update set article_title = excluded.article_title,
                                         fetched_at = now()
  returning id into v_id;

  delete from public.wikipedia_cache_items where cache_id = v_id;

  -- indexed rather than FOREACH: the image arrays are positional, and a
  -- skipped short name must not slide every later picture onto the wrong item
  for i in 1 .. coalesce(array_length(p_items, 1), 0) loop
    v_clean := public.df20_clean_text(p_items[i], 60);
    if length(coalesce(v_clean, '')) >= 2 then
      v_img := public.df20_clean_image_url(
                 case when p_images is null or i > coalesce(array_length(p_images,1),0)
                      then null else p_images[i] end);
      v_lic := case when p_licenses is null or i > coalesce(array_length(p_licenses,1),0)
                    then null else p_licenses[i] end;
      if v_img is null then v_lic := null; end if;         -- keep the pair honest
      if v_lic is not null and v_lic not in ('free','nonfree') then v_lic := null; end if;

      insert into public.wikipedia_cache_items (cache_id, name, image_url, image_license)
      values (v_id, v_clean, v_img, v_lic) on conflict do nothing;
    end if;
  end loop;

  select count(*) into v_n from public.wikipedia_cache_items where cache_id = v_id;
  return jsonb_build_object('source','wikipedia','source_id',v_id,
                            'name',p_title,'item_count',v_n);
end $$;
grant execute on function
  public.df20_cache_wikipedia(text,text,text,text[],text[],text[]) to anon, authenticated;

-- the pre-image signature, preserved for df20_selfcheck() and for any caller
-- that has not been taught about pictures yet
create or replace function public.df20_cache_wikipedia(
  p_secret text, p_query text, p_title text, p_items text[]
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
begin
  return public.df20_cache_wikipedia(p_secret, p_query, p_title, p_items, null, null);
end $$;
grant execute on function
  public.df20_cache_wikipedia(text,text,text,text[]) to anon, authenticated;

-- ── carry the image into the room pool ────────────────────────────────────
create or replace function public.df20_fill_pool(
  p_room uuid, p_source text, p_ref uuid
) returns int language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_n int; v_name text;
begin
  if p_source in ('builtin','library') then
    if p_ref is null then
      select id into p_ref from public.category_library
       where name_norm = public.df20_norm_category('Football Draft');
    end if;
    select name into v_name from public.category_library where id = p_ref;
    if v_name is null then raise exception 'DF20_NO_SUCH_CATEGORY'; end if;
    insert into public.room_pool (room_id, name, image_url, image_license)
      select p_room, i.name, i.image_url, i.image_license
        from public.category_library_items i where i.library_id = p_ref
      on conflict do nothing;
  elsif p_source = 'wikipedia' then
    select article_title into v_name from public.wikipedia_cache where id = p_ref;
    if v_name is null then raise exception 'DF20_NO_SUCH_CATEGORY'; end if;
    insert into public.room_pool (room_id, name, image_url, image_license)
      select p_room, i.name, i.image_url, i.image_license
        from public.wikipedia_cache_items i where i.cache_id = p_ref
      on conflict do nothing;
  elsif p_source = 'saved' then
    select name into v_name from public.user_categories where id = p_ref;
    if v_name is null then raise exception 'DF20_NO_SUCH_CATEGORY'; end if;
    insert into public.room_pool (room_id, name, image_url, image_license)
      select p_room, i.name, i.image_url, i.image_license
        from public.user_category_items i where i.category_id = p_ref
      on conflict do nothing;
  else
    raise exception 'DF20_BAD_POOL_SOURCE';
  end if;

  select count(*) into v_n from public.room_pool where room_id = p_room;
  update public.rooms
     set pool_source = p_source,
         category_name = coalesce(category_name, v_name)
   where id = p_room;
  return v_n;
end $$;
revoke all on function public.df20_fill_pool(uuid, text, uuid) from anon, authenticated;

-- ── carry it into the deck ────────────────────────────────────────────────
-- Only the deck insert changes; every money and seat rule below it is the
-- 0010 text unchanged.
create or replace function public.start_draft(p_code text, p_token uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_me public.players; v_n int; v_pool int; v_size int;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  select * into v_me from public.players
   where room_id = v_room.id and session_token = p_token;
  if not found then raise exception 'DF20_BAD_TOKEN'; end if;
  if not v_me.is_host then raise exception 'DF20_HOST_ONLY'; end if;
  if v_room.status <> 'lobby' then raise exception 'DF20_ALREADY_STARTED'; end if;

  select count(*) into v_n from public.players where room_id = v_room.id;
  if v_n <> 2 then raise exception 'DF20_NEED_TWO_PLAYERS'; end if;

  select count(*) into v_pool from public.room_pool where room_id = v_room.id;
  if v_pool < v_room.roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;
  v_size := least(greatest(v_room.roster_size * 6, v_room.roster_size * 2 + 4), v_pool);

  insert into public.room_deck (room_id, position, item_name, image_url, image_license)
  select v_room.id, row_number() over (order by s.r), s.name, s.image_url, s.image_license
    from (select name, image_url, image_license, random() as r
            from public.room_pool
           where room_id = v_room.id order by random() limit v_size) s;

  update public.rooms set status = 'live', started_at = now() where id = v_room.id;
  perform public.df20_reveal_next(v_room.id);
  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);
  return public.df20_public_state(v_room.id);
end $$;
grant execute on function public.start_draft(text, uuid) to anon, authenticated;

-- ── and onto the lot, which is the moment it becomes visible ──────────────
-- This is the only place an image crosses from hidden to public. Everything
-- else here is the 0021 text unchanged, including the no-limit deadline.
create or replace function public.df20_reveal_next(p_room uuid)
returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_room public.rooms; v_p1 public.players; v_p2 public.players;
  v_o1 int; v_o2 int; v_opener public.players; v_card record; v_lot uuid;
begin
  select * into v_room from public.rooms where id = p_room;
  select * into v_p1 from public.players where room_id = p_room and seat = 1;
  select * into v_p2 from public.players where room_id = p_room and seat = 2;
  v_o1 := public.df20_open_slots(p_room, v_p1.id);
  v_o2 := public.df20_open_slots(p_room, v_p2.id);

  if v_o1 = 0 and v_o2 = 0 then
    update public.rooms
       set phase = 'complete', status = 'complete',
           completed_at = coalesce(completed_at, now())
     where id = p_room;
    return;
  end if;

  if v_o1 > 0 and v_o2 > 0 then
    v_opener := case when v_room.opener_seat = 1 then v_p1 else v_p2 end;
  elsif v_o1 > 0 then v_opener := v_p1;
  else                v_opener := v_p2;
  end if;

  select d.position as pos, d.item_name as nm,
         d.image_url as img, d.image_license as lic
    into v_card
    from public.room_deck d
   where d.room_id = p_room and d.revealed_at is null
   order by d.position limit 1;

  if not found then
    update public.rooms
       set phase = 'complete', status = 'complete',
           completed_at = coalesce(completed_at, now())
     where id = p_room;
    return;
  end if;

  update public.room_deck set revealed_at = now()
   where room_id = p_room and position = v_card.pos;

  insert into public.lots
    (room_id, item_name, image_url, image_license, opener_player_id, status,
     current_bid_cents, high_bidder_player_id, on_the_clock_player_id,
     turn_expires_at, turn_seq)
  values
    (p_room, v_card.nm, v_card.img, v_card.lic, v_opener.id, 'offered',
     v_room.min_bid_cents, v_opener.id, v_opener.id,
     public.df20_turn_deadline(v_room.timer_seconds), 1)
  returning id into v_lot;

  insert into public.bid_events (room_id, lot_id, player_id, action, amount_cents, turn_seq)
  values (p_room, v_lot, null, 'reveal', v_room.min_bid_cents, 1);

  update public.rooms set phase = 'offering' where id = p_room;
end $$;

-- ── selfcheck: df20_cache_wikipedia changed shape ─────────────────────────
-- search_path is pinned inline: 0042's pinning loop runs BEFORE this file and
-- only touches functions whose proconfig is null, so a df20_ function created
-- afterwards has to pin itself or it stays unpinned forever.
create or replace function public.df20_selfcheck_images()
returns text language plpgsql
set search_path = public, pg_temp as $$
declare v_missing text[] := '{}'; f text; c text;
  v_fns text[] := array[
    'public.df20_clean_image_url(text)',
    'public.df20_cache_wikipedia(text,text,text,text[],text[],text[])'
  ];
  v_cols text[] := array[
    'wikipedia_cache_items.image_url', 'room_pool.image_url',
    'room_deck.image_url', 'lots.image_url', 'lots.image_license'
  ];
begin
  foreach f in array v_fns loop
    if to_regprocedure(f) is null then v_missing := v_missing || f; end if;
  end loop;
  foreach c in array v_cols loop
    if not exists (select 1 from information_schema.columns
                    where table_schema = 'public'
                      and table_name = split_part(c, '.', 1)
                      and column_name = split_part(c, '.', 2)) then
      v_missing := v_missing || c;
    end if;
  end loop;
  if array_length(v_missing, 1) > 0 then
    raise exception 'DF20_SELFCHECK_IMAGES_FAILED: %', array_to_string(v_missing, ', ');
  end if;
  return 'ok: images wired from cache to lot';
end $$;

revoke all on function public.df20_selfcheck_images() from anon, authenticated;

select public.df20_selfcheck_images();

-- ─────────── 0044_onepiece.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0044 · One Piece Characters, with portraits
--
-- GENERATED by scripts/build-onepiece-seed.mjs. Re-run that rather than
-- editing the lists below; the names and the URLs are positional and hand
-- editing one without the other slides every later picture onto the wrong
-- character.
--
-- The first library category to ship with images. 0043 carries image_url the
-- length of the chain (library -> room_pool -> room_deck -> lots), and the
-- leak rule is unchanged: the picture travels exactly where the name travels
-- and reaches a client only when the card is dealt.
--
-- Re-runnable. Both seeds upsert by normalised name.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── the image allowlist gains one host ────────────────────────────────────
-- Everything else about df20_clean_image_url is the 0043 text. MAL portraits
-- are fair-use promotional art, which is the same footing as the non-free
-- Wikipedia infobox leads already allowed, and they are stored as 'nonfree'
-- so a freeOnly policy can drop them as a set.
create or replace function public.df20_clean_image_url(p_in text)
returns text language plpgsql immutable
set search_path = public, pg_temp as $$
declare v text;
begin
  v := btrim(coalesce(p_in, ''));
  if length(v) = 0 or length(v) > 600 then return null; end if;
  if v !~ '^https://' then return null; end if;
  if v !~* '^https://(upload\.wikimedia\.org|commons\.wikimedia\.org|coverartarchive\.org|covers\.openlibrary\.org|cdn\.myanimelist\.net)/' then
    return null;
  end if;
  if v ~ '[[:cntrl:]"''<>]' then return null; end if;
  return v;
end $$;

-- ── seeding a category that has pictures ──────────────────────────────────
-- Four arguments with NO defaults, so the two-argument df20_seed_category
-- survives as a real function rather than becoming an ambiguous call. Same
-- reasoning as the two df20_cache_wikipedia arities in 0043, and the
-- two-argument form is asserted by df20_selfcheck().
--
-- Indexed rather than FOREACH because the arrays are positional: a name that
-- fails df20_clean_text must not shift every following image up by one.
create or replace function public.df20_seed_category(
  p_name text, p_items text[], p_images text[], p_licenses text[]
) returns int language plpgsql security definer
set search_path = public, pg_temp as $fn$
declare v_id uuid; v_clean text; v_img text; v_lic text; v_n int; i int;
begin
  insert into public.category_library (name, name_norm)
  values (p_name, public.df20_norm_category(p_name))
  on conflict (name_norm) do update set name = excluded.name
  returning id into v_id;

  for i in 1 .. coalesce(array_length(p_items, 1), 0) loop
    v_clean := public.df20_clean_text(p_items[i], 60);
    if length(coalesce(v_clean, '')) >= 1 then
      v_img := public.df20_clean_image_url(
                 case when p_images is null or i > coalesce(array_length(p_images, 1), 0)
                      then null else p_images[i] end);
      v_lic := case when p_licenses is null or i > coalesce(array_length(p_licenses, 1), 0)
                    then null else p_licenses[i] end;
      if v_img is null then v_lic := null; end if;      -- keep the pair honest
      if v_lic is not null and v_lic not in ('free', 'nonfree') then v_lic := null; end if;

      -- on conflict UPDATE, not DO NOTHING: re-running has to be able to
      -- refresh a portrait whose URL moved, which DO NOTHING would silently
      -- skip for every name that already existed
      insert into public.category_library_items (library_id, name, image_url, image_license)
      values (v_id, v_clean, v_img, v_lic)
      on conflict (library_id, name)
        do update set image_url = excluded.image_url,
                      image_license = excluded.image_license;
    end if;
  end loop;

  select count(*) into v_n from public.category_library_items where library_id = v_id;
  return v_n;
end $fn$;
revoke all on function public.df20_seed_category(text, text[], text[], text[]) from anon, authenticated;

-- ── One Piece Characters · 80 items ────────────────────────────────
select public.df20_seed_category(
  'One Piece Characters',
  string_to_array($it$Monkey D. Luffy
Roronoa Zoro
Sanji
Nico Robin
Trafalgar Law
Tony Tony Chopper
Nami
Usopp
Portgas D. Ace
Brook
Franky
Charlotte Katakuri
Shanks
Whitebeard
Donquixote Doflamingo
Jinbe
Boa Hancock
Donquixote Rosinante
Yamato
Bon Clay
Dracule Mihawk
Sabo
Carrot
Perona
Buggy
Crocodile
Bartholomew Kuma
Kozuki Oden
Monkey D. Garp
Blackbeard
Silvers Rayleigh
Marco
Aokiji
Bartolomeo
Kizaru
Gol D. Roger
Eustass Kid
Uta
Smoker
Nefertari Vivi
Enel
Fujitora
Akainu
Monkey D. Dragon
Kaido
Rocks D. Xebec
Jewelry Bonney
Senor Pink
Rob Lucci
Vinsmoke Reiju
Koby
Bepo
Hiluluk
Karoo
Emporio Ivankov
Caesar Clown
Big Mom
Loki
Tashigi
Ulti
Monet
Shirahoshi
Chouchou
Laboon
Okiku
Kaku
Koala
Charlotte Pudding
Gaimon
Pandaman
Benn Beckman
Tama
Cavendish
Killer
Gecko Moria
Kung Fu Dugong
Bellemere
Kyros
Ryuma
Fisher Tiger$it$, E'\n'),
  string_to_array($im$https://cdn.myanimelist.net/images/characters/9/310307.jpg
https://cdn.myanimelist.net/images/characters/3/100534.jpg
https://cdn.myanimelist.net/images/characters/5/136769.jpg
https://cdn.myanimelist.net/images/characters/16/363700.jpg
https://cdn.myanimelist.net/images/characters/10/258757.jpg
https://cdn.myanimelist.net/images/characters/3/100536.jpg
https://cdn.myanimelist.net/images/characters/6/59914.jpg
https://cdn.myanimelist.net/images/characters/16/188076.jpg
https://cdn.myanimelist.net/images/characters/2/72220.jpg
https://cdn.myanimelist.net/images/characters/10/161005.jpg
https://cdn.myanimelist.net/images/characters/13/210053.jpg
https://cdn.myanimelist.net/images/characters/8/342776.jpg
https://cdn.myanimelist.net/images/characters/9/307639.jpg
https://cdn.myanimelist.net/images/characters/3/100236.jpg
https://cdn.myanimelist.net/images/characters/5/349513.jpg
https://cdn.myanimelist.net/images/characters/15/307148.jpg
https://cdn.myanimelist.net/images/characters/14/146013.jpg
https://cdn.myanimelist.net/images/characters/13/288038.jpg
https://cdn.myanimelist.net/images/characters/14/490104.jpg
https://cdn.myanimelist.net/images/characters/6/146037.jpg
https://cdn.myanimelist.net/images/characters/7/69747.jpg
https://cdn.myanimelist.net/images/characters/15/131855.jpg
https://cdn.myanimelist.net/images/characters/8/323766.jpg
https://cdn.myanimelist.net/images/characters/15/136777.jpg
https://cdn.myanimelist.net/images/characters/6/69112.jpg
https://cdn.myanimelist.net/images/characters/6/100535.jpg
https://cdn.myanimelist.net/images/characters/2/54820.jpg
https://cdn.myanimelist.net/images/characters/4/433930.jpg
https://cdn.myanimelist.net/images/characters/5/509073.jpg
https://cdn.myanimelist.net/images/characters/2/109536.jpg
https://cdn.myanimelist.net/images/characters/16/141861.jpg
https://cdn.myanimelist.net/images/characters/4/100226.jpg
https://cdn.myanimelist.net/images/characters/9/96167.jpg
https://cdn.myanimelist.net/images/characters/13/249217.jpg
https://cdn.myanimelist.net/images/characters/12/96168.jpg
https://cdn.myanimelist.net/images/characters/3/51747.jpg
https://cdn.myanimelist.net/images/characters/12/146187.jpg
https://cdn.myanimelist.net/images/characters/11/506689.jpg
https://cdn.myanimelist.net/images/characters/5/235841.jpg
https://cdn.myanimelist.net/images/characters/9/298188.jpg
https://cdn.myanimelist.net/images/characters/16/55111.jpg
https://cdn.myanimelist.net/images/characters/14/235827.jpg
https://cdn.myanimelist.net/images/characters/16/306908.jpg
https://cdn.myanimelist.net/images/characters/6/193567.jpg
https://cdn.myanimelist.net/images/characters/4/492819.jpg
https://cdn.myanimelist.net/images/characters/6/619345.jpg
https://cdn.myanimelist.net/images/characters/14/146045.jpg
https://cdn.myanimelist.net/images/characters/16/235809.jpg
https://cdn.myanimelist.net/images/characters/14/71509.jpg
https://cdn.myanimelist.net/images/characters/6/343184.jpg
https://cdn.myanimelist.net/images/characters/11/49289.jpg
https://cdn.myanimelist.net/images/characters/16/51353.jpg
https://cdn.myanimelist.net/images/characters/2/61610.jpg
https://cdn.myanimelist.net/images/characters/3/64158.jpg
https://cdn.myanimelist.net/images/characters/6/81182.jpg
https://cdn.myanimelist.net/images/characters/7/235823.jpg
https://cdn.myanimelist.net/images/characters/14/337166.jpg
https://cdn.myanimelist.net/images/characters/4/593001.jpg
https://cdn.myanimelist.net/images/characters/2/266983.jpg
https://cdn.myanimelist.net/images/characters/8/453421.jpg
https://cdn.myanimelist.net/images/characters/8/235837.jpg
https://cdn.myanimelist.net/images/characters/14/159079.jpg
https://cdn.myanimelist.net/images/characters/2/379992.jpg
https://cdn.myanimelist.net/images/characters/13/235377.jpg
https://cdn.myanimelist.net/images/characters/9/390613.jpg
https://cdn.myanimelist.net/images/characters/12/51463.jpg
https://cdn.myanimelist.net/images/characters/16/391323.jpg
https://cdn.myanimelist.net/images/characters/9/328672.jpg
https://cdn.myanimelist.net/images/characters/11/384783.jpg
https://cdn.myanimelist.net/images/characters/5/190448.jpg
https://cdn.myanimelist.net/images/characters/13/110987.jpg
https://cdn.myanimelist.net/images/characters/2/384729.jpg
https://cdn.myanimelist.net/images/characters/15/280596.jpg
https://cdn.myanimelist.net/images/characters/12/51350.jpg
https://cdn.myanimelist.net/images/characters/2/61709.jpg
https://cdn.myanimelist.net/images/characters/13/155273.jpg
https://cdn.myanimelist.net/images/characters/10/350916.jpg
https://cdn.myanimelist.net/images/characters/2/274449.jpg
https://cdn.myanimelist.net/images/characters/13/530997.jpg
https://cdn.myanimelist.net/images/characters/8/162743.jpg$im$, E'\n'),
  array_fill('nonfree'::text, array[80]));

select public.df20_add_alias('One Piece Characters',
  array['one piece', 'onepiece', 'one piece cast', 'straw hats', 'straw hat pirates']);

-- ── assert the pictures actually landed ───────────────────────────────────
-- A silent zero here would mean every portrait failed df20_clean_image_url
-- and the whole category quietly degraded to generated cards.
do $$
declare v_total int; v_imgs int;
begin
  select count(*), count(image_url) into v_total, v_imgs
    from public.category_library_items i
    join public.category_library l on l.id = i.library_id
   where l.name_norm = public.df20_norm_category('One Piece Characters');

  if v_total < 60 then
    raise exception 'DF20_ONEPIECE_TOO_SMALL: % items, need 60 for a 30-slot roster', v_total;
  end if;
  if v_imgs < v_total then
    raise exception 'DF20_ONEPIECE_MISSING_IMAGES: % of % items have no picture',
      v_total - v_imgs, v_total;
  end if;
  raise notice 'One Piece Characters: % items, all with portraits', v_total;
end $$;

-- ─────────── 0045_dev_library_preview.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0045 · reading a seeded category back, for the dev browser
--
-- /dev/cards previews the RUNTIME image cascade: it parses a Wikipedia list
-- and resolves pictures live. That is the right preview for a category nobody
-- curated, and the wrong one for a category somebody did — typing "one piece"
-- there parses "List of One Piece characters" and shows different names with
-- the group-photo images that 0044 deliberately rejected. A preview that
-- disagrees with what a room will actually deal is worse than no preview.
--
-- So the dev browser needs to read category_library_items. Those are revoked
-- from anon and authenticated and MUST STAY THAT WAY: a player who can list
-- every candidate in their room's pool can see items that have not been
-- dealt, which is the rule the whole product rests on.
--
-- The established answer in this codebase is a shared secret in df20_config,
-- checked inside a SECURITY DEFINER function — df20_cache_wikipedia and
-- df20_billing_profile both do exactly this. The grant is to anon, so the
-- secret is the whole gate. Leaking it costs a readable premade category
-- list, not the database.
--
-- READ ONLY. Unlike the other two secret-guarded functions this one writes
-- nothing at all, so the worst a leak can do is show someone a list of
-- premade categories they could already see the names of.
--
-- Re-runnable.
-- ═══════════════════════════════════════════════════════════════════════════

-- Generated once, never written down. Read it out when you need it:
--   select value from public.df20_config where key = 'dev_read_secret';
insert into public.df20_config (key, value)
values ('dev_read_secret', encode(gen_random_bytes(24), 'hex'))
on conflict (key) do nothing;

-- ── the whole of a category, names and pictures ───────────────────────────
-- Resolves the query the same way the real app does, via df20_match_category,
-- so an alias that works in production works here: "one piece", "straw hats"
-- and "One Piece Characters" all land on the same 80 rows. Handles a cached
-- Wikipedia parse too, so the dev browser can show anything already stored
-- rather than only the curated shelf.
create or replace function public.df20_library_items(p_secret text, p_query text)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_expected text; v_hit jsonb; v_items jsonb; v_src text; v_ref uuid;
begin
  select value into v_expected from public.df20_config where key = 'dev_read_secret';
  if v_expected is null or p_secret is null or p_secret <> v_expected then
    raise exception 'DF20_NOT_AUTHORISED';
  end if;

  -- p_min_items 1: the dev browser wants to see a short category too, where
  -- the real resolve route would correctly refuse it as unplayable
  v_hit := public.df20_match_category(p_query, 1);
  if v_hit is null then return null; end if;

  v_src := v_hit->>'source';
  v_ref := (v_hit->>'source_id')::uuid;

  if v_src = 'library' then
    select jsonb_agg(jsonb_build_object(
             'name', i.name, 'image_url', i.image_url, 'image_license', i.image_license)
             order by i.name)
      into v_items
      from public.category_library_items i
     where i.library_id = v_ref;
  elsif v_src = 'wikipedia' then
    select jsonb_agg(jsonb_build_object(
             'name', i.name, 'image_url', i.image_url, 'image_license', i.image_license)
             order by i.name)
      into v_items
      from public.wikipedia_cache_items i
     where i.cache_id = v_ref;
  else
    return null;
  end if;

  return jsonb_build_object(
    'source', v_src,
    'name', v_hit->>'name',
    'item_count', v_hit->'item_count',
    'items', coalesce(v_items, '[]'::jsonb));
end $$;

-- anon, because the dev route talks to PostgREST with the publishable key and
-- has no session. The secret is the gate, exactly as it is for the cache
-- writer; without it this raises DF20_NOT_AUTHORISED for every caller.
grant execute on function public.df20_library_items(text, text) to anon, authenticated;

-- ── assert the gate actually closes ───────────────────────────────────────
-- A function that fails open here would publish every premade category's
-- item list to the anon key, which is the leak this exists to avoid.
do $$
declare v_leaked boolean := false;
begin
  begin
    perform public.df20_library_items('definitely-not-the-secret', 'one piece');
    v_leaked := true;
  exception when others then
    if sqlerrm <> 'DF20_NOT_AUTHORISED' then raise; end if;
  end;
  if v_leaked then
    raise exception 'DF20_DEV_READ_UNGATED: df20_library_items answered a bad secret';
  end if;
  raise notice 'ok: df20_library_items refuses a wrong secret';
end $$;

-- ─────────── 0046_anime_categories.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0046 · five more anime casts, with portraits
--
-- GENERATED by scripts/build-anime-seed.mjs. Re-run that rather than editing
-- the lists below; names and URLs are positional, and hand editing one
-- without the other slides every later picture onto the wrong character.
--
-- Same shape and same reasoning as 0044 (One Piece): seeded from MyAnimeList
-- rather than resolved from Wikipedia, because Wikipedia redirects most of a
-- cast to a group article and hands several characters the same photograph.
--
-- Depends on 0044 for df20_seed_category(text,text[],text[],text[]) and for
-- the MyAnimeList host on the image allowlist. df20_clean_image_url is
-- re-declared below anyway so this file is correct applied on its own — the
-- df20_clean_logo_url outage was exactly a caller split from its dependency
-- across two migrations.
--
-- Re-runnable. Every seed upserts by normalised name and refreshes portraits.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.df20_clean_image_url(p_in text)
returns text language plpgsql immutable
set search_path = public, pg_temp as $$
declare v text;
begin
  v := btrim(coalesce(p_in, ''));
  if length(v) = 0 or length(v) > 600 then return null; end if;
  if v !~ '^https://' then return null; end if;
  if v !~* '^https://(upload\.wikimedia\.org|commons\.wikimedia\.org|coverartarchive\.org|covers\.openlibrary\.org|cdn\.myanimelist\.net|media\.kitsu\.app)/' then
    return null;
  end if;
  if v ~ '[[:cntrl:]"''<>]' then return null; end if;
  return v;
end $$;

-- ── Jujutsu Kaisen Characters · 28 items
select public.df20_seed_category(
  'Jujutsu Kaisen Characters',
  string_to_array($it$Satoru Gojo
Yuji Itadori
Megumi Fushiguro
Nobara Kugisaki
Sukuna
Suguru Geto
Yuta Okkotsu
Kento Nanami
Maki Zenin
Toge Inumaki
Panda
Aoi Todo
Toji Fushiguro
Kenjaku
Mahito
Choso
Yuki Tsukumo
Kasumi Miwa
Rika Orimoto
Kinji Hakari
Hajime Kashimo
Hiromi Higuruma
Naoya Zenin
Ryu Ishigori
Takako Uro
Fumihiko Takaba
Ui Ui
Mahoraga$it$, E'\n'),
  string_to_array($im$https://media.kitsu.app/character/105898/image/8a8a441392fe5191c2449460e7338ce6.jpg
https://media.kitsu.app/character/105902/image/7fddba940feccb98fbc613fce4fe2a8e.jpg
https://media.kitsu.app/character/105901/image/762b0293d9cd5de95289ea8a9b072b9e.jpg
https://media.kitsu.app/character/105903/image/293753a40af0f34df05532a4f413724d.jpg
https://media.kitsu.app/character/105906/image/de1a29b96b9a8d7eddb6940249d71cd8.jpg
https://media.kitsu.app/character/105899/image/34c2f1977f3e2e61bf6ad8bda436f1a8.jpg
https://media.kitsu.app/character/105900/image/c18c5241b9bc03f730db4f8eee567edb.jpg
https://media.kitsu.app/character/105910/image/f41a11d9bd5ec962b1db4ae8927f38db.jpg
https://media.kitsu.app/character/105909/image/978c0b75541db15e14d9c7f12ae2b681.jpg
https://media.kitsu.app/character/105920/image/20916dd564c1081a4c5e492e9f342776.jpg
https://media.kitsu.app/character/105911/image/8f3df4c97e949d39277a12fd421164b6.jpg
https://media.kitsu.app/character/105929/image/87de341454cec9433a980298b2fb97f2.jpg
https://media.kitsu.app/character/105905/image/d2a5b01f4b2b1a545c9d39f61381b887.jpg
https://media.kitsu.app/character/105904/image/c63ccde661eaad1a7bace91a91f4e97e.jpg
https://media.kitsu.app/character/105912/image/f93eadaeb425d08c3d32622349eaa6ff.jpg
https://media.kitsu.app/character/105908/image/163db31de25c58d1bfeaeb06a3008808.jpg
https://media.kitsu.app/character/105907/image/550ebc7b5ac77a22b0a1eb6f64e7ab2d.jpg
https://media.kitsu.app/character/105930/image/29e1a0120c641b5c6a7acb6e7dac1552.jpg
https://media.kitsu.app/character/105919/image/229e4c5d6069e29b845cab425be838a2.jpg
https://media.kitsu.app/character/105921/image/f420358849a09282be9c19ef0dde4ab1.jpg
https://media.kitsu.app/character/105922/image/2a241b9efbb1dac2a7e48b7884440d88.jpg
https://media.kitsu.app/character/105923/image/add52c63e9c63252f2f90f31140b193a.jpg
https://media.kitsu.app/character/105924/image/a543689770fb4b87a534808ac76f1f29.jpg
https://media.kitsu.app/character/105925/image/55c8ac4ab716915227163ada3417ee20.jpg
https://media.kitsu.app/character/105926/image/f4bae31c0f91191bb50af952874d5f97.jpg
https://media.kitsu.app/character/105994/image/7b4c4dbe02d0bb23de5db2def2bbc347.jpg
https://media.kitsu.app/character/105995/image/1405064d9647328bc3407c0ca93bbfc0.png
https://media.kitsu.app/character/105993/image/b6122dbc829add43c4ecef04e89bdcc7.jpg$im$, E'\n'),
  array_fill('nonfree'::text, array[28]));

select public.df20_add_alias('Jujutsu Kaisen Characters',
  array['jujutsu kaisen', 'jjk', 'jujutsu kaisen cast']);

-- ── Dragon Ball Z Characters · 65 items
select public.df20_seed_category(
  'Dragon Ball Z Characters',
  string_to_array($it$Goku
Vegeta
Gohan
Piccolo
Krillin
Frieza
Cell
Majin Buu
Trunks
Future Trunks
Goten
Bulma
Chi-Chi
Master Roshi
Yamcha
Tien
Chiaotzu
Android 16
Android 17
Android 18
Android 19
Dr. Gero
Nappa
Raditz
Bardock
King Vegeta
Zarbon
Dodoria
Captain Ginyu
Recoome
Burter
Jeice
Guldo
King Cold
Babidi
Dabura
Spopovich
Videl
Mr. Satan
Supreme Kai
Kibito
Dende
Nail
Kami
Mr. Popo
King Kai
Korin
Yajirobe
Oolong
Puar
Uub
Pan
Shenron
Porunga
Mercenary Tao
King Piccolo
Garlic Jr.
Ox-King
Fortuneteller Baba
Launch
Marron
Paikuhan
Yakon
Pui Pui
Gine$it$, E'\n'),
  string_to_array($im$https://media.kitsu.app/characters/images/4119/original.jpg
https://media.kitsu.app/characters/images/4196/original.jpg
https://media.kitsu.app/characters/images/4231/original.jpg
https://media.kitsu.app/characters/images/4121/original.jpg
https://media.kitsu.app/characters/images/4115/original.jpg
https://media.kitsu.app/characters/images/4209/original.jpg
https://media.kitsu.app/characters/images/4210/original.jpg
https://media.kitsu.app/characters/images/4200/original.jpg
https://media.kitsu.app/characters/images/4199/original.jpg
https://media.kitsu.app/characters/images/86951/original.jpg
https://media.kitsu.app/characters/images/4233/original.jpg
https://media.kitsu.app/characters/images/4117/original.jpg
https://media.kitsu.app/characters/images/4128/original.jpg
https://media.kitsu.app/characters/images/4118/original.jpg
https://media.kitsu.app/characters/images/4116/original.jpg
https://media.kitsu.app/characters/images/4157/original.jpg
https://media.kitsu.app/characters/images/4156/original.jpg
https://media.kitsu.app/characters/images/10340/original.jpg
https://media.kitsu.app/characters/images/4206/original.jpg
https://media.kitsu.app/characters/images/4211/original.jpg
https://media.kitsu.app/characters/images/4214/original.jpg
https://media.kitsu.app/characters/images/4205/original.jpg
https://media.kitsu.app/characters/images/4213/original.jpg
https://media.kitsu.app/characters/images/10358/original.jpg
https://media.kitsu.app/characters/images/10349/original.jpg
https://media.kitsu.app/characters/images/4221/original.jpg
https://media.kitsu.app/characters/images/10347/original.jpg
https://media.kitsu.app/characters/images/10360/original.jpg
https://media.kitsu.app/characters/images/10353/original.jpg
https://media.kitsu.app/characters/images/10357/original.jpg
https://media.kitsu.app/characters/images/10354/original.jpg
https://media.kitsu.app/characters/images/10356/original.jpg
https://media.kitsu.app/characters/images/10355/original.jpg
https://media.kitsu.app/characters/images/10372/original.jpg
https://media.kitsu.app/characters/images/10350/original.jpg
https://media.kitsu.app/characters/images/10351/original.jpg
https://media.kitsu.app/characters/images/10345/original.jpg
https://media.kitsu.app/characters/images/4203/original.jpg
https://media.kitsu.app/characters/images/4219/original.jpg
https://media.kitsu.app/characters/images/10352/original.jpg
https://media.kitsu.app/characters/images/10366/original.jpg
https://media.kitsu.app/characters/images/4215/original.jpg
https://media.kitsu.app/characters/images/10359/original.jpg
https://media.kitsu.app/characters/images/4159/original.jpg
https://media.kitsu.app/characters/images/4158/original.jpg
https://media.kitsu.app/characters/images/4212/original.jpg
https://media.kitsu.app/characters/images/4161/original.jpg
https://media.kitsu.app/characters/images/4125/original.jpg
https://media.kitsu.app/characters/images/4130/original.jpg
https://media.kitsu.app/characters/images/4120/original.jpg
https://media.kitsu.app/characters/images/4220/original.jpg
https://media.kitsu.app/characters/images/4197/original.jpg
https://media.kitsu.app/characters/images/4160/original.jpg
https://media.kitsu.app/characters/images/10363/original.jpg
https://media.kitsu.app/characters/images/4145/original.jpg
https://media.kitsu.app/characters/images/4165/original.jpg
https://media.kitsu.app/characters/images/10348/original.jpg
https://media.kitsu.app/characters/images/4122/original.jpg
https://media.kitsu.app/characters/images/4194/original.jpg
https://media.kitsu.app/characters/images/4129/original.jpg
https://media.kitsu.app/characters/images/4202/original.jpg
https://media.kitsu.app/characters/images/10364/original.jpg
https://media.kitsu.app/characters/images/10374/original.jpg
https://media.kitsu.app/characters/images/10362/original.jpg
https://media.kitsu.app/characters/images/41540/original.jpg$im$, E'\n'),
  array_fill('nonfree'::text, array[65]));

select public.df20_add_alias('Dragon Ball Z Characters',
  array['dragon ball z', 'dragonball z', 'dbz', 'dragon ball']);

-- ── My Hero Academia Characters · 66 items
select public.df20_seed_category(
  'My Hero Academia Characters',
  string_to_array($it$Izuku Midoriya
Katsuki Bakugo
Shoto Todoroki
Ochaco Uraraka
Tenya Iida
All Might
Shota Aizawa
Tsuyu Asui
Eijiro Kirishima
Denki Kaminari
Momo Yaoyorozu
Kyoka Jiro
Fumikage Tokoyami
Mina Ashido
Hanta Sero
Mezo Shoji
Rikido Sato
Koji Koda
Toru Hagakure
Yuga Aoyama
Mashirao Ojiro
Minoru Mineta
All For One
Tomura Shigaraki
Dabi
Himiko Toga
Kurogiri
Stain
Overhaul
Twice
Muscular
Mr. Compress
Spinner
Magne
Endeavor
Hawks
Best Jeanist
Mirko
Edgeshot
Kamui Woods
Mt. Lady
Present Mic
Midnight
Recovery Girl
Principal Nezu
Sir Nighteye
Gran Torino
Mirio Togata
Nejire Hado
Tamaki Amajiki
Eri
Mei Hatsume
Itsuka Kendo
Neito Monoma
Tetsutetsu Tetsutetsu
Hitoshi Shinso
Fuyumi Todoroki
Nana Shimura
Inko Midoriya
Mitsuki Bakugo
Ibara Shiozaki
Setsuna Tokage
Pony Tsunotori
Inasa Yoarashi
Camie Utsushimi
Nomu$it$, E'\n'),
  string_to_array($im$https://media.kitsu.app/characters/images/61663/original.jpg
https://media.kitsu.app/characters/images/61661/original.jpg
https://media.kitsu.app/characters/images/61664/original.jpg
https://media.kitsu.app/characters/images/61665/original.jpg
https://media.kitsu.app/characters/images/61662/original.jpg
https://media.kitsu.app/characters/images/61660/original.jpg
https://media.kitsu.app/characters/images/61666/original.jpg
https://media.kitsu.app/characters/images/61669/original.jpg
https://media.kitsu.app/characters/images/61676/original.jpg
https://media.kitsu.app/characters/images/61674/original.jpg
https://media.kitsu.app/characters/images/61688/original.jpg
https://media.kitsu.app/characters/images/61673/original.jpg
https://media.kitsu.app/characters/images/61687/original.jpg
https://media.kitsu.app/characters/images/61668/original.jpg
https://media.kitsu.app/characters/images/61685/original.jpg
https://media.kitsu.app/characters/images/61686/original.jpg
https://media.kitsu.app/characters/images/61684/original.jpg
https://media.kitsu.app/characters/images/61677/original.jpg
https://media.kitsu.app/characters/images/61672/original.jpg
https://media.kitsu.app/characters/images/61667/original.jpg
https://media.kitsu.app/characters/images/61681/original.jpg
https://media.kitsu.app/characters/images/61679/original.jpg
https://media.kitsu.app/characters/images/82393/original.jpg
https://media.kitsu.app/characters/images/87109/original.jpg
https://media.kitsu.app/characters/images/89171/original.jpg
https://media.kitsu.app/characters/images/78153/original.jpg
https://media.kitsu.app/characters/images/85839/original.jpg
https://media.kitsu.app/characters/images/90839/original.jpg
https://media.kitsu.app/characters/images/103007/original.jpg
https://media.kitsu.app/characters/images/95686/original.jpg
https://media.kitsu.app/characters/images/98279/original.jpg
https://media.kitsu.app/characters/images/98283/original.jpg
https://media.kitsu.app/characters/images/98079/original.jpg
https://media.kitsu.app/characters/images/98282/original.jpg
https://media.kitsu.app/characters/images/94227/original.jpg
https://media.kitsu.app/characters/images/105807/original.jpg
https://media.kitsu.app/characters/images/104274/original.jpg
https://media.kitsu.app/character/105805/image/7ba1fa0db802478d1ae57bda3d85ffc3.jpg
https://media.kitsu.app/characters/images/104271/original.jpg
https://media.kitsu.app/characters/images/61675/original.jpg
https://media.kitsu.app/characters/images/61680/original.jpg
https://media.kitsu.app/characters/images/61682/original.jpg
https://media.kitsu.app/characters/images/70008/original.jpg
https://media.kitsu.app/characters/images/61683/original.jpg
https://media.kitsu.app/characters/images/80402/original.jpg
https://media.kitsu.app/characters/images/98275/original.jpg
https://media.kitsu.app/characters/images/70274/original.jpg
https://media.kitsu.app/characters/images/103817/original.jpg
https://media.kitsu.app/characters/images/104284/original.jpg
https://media.kitsu.app/characters/images/104285/original.jpg
https://media.kitsu.app/characters/images/102018/original.jpg
https://media.kitsu.app/characters/images/81809/original.png
https://media.kitsu.app/characters/images/76532/original.jpg
https://media.kitsu.app/characters/images/63613/original.jpg
https://media.kitsu.app/characters/images/95066/original.jpg
https://media.kitsu.app/characters/images/85271/original.jpg
https://media.kitsu.app/characters/images/90502/original.jpg
https://media.kitsu.app/characters/images/76471/original.jpg
https://media.kitsu.app/characters/images/61678/original.jpg
https://media.kitsu.app/characters/images/96320/original.jpg
https://media.kitsu.app/characters/images/76346/original.jpg
https://media.kitsu.app/characters/images/84566/original.jpg
https://media.kitsu.app/characters/images/86276/original.jpg
https://media.kitsu.app/characters/images/87462/original.jpg
https://media.kitsu.app/characters/images/104290/original.jpg
https://media.kitsu.app/characters/images/84043/original.jpg$im$, E'\n'),
  array_fill('nonfree'::text, array[66]));

select public.df20_add_alias('My Hero Academia Characters',
  array['my hero academia', 'mha', 'boku no hero academia', 'bnha']);

-- ── Naruto Characters · 60 items
select public.df20_seed_category(
  'Naruto Characters',
  string_to_array($it$Naruto Uzumaki
Itachi Uchiha
Kakashi Hatake
Sasuke Uchiha
Shikamaru Nara
Jiraiya
Gaara
Hinata Hyuga
Minato Namikaze
Pain
Rock Lee
Sakura Haruno
Neji Hyuga
Deidara
Orochimaru
Might Guy
Tsunade
Hidan
Temari
Konan
Zabuza Momochi
Kiba Inuzuka
Kurama
Tobirama Senju
Hashirama Senju
Haku
Kisame Hoshigaki
Tenten
Ino Yamanaka
Shino Aburame
Kimimaro
Kabuto Yakushi
Kakuzu
Iruka Umino
Asuma Sarutobi
Konohamaru Sarutobi
Akamaru
Kankuro
Teuchi
Anko Mitarashi
Choji Akimichi
Hanabi Hyuga
Tayuya
Kurenai Yuhi
Zetsu
Hiruzen Sarutobi
Pakkun
Gamatatsu
Gamabunta
Genma Shiranui
Hayate Gekko
Mikoto Uchiha
Shikaku Nara
Gamakichi
Shizune
Tonton
Menma
Dosu Kinuta
Genzo
Kotetsu Hagane$it$, E'\n'),
  string_to_array($im$https://cdn.myanimelist.net/images/characters/2/284121.jpg
https://cdn.myanimelist.net/images/characters/9/284122.jpg
https://cdn.myanimelist.net/images/characters/7/284129.jpg
https://cdn.myanimelist.net/images/characters/9/131317.jpg
https://cdn.myanimelist.net/images/characters/3/131315.jpg
https://cdn.myanimelist.net/images/characters/15/68618.jpg
https://cdn.myanimelist.net/images/characters/10/293375.jpg
https://cdn.myanimelist.net/images/characters/6/278736.jpg
https://cdn.myanimelist.net/images/characters/14/128074.jpg
https://cdn.myanimelist.net/images/characters/8/73473.jpg
https://cdn.myanimelist.net/images/characters/13/433353.jpg
https://cdn.myanimelist.net/images/characters/9/69275.jpg
https://cdn.myanimelist.net/images/characters/2/105538.jpg
https://cdn.myanimelist.net/images/characters/9/131319.jpg
https://cdn.myanimelist.net/images/characters/3/162089.jpg
https://cdn.myanimelist.net/images/characters/16/103576.jpg
https://cdn.myanimelist.net/images/characters/12/523646.jpg
https://cdn.myanimelist.net/images/characters/8/103578.jpg
https://cdn.myanimelist.net/images/characters/13/292452.jpg
https://cdn.myanimelist.net/images/characters/13/158755.jpg
https://cdn.myanimelist.net/images/characters/14/103706.jpg
https://cdn.myanimelist.net/images/characters/11/131217.jpg
https://cdn.myanimelist.net/images/characters/5/232183.jpg
https://cdn.myanimelist.net/images/characters/2/293367.jpg
https://cdn.myanimelist.net/images/characters/10/34809.jpg
https://cdn.myanimelist.net/images/characters/10/103707.jpg
https://cdn.myanimelist.net/images/characters/11/433351.jpg
https://cdn.myanimelist.net/images/characters/16/110946.jpg
https://cdn.myanimelist.net/images/characters/9/60062.jpg
https://cdn.myanimelist.net/images/characters/16/292449.jpg
https://cdn.myanimelist.net/images/characters/13/103598.jpg
https://cdn.myanimelist.net/images/characters/14/82459.jpg
https://cdn.myanimelist.net/images/characters/11/255727.jpg
https://cdn.myanimelist.net/images/characters/10/100216.jpg
https://cdn.myanimelist.net/images/characters/13/82538.jpg
https://cdn.myanimelist.net/images/characters/7/109419.jpg
https://cdn.myanimelist.net/images/characters/6/58197.jpg
https://cdn.myanimelist.net/images/characters/7/68615.jpg
https://cdn.myanimelist.net/images/characters/14/62801.jpg
https://cdn.myanimelist.net/images/characters/8/66177.jpg
https://cdn.myanimelist.net/images/characters/9/105421.jpg
https://cdn.myanimelist.net/images/characters/16/292518.jpg
https://cdn.myanimelist.net/images/characters/10/295205.jpg
https://cdn.myanimelist.net/images/characters/8/103797.jpg
https://cdn.myanimelist.net/images/characters/11/76260.jpg
https://cdn.myanimelist.net/images/characters/2/68520.jpg
https://cdn.myanimelist.net/images/characters/13/54922.jpg
https://cdn.myanimelist.net/images/characters/13/62776.jpg
https://cdn.myanimelist.net/images/characters/6/70846.jpg
https://cdn.myanimelist.net/images/characters/3/104664.jpg
https://cdn.myanimelist.net/images/characters/10/104665.jpg
https://cdn.myanimelist.net/images/characters/6/103949.jpg
https://cdn.myanimelist.net/images/characters/2/100214.jpg
https://cdn.myanimelist.net/images/characters/13/54034.jpg
https://cdn.myanimelist.net/images/characters/3/103794.jpg
https://cdn.myanimelist.net/images/characters/4/218401.jpg
https://cdn.myanimelist.net/images/characters/5/57869.jpg
https://cdn.myanimelist.net/images/characters/14/36354.jpg
https://cdn.myanimelist.net/images/characters/4/66172.jpg
https://cdn.myanimelist.net/images/characters/4/104662.jpg$im$, E'\n'),
  array_fill('nonfree'::text, array[60]));

select public.df20_add_alias('Naruto Characters',
  array['naruto', 'naruto characters', 'naruto shippuden', 'hidden leaf']);

-- ── Demon Slayer Characters · 45 items
select public.df20_seed_category(
  'Demon Slayer Characters',
  string_to_array($it$Tanjiro Kamado
Zenitsu Agatsuma
Inosuke Hashibira
Kyojuro Rengoku
Nezuko Kamado
Shinobu Kocho
Giyu Tomioka
Tengen Uzui
Mitsuri Kanroji
Muichiro Tokito
Kanao Tsuyuri
Sanemi Shinazugawa
Obanai Iguro
Yoriichi Tsugikuni
Genya Shinazugawa
Muzan Kibutsuji
Sabito
Gyomei Himejima
Rui
Enmu
Hotaru Haganezuka
Tamayo
Kanae Kocho
Sakonji Urokodaki
Yushiro
Mother Spider Demon
Kagaya Ubuyashiki
Makomo
Ukogi
Susamaru
Aoi Kanzaki
Tanjuro Kamado
Kaigaku
Goto
Kie Kamado
Murata
Hanako Kamado
Kyogai
Nakime
Older Sister Spider Demon
Kiriya Ubuyashiki
Matsuemon Tennoji
Jigoro Kuwajima
Toyo
Hand Demon$it$, E'\n'),
  string_to_array($im$https://cdn.myanimelist.net/images/characters/6/386735.jpg
https://cdn.myanimelist.net/images/characters/10/459689.jpg
https://cdn.myanimelist.net/images/characters/3/329560.jpg
https://cdn.myanimelist.net/images/characters/10/423443.jpg
https://cdn.myanimelist.net/images/characters/2/378254.jpg
https://cdn.myanimelist.net/images/characters/3/386591.jpg
https://cdn.myanimelist.net/images/characters/3/423445.jpg
https://cdn.myanimelist.net/images/characters/16/387706.jpg
https://cdn.myanimelist.net/images/characters/11/514229.jpg
https://cdn.myanimelist.net/images/characters/5/464903.jpg
https://cdn.myanimelist.net/images/characters/2/384712.jpg
https://cdn.myanimelist.net/images/characters/11/556642.jpg
https://cdn.myanimelist.net/images/characters/15/466014.jpg
https://cdn.myanimelist.net/images/characters/12/394870.jpg
https://cdn.myanimelist.net/images/characters/5/390152.jpg
https://cdn.myanimelist.net/images/characters/4/384669.jpg
https://cdn.myanimelist.net/images/characters/8/599194.jpg
https://cdn.myanimelist.net/images/characters/10/550017.jpg
https://cdn.myanimelist.net/images/characters/4/385228.jpg
https://cdn.myanimelist.net/images/characters/16/440983.jpg
https://cdn.myanimelist.net/images/characters/13/379207.jpg
https://cdn.myanimelist.net/images/characters/14/384692.jpg
https://cdn.myanimelist.net/images/characters/16/389355.jpg
https://cdn.myanimelist.net/images/characters/11/382214.jpg
https://cdn.myanimelist.net/images/characters/5/384720.jpg
https://cdn.myanimelist.net/images/characters/4/385242.jpg
https://cdn.myanimelist.net/images/characters/2/387497.jpg
https://cdn.myanimelist.net/images/characters/7/382213.jpg
https://cdn.myanimelist.net/images/characters/11/470329.jpg
https://cdn.myanimelist.net/images/characters/3/379196.jpg
https://cdn.myanimelist.net/images/characters/5/388816.jpg
https://cdn.myanimelist.net/images/characters/9/385444.jpg
https://cdn.myanimelist.net/images/characters/7/508549.jpg
https://cdn.myanimelist.net/images/characters/10/388820.jpg
https://cdn.myanimelist.net/images/characters/3/382215.jpg
https://cdn.myanimelist.net/images/characters/6/388807.jpg
https://cdn.myanimelist.net/images/characters/9/382218.jpg
https://cdn.myanimelist.net/images/characters/6/385328.jpg
https://cdn.myanimelist.net/images/characters/2/551259.jpg
https://cdn.myanimelist.net/images/characters/11/385245.jpg
https://cdn.myanimelist.net/images/characters/6/385248.jpg
https://cdn.myanimelist.net/images/characters/4/494313.jpg
https://cdn.myanimelist.net/images/characters/7/385246.jpg
https://cdn.myanimelist.net/images/characters/13/388819.jpg
https://cdn.myanimelist.net/images/characters/7/385331.jpg$im$, E'\n'),
  array_fill('nonfree'::text, array[45]));

select public.df20_add_alias('Demon Slayer Characters',
  array['demon slayer', 'kimetsu no yaiba', 'demon slayer characters']);

-- ── assert every one of them landed with distinct pictures ────────────────
-- Distinct, not merely non-null: the Wikipedia failure mode this whole
-- approach exists to avoid is several characters sharing one group photo,
-- and a count of non-null images would not notice that at all.
do $$
declare c text; v_total int; v_imgs int; v_distinct int;
  v_cats text[] := array['Jujutsu Kaisen Characters', 'Dragon Ball Z Characters', 'My Hero Academia Characters', 'Naruto Characters', 'Demon Slayer Characters'];
begin
  foreach c in array v_cats loop
    select count(*), count(i.image_url), count(distinct i.image_url)
      into v_total, v_imgs, v_distinct
      from public.category_library_items i
      join public.category_library l on l.id = i.library_id
     where l.name_norm = public.df20_norm_category(c);

    if v_total < 30 then
      raise exception 'DF20_ANIME_TOO_SMALL: % has only % items', c, v_total;
    end if;
    if v_imgs < v_total then
      raise exception 'DF20_ANIME_MISSING_IMAGES: % of % items in % have no picture',
        v_total - v_imgs, v_total, c;
    end if;
    if v_distinct < v_total then
      raise exception 'DF20_ANIME_DUPLICATE_IMAGES: % shares % pictures across % items',
        c, v_total - v_distinct, v_total;
    end if;
    raise notice '%: % items, % distinct portraits', c, v_total, v_distinct;
  end loop;
end $$;

-- ─────────── 0047_library_genres.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0046 · genres for the shelf
--
-- The library is 23 categories and growing, rendered as one flat wall of
-- chips in /new. Past about a dozen that stops being a menu and becomes a
-- search problem, so each category gets a genre and the picker can filter.
--
-- NOT CONSTRAINED to a fixed list, deliberately. A check constraint here
-- would mean every future category has to be added in lockstep with this
-- file, and the failure mode is a seed that errors out. The default of
-- 'other' is the safety net instead: an unclassified category is mis-filed,
-- never invisible. The UI builds its filter chips from whatever genres
-- actually exist, so a new one appears without a UI change.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.category_library
  add column if not exists genre text not null default 'other';

create index if not exists category_library_genre_idx on public.category_library(genre);

-- ── classify what is on the shelf today ───────────────────────────────────
do $$
declare
  r record;
  v_map jsonb := jsonb_build_object(
    'sports', jsonb_build_array('Football Draft','NFL Teams','NBA Teams','MLB Teams'),
    'movies', jsonb_build_array('Disney Animated Movies','Movie Villains'),
    'tv',     jsonb_build_array('TV Sitcoms'),
    -- 0044 and 0046 each added anime categories; this list has to be extended
    -- alongside them. The 'ungenred' notice below is what catches the miss —
    -- it is how Naruto and Demon Slayer were spotted sitting in 'other'.
    'anime',  jsonb_build_array('One Piece Characters','Naruto Characters',
                                'Demon Slayer Characters','Dragon Ball Z Characters',
                                'My Hero Academia Characters','Jujutsu Kaisen Characters'),
    'music',  jsonb_build_array('90s Songs','2000s Songs'),
    'games',  jsonb_build_array('Board Games','Video Game Franchises'),
    'comics', jsonb_build_array('Superheroes'),
    'food',   jsonb_build_array('Breakfast Cereals','Candy and Sweets','Chip Flavors',
                                'Fast Food Chains','Halloween Candy','Ice Cream Flavors',
                                'Pizza Toppings','Soft Drinks')
  );
  v_genre text;
  v_name  text;
begin
  for v_genre in select jsonb_object_keys(v_map) loop
    for v_name in select jsonb_array_elements_text(v_map -> v_genre) loop
      update public.category_library
         set genre = v_genre
       where name_norm = public.df20_norm_category(v_name);
    end loop;
  end loop;

  -- report anything still sitting in the default, so a new category that
  -- nobody classified is visible here rather than discovered in the UI
  for r in select name from public.category_library where genre = 'other' order by name loop
    raise notice 'ungenred (filed under other): %', r.name;
  end loop;
end $$;

-- ── the shelf, now with a genre on every row ──────────────────────────────
-- Same signature, so df20_selfcheck()'s assertion of
-- `public.list_free_categories()` still holds.
create or replace function public.list_free_categories()
returns jsonb language sql stable security definer
set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'id', l.id,
               'name', l.name,
               'genre', coalesce(l.genre, 'other'),
               'item_count', (select count(*) from public.category_library_items i
                               where i.library_id = l.id)) as x
        from public.category_library l
    ) s
   where (x->>'item_count')::int >= 20;
$$;
grant execute on function public.list_free_categories() to anon, authenticated;

-- ── assert the shelf is actually usable as a filtered menu ────────────────
create or replace function public.df20_selfcheck_genres()
returns text language plpgsql
set search_path = public, pg_temp as $$
declare v_total int; v_other int; v_genres int;
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='category_library'
                    and column_name='genre') then
    raise exception 'DF20_SELFCHECK_GENRES_FAILED: category_library.genre missing';
  end if;

  select count(*) into v_total  from public.category_library;
  select count(*) into v_other  from public.category_library where genre = 'other';
  select count(distinct genre) into v_genres from public.category_library;

  -- every row still carries the key the UI groups on
  if exists (select 1 from public.category_library where genre is null or btrim(genre) = '') then
    raise exception 'DF20_SELFCHECK_GENRES_FAILED: a category has no genre';
  end if;

  return format('ok - %s categories across %s genres (%s unclassified)',
                v_total, v_genres, v_other);
end $$;
revoke all on function public.df20_selfcheck_genres() from anon, authenticated;

select public.df20_selfcheck_genres();

-- ─────────── 0048_revoke_public_execute.sql ───────────

-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0048 · every `revoke ... from anon, authenticated` in this
--                     repo has been a no-op, and here is why
--
-- Postgres grants EXECUTE on a new function to PUBLIC by default. anon and
-- authenticated are members of PUBLIC, so
--
--     revoke all on function public.df20_reveal_next(uuid) from anon, authenticated;
--
-- removes a grant those roles never had and leaves the PUBLIC one untouched.
-- Every internal function this codebase believed it had sealed since 0004 has
-- in fact been callable by anyone holding the publishable key. Verified, not
-- theorised:
--
--     curl -X POST "$URL/rest/v1/rpc/df20_gen_code" \
--          -H "apikey: $ANON_KEY" -d '{}'
--     "FKMWDK"
--
-- 100 of 103 app functions were reachable. The exposed set includes the two
-- rules the product rests on:
--
--   df20_reveal_next(uuid)     deals the next card — a caller could turn over
--                              the deck of a room they are merely watching
--   df20_add_to_roster(...)    writes a roster entry with no money check at
--                              all, which is the whole auction bypassed
--   df20_fill_pool(...)        replaces a live room's item pool
--   df20_resolve_lot/_gift     ends a lot in a chosen direction
--   df20_purge_old_rooms()     deletes rooms
--   df20_seed_category(...)    writes to the shared public library
--
-- THE FIX IS TO REVOKE FROM PUBLIC, NOT FROM THE ROLES. The 69 functions that
-- are genuinely the client API were each given an explicit
-- `grant execute ... to anon, authenticated`, and an explicit grant survives a
-- revoke from PUBLIC — so the client API is unaffected and only the functions
-- that were riding the default grant lose access.
--
-- Extension functions (pg_trgm) are deliberately excluded: they are not ours
-- to re-permission, and trigram matching runs inside SECURITY DEFINER
-- functions that would keep working regardless.
--
-- Re-runnable.
-- ═══════════════════════════════════════════════════════════════════════════

do $$
declare r record; v_n int := 0;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      left join pg_depend d on d.objid = p.oid and d.deptype = 'e'   -- extension-owned
     where n.nspname = 'public'
       and d.objid is null
  loop
    execute format('revoke all on function %s from public', r.sig);
    v_n := v_n + 1;
  end loop;
  raise notice 'revoked PUBLIC execute on % app functions', v_n;
end $$;

-- ── and assert the hole is actually closed ────────────────────────────────
-- Two directions, because either failure is silent: an internal function that
-- is still reachable, or a client RPC that lost its grant and will now 404
-- the moment somebody tries to create a room.
do $$
declare
  v_exposed text[] := '{}';
  v_broken  text[] := '{}';
  r record;
  -- the client API. If any of these stops being executable the app is down,
  -- so they are named rather than inferred.
  v_client text[] := array[
    'public.create_room(text,integer,integer,integer,integer,text,boolean,integer,text,text,text,uuid,text)',
    'public.join_room(text,text)',
    'public.start_draft(text,uuid)',
    'public.place_bid(text,uuid,integer,integer)',
    'public.pass_turn(text,uuid,integer)',
    'public.offer_decide(text,uuid,text)',
    'public.expire_turn(text)',
    'public.get_room_state(text)',
    'public.submit_vote(text,uuid,uuid)',
    'public.list_free_categories()',
    'public.df20_match_category(text,integer)',
    'public.df20_rate_limit(text,text,integer,integer)',
    'public.my_premium()',
    'public.get_audience_state(text,text)',
    'public.cast_audience_vote(text,text,uuid)',
    'public.get_obs_state(uuid)'
  ];
  f text;
begin
  -- 1. nothing internal may remain reachable by anon
  for r in
    select p.oid, p.oid::regprocedure::text as sig, p.proacl
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      left join pg_depend d on d.objid = p.oid and d.deptype = 'e'
     where n.nspname = 'public'
       and d.objid is null
       and not (coalesce(p.proacl::text, '') like '%anon=X%'
             or coalesce(p.proacl::text, '') like '%authenticated=X%')
  loop
    if has_function_privilege('anon', r.oid, 'EXECUTE') then
      v_exposed := v_exposed || r.sig;
    end if;
  end loop;

  -- 2. everything the client actually calls must still work
  foreach f in array v_client loop
    if to_regprocedure(f) is null then
      v_broken := v_broken || (f || ' (missing)');
    elsif not has_function_privilege('anon', to_regprocedure(f)::oid, 'EXECUTE') then
      v_broken := v_broken || (f || ' (anon lost EXECUTE)');
    end if;
  end loop;

  if coalesce(array_length(v_exposed, 1), 0) > 0 then
    raise exception E'DF20_INTERNAL_STILL_EXPOSED\n  %', array_to_string(v_exposed, E'\n  ');
  end if;
  if coalesce(array_length(v_broken, 1), 0) > 0 then
    raise exception E'DF20_CLIENT_API_BROKEN\n  %', array_to_string(v_broken, E'\n  ');
  end if;

  raise notice 'ok: internal functions sealed, % client RPCs still reachable',
    array_length(v_client, 1);
end $$;

do $$
begin
  raise notice '%', public.df20_selfcheck();
  raise notice '%', public.df20_grant_check();
  raise notice 'free shelf: % categories', jsonb_array_length(public.list_free_categories());
end $$;
