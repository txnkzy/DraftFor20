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
    -- 0049 added four more; same rule as the anime list below, the
    -- 'ungenred' notice at the end is what catches a miss
    'sports', jsonb_build_array('Football Draft','NFL Teams','NBA Teams','MLB Teams',
                                'NFL Players','NBA Players',
                                'NFL All-Time Greats','NBA All-Time Greats'),
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
