-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 v8 · item images
--
-- The leak test is the important one here, exactly as it is for names. An
-- image URL identifies a card as surely as its name does — "…/Iron_Man.png"
-- in a network tab is the same tell as the word "Iron Man" — so an undealt
-- item's picture must not appear in any public projection either.
--
-- Run after APPLY_V7.sql + 0026..0031. Cleans up after itself.
-- ═══════════════════════════════════════════════════════════════════════════

do $test$
declare
  v_h jsonb; v_g jsonb; v_s jsonb; v_code text; v_ht uuid;
  v_rid uuid; v_rooms uuid[] := '{}'; v_lot_img text; v_deck_img text;
  v_n int; v_imgs int; v_distinct int; v_cat text;
begin
  -- ── 1. the URL cleaner refuses everything it should ─────────────────────
  assert public.df20_clean_image_url('https://upload.wikimedia.org/wikipedia/en/a/ab/X.jpg')
         is not null, 'a wikimedia upload is allowed';
  assert public.df20_clean_image_url('https://coverartarchive.org/release-group/abc/front-500')
         is not null, 'cover art archive is allowed';
  assert public.df20_clean_image_url('http://upload.wikimedia.org/x.jpg') is null,
         'plain http is refused';
  assert public.df20_clean_image_url('https://evil.example.com/x.jpg') is null,
         'an unknown host is refused';
  assert public.df20_clean_image_url('javascript:alert(1)') is null,
         'a script URL is refused';
  assert public.df20_clean_image_url('https://upload.wikimedia.org/a"onerror=x.jpg') is null,
         'a quote that could break out of an attribute is refused';
  assert public.df20_clean_image_url(null) is null, 'null in, null out';
  assert public.df20_clean_image_url(repeat('https://upload.wikimedia.org/', 40)) is null,
         'an absurdly long URL is refused';
  raise notice 'PASS  df20_clean_image_url allowlists rather than trusts';

  -- ── 2. a deck carrying images ───────────────────────────────────────────
  v_h := public.create_room('TEST Football Draft', 5, 2000, 100, 120, 'Ari', true, 2);
  v_code := v_h->>'code'; v_ht := (v_h->>'session_token')::uuid;
  v_rid := (v_h->>'room_id')::uuid;
  v_rooms := v_rooms || v_rid;
  v_g := public.join_room(v_code, 'Bo');

  -- give every pooled item a distinguishable picture before the deck is built
  update public.room_pool
     set image_url = 'https://upload.wikimedia.org/wikipedia/en/LEAK-' || md5(name) || '.jpg',
         image_license = 'nonfree'
   where room_id = v_rid;

  v_s := public.start_draft(v_code, v_ht);

  select count(*) into v_n from public.room_deck
   where room_id = v_rid and image_url is not null;
  assert v_n = 30, 'every deck row carried its image down from the pool';
  raise notice 'PASS  images survive pool -> deck';

  -- ── 3. THE UNDEALT PICTURES ARE HIDDEN ──────────────────────────────────
  assert not exists (
    select 1 from public.room_deck d
     where d.room_id = v_rid and d.revealed_at is null
       and public.df20_public_state(v_rid)::text like '%' || d.image_url || '%'),
    'an undealt image URL leaked into the public state';
  raise notice 'PASS  no undealt picture is reachable';

  -- ── 4. the dealt card DOES carry its own picture ────────────────────────
  v_lot_img := v_s->'lot'->>'image_url';
  assert v_lot_img is not null, 'the card on the block has a picture';
  select d.image_url into v_deck_img from public.room_deck d
   where d.room_id = v_rid and d.revealed_at is not null
   order by d.revealed_at desc limit 1;
  assert v_lot_img = v_deck_img,
         'the lot shows the picture belonging to the card that was dealt';
  assert v_s->'lot'->>'image_license' = 'nonfree', 'the licence travelled too';
  raise notice 'PASS  the dealt card shows its own picture, and only its own';

  -- ── 5. a null image is a normal outcome, not a failure ──────────────────
  update public.room_pool set image_url = null, image_license = null
   where room_id = v_rid;
  assert public.df20_clean_image_url('') is null, 'empty is null, not empty string';
  raise notice 'PASS  a missing picture is representable (client draws a card)';

  -- ── 6. One Piece Characters: the first seeded category with pictures ────
  -- 0029 both adds a host to the allowlist and relies on it, so assert the
  -- pair together: a rejected host would silently null every portrait and
  -- leave a category that still has 80 names and no pictures at all.
  assert public.df20_clean_image_url(
           'https://cdn.myanimelist.net/images/characters/9/310307.jpg') is not null,
         'the MyAnimeList CDN is on the allowlist';
  assert public.df20_clean_image_url('https://cdn.myanimelist.net.evil.com/x.jpg') is null,
         'a lookalike host that merely CONTAINS the allowed one is refused';
  assert public.df20_clean_image_url(
           'https://media.kitsu.app/characters/images/4119/original.jpg') is not null,
         'the Kitsu media CDN is on the allowlist';
  assert public.df20_clean_image_url('https://media.kitsu.app.evil.com/x.jpg') is null,
         'the same lookalike trick is refused for Kitsu';

  -- every seeded anime category, checked the same way
  foreach v_cat in array array['One Piece Characters', 'Naruto Characters',
                               'Demon Slayer Characters', 'Jujutsu Kaisen Characters',
                               'Dragon Ball Z Characters', 'My Hero Academia Characters']
  loop
    select count(*), count(i.image_url), count(distinct i.image_url)
      into v_n, v_imgs, v_distinct
      from public.category_library_items i
      join public.category_library l on l.id = i.library_id
     where l.name_norm = public.df20_norm_category(v_cat);

    -- a room refuses to start unless the pool covers roster_size * 2, so a
    -- category is only as big as the roster it can seat
    assert v_n >= 24, format('%s has only %s items', v_cat, v_n);
    assert v_imgs = v_n, format('%s items in %s have no portrait', v_n - v_imgs, v_cat);
    -- DISTINCT, not merely non-null: the failure mode that ruled Wikipedia out
    -- is several characters resolving to one group photo, and a non-null count
    -- would not notice that at all
    assert v_distinct = v_n,
           format('%s: only %s distinct portraits across %s characters', v_cat, v_distinct, v_n);
    raise notice 'PASS  %: % items, % distinct portraits (max roster %)',
                 v_cat, v_n, v_distinct, v_n / 2;
  end loop;

  -- ── cleanup ─────────────────────────────────────────────────────────────
  delete from public.rooms where id = any(v_rooms);
  raise notice 'ALL IMAGE ASSERTIONS PASSED';
end $test$;
