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
