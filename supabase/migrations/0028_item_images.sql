-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0028 · a picture on the card being auctioned
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
-- search_path is pinned inline: 0027's pinning loop runs BEFORE this file and
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
