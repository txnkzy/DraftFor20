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
