-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · Football Draft, cut down to names people recognise
--
-- THE MEASUREMENT. Football Draft held 268 names. Only 26 of them — 10% —
-- also appear in NFL Players, which is the deck this project builds by
-- ranking Wikipedia pageviews and cutting at 40% of the tenth-ranked player.
-- A five-slot draft deals ten cards, so by the project's OWN recognisability
-- test roughly one card per draft was a name anybody could argue about.
--
-- It was also the only deck on the shelf with no pictures at all: 0 of 268,
-- where NFL Players, NFL All-Time Greats and Candy and Sweets are each at
-- 100%. No visual rescue for a name you do not know.
--
-- WHAT WAS IN IT. A random sample turned up Frank Ragnow, Lane Johnson,
-- Landon Dickerson, Olu Fashanu and JC Latham — offensive linemen — beside
-- Tyler Bass and Cameron Dicker, who are kickers. "Who would you rather
-- have" is not a question two people can argue about for a centre. The
-- category guide states the rule this broke: recognition, not expertise.
--
-- THE FIX. Rebuilt as the union of the two decks this project has already
-- curated and vouches for — NFL Players (37) and NFL All-Time Greats (59),
-- 94 after the two that appear in both. Every name carries the picture it
-- already had. It stops being this season's roster and becomes current
-- players against all-time greats, which is a better argument anyway, and 94
-- is well past the four-times-roster-size depth the guide asks for.
--
-- DELETE FIRST, because df20_seed_category upserts and never deletes: a
-- category that SHRINKS keeps every dropped name otherwise. That is the 0049
-- lesson and this is the same shape of change.
--
-- Rooms already dealt are untouched. room_pool copies name, image and
-- licence by value with no foreign key back here, so every existing and
-- in-flight draft keeps exactly the deck it was dealt.
-- ═══════════════════════════════════════════════════════════════════════════

do $$
declare v_fd uuid; v_before int; v_after int;
begin
  select id into v_fd from public.category_library where name = 'Football Draft';
  if v_fd is null then
    raise notice 'No Football Draft category on this database; nothing to do.';
    return;
  end if;

  select count(*) into v_before from public.category_library_items where library_id = v_fd;

  delete from public.category_library_items where library_id = v_fd;

  insert into public.category_library_items (library_id, name, image_url, image_license)
  select distinct on (i.name) v_fd, i.name, i.image_url, i.image_license
    from public.category_library c
    join public.category_library_items i on i.library_id = c.id
   where c.name in ('NFL Players', 'NFL All-Time Greats')
   order by i.name, (i.image_url is null);   -- prefer the copy that has a picture

  select count(*) into v_after from public.category_library_items where library_id = v_fd;
  raise notice 'Football Draft: % names -> %', v_before, v_after;
end $$;

notify pgrst, 'reload schema';
