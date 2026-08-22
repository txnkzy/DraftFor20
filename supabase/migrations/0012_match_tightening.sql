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
