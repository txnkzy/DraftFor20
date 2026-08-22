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
