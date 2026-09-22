-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0069 · Lineup — five cards, five slots, no takebacks
--
-- A single-player mode. Five cards are dealt from a category one at a time,
-- and each must be placed in a ranked slot before the next is shown. Slots
-- are exclusive, so putting Luffy at 1 is a bet that nothing better is
-- coming — and when Imu turns up two cards later, that bet is the game.
--
-- THE DECK RULE FROM THE DRAFT APPLIES UNCHANGED, and it is the whole
-- integrity story: a player must never see an undealt card. If the next four
-- were reachable the mode would be a sorting exercise rather than a gamble,
-- and the anon key is public, so this cannot be enforced in the UI. The five
-- cards are written to lineup_cards at creation and `revealed` gates what
-- comes back — my_lineup_state never returns a card at a position above it.
--
-- THE FLIP ANIMATION IS NOT A LEAK. The client is handed every image in the
-- CATEGORY to riffle through, which is public the moment you pick it — the
-- premade shelf is on /dev/cards. Forty images say nothing about which five
-- were dealt.
--
-- NO SCORE. There is no power ranking in this database — and Wikipedia
-- traffic, the one popularity signal the seeders use, would get exactly the
-- case that motivates the mode backwards: Imu is the strongest character
-- alive and barely registers, Luffy dominates it. So the verdict comes from
-- people. A finished lineup gets a share link and anyone who opens it rates
-- it out of ten, blind until they have voted, which is the same rule the
-- draft's audience vote already earns its tally by.
--
-- Re-runnable.
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.lineups (
  id               uuid primary key default gen_random_uuid(),
  code             text unique not null,
  session_token    uuid not null default gen_random_uuid(),
  owner_profile_id uuid references public.profiles(id) on delete set null,
  -- the per-device key Quick Play already uses for its daily cap
  solo_key         text,
  category_name    text not null,
  library_id       uuid references public.category_library(id) on delete set null,
  slot_count       int not null default 5 check (slot_count between 3 and 10),
  -- how many of the dealt cards the player has been shown. THE GATE.
  revealed         int not null default 0,
  status           text not null default 'live' check (status in ('live','complete','abandoned')),
  created_at       timestamptz not null default now(),
  completed_at     timestamptz
);
alter table public.lineups enable row level security;
revoke all on table public.lineups from public, anon, authenticated;

create index if not exists lineups_solo_key_day_idx
  on public.lineups (solo_key, created_at) where solo_key is not null;
create index if not exists lineups_owner_idx
  on public.lineups (owner_profile_id) where owner_profile_id is not null;

comment on column public.lineups.revealed is
  'How many of the five dealt cards the player has been shown. Every read '
  'path filters on it, so a card at a higher position cannot reach a client '
  'no matter what it asks for.';

-- position = the order dealt. slot = where the player put it, null until then.
create table if not exists public.lineup_cards (
  lineup_id     uuid not null references public.lineups(id) on delete cascade,
  position      int  not null check (position >= 1),
  item_name     text not null,
  image_url     text,
  image_license text,
  slot          int,
  placed_at     timestamptz,
  primary key (lineup_id, position)
);
alter table public.lineup_cards enable row level security;
revoke all on table public.lineup_cards from public, anon, authenticated;

-- one card per slot, enforced by the database rather than by the check in
-- place_lineup_card: two taps in the same millisecond both pass that read
create unique index if not exists lineup_cards_slot_idx
  on public.lineup_cards (lineup_id, slot) where slot is not null;

create table if not exists public.lineup_ratings (
  lineup_id  uuid not null references public.lineups(id) on delete cascade,
  voter_key  text not null,
  score      int  not null check (score between 1 and 10),
  created_at timestamptz not null default now(),
  primary key (lineup_id, voter_key)
);
alter table public.lineup_ratings enable row level security;
revoke all on table public.lineup_ratings from public, anon, authenticated;

-- ── the daily cap, shared with Quick Play ─────────────────────────────────
-- ONE ALLOWANCE FOR SINGLE PLAYER, not three of each. Two separate caps would
-- mean "three a day" is true of neither mode and the number on screen is a
-- lie in both. Same key, same window, same limit.
create or replace function public.df20_solo_quota(p_key text)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_uid uuid; v_key text; v_used int; v_premium boolean; v_limit int := 3;
begin
  v_uid := (select auth.uid());
  v_premium := v_uid is not null and public.df20_premium_active(v_uid);
  -- an account beats a cookie: it is the identity that cannot be cleared
  v_key := coalesce(v_uid::text, nullif(btrim(coalesce(p_key,'')), ''));

  if v_premium then
    return jsonb_build_object('allowed', true, 'unlimited', true,
                              'used', 0, 'limit', null, 'premium', true);
  end if;
  if v_key is null then
    return jsonb_build_object('allowed', true, 'unlimited', false,
                              'used', 0, 'limit', v_limit, 'premium', false);
  end if;

  select (select count(*) from public.rooms
           where is_solo and solo_key = v_key
             and created_at >= date_trunc('day', now()))
       + (select count(*) from public.lineups
           where solo_key = v_key
             and created_at >= date_trunc('day', now()))
    into v_used;

  return jsonb_build_object(
    'allowed', v_used < v_limit, 'unlimited', false,
    'used', v_used, 'limit', v_limit, 'premium', false,
    'signed_in', v_uid is not null);
end $$;
revoke all on function public.df20_solo_quota(text) from public;
grant execute on function public.df20_solo_quota(text) to anon, authenticated;

-- ── what the player is allowed to see ─────────────────────────────────────
create or replace function public.df20_lineup_state(p_lineup uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v public.lineups;
begin
  select * into v from public.lineups where id = p_lineup;
  if not found then return null; end if;

  return jsonb_build_object(
    'code', v.code,
    'category', v.category_name,
    'slot_count', v.slot_count,
    'revealed', v.revealed,
    'status', v.status,
    'created_at', v.created_at,
    /* The card awaiting a slot. Null once every slot is filled. */
    'current', (select jsonb_build_object(
                         'position', c.position, 'name', c.item_name,
                         'image_url', c.image_url, 'image_license', c.image_license)
                  from public.lineup_cards c
                 where c.lineup_id = v.id and c.position = v.revealed
                   and c.slot is null),
    /* PLACED CARDS ONLY. A card that has not been dealt has no row here at
       all, so there is nothing for a client to read ahead to. */
    'slots', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'slot', c.slot, 'name', c.item_name,
                 'image_url', c.image_url, 'image_license', c.image_license)
               order by c.slot)
          from public.lineup_cards c
         where c.lineup_id = v.id and c.slot is not null), '[]'::jsonb),
    'open_slots', coalesce((
        select jsonb_agg(s order by s)
          from generate_series(1, v.slot_count) s
         where not exists (select 1 from public.lineup_cards c
                            where c.lineup_id = v.id and c.slot = s)), '[]'::jsonb));
end $$;
revoke all on function public.df20_lineup_state(uuid) from public;

-- ── start one ─────────────────────────────────────────────────────────────
create or replace function public.create_lineup(
  p_library_id uuid, p_solo_key text, p_slots int default 5
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_uid uuid; v_lib public.category_library; v_n int; v_id uuid;
        v_code text; v_quota jsonb; v_key text; v_slots int;
begin
  v_uid   := public.df20_ensure_profile();   -- null when signed out, fine
  v_slots := least(greatest(coalesce(p_slots, 5), 3), 10);
  v_key   := nullif(btrim(coalesce(p_solo_key, '')), '');

  v_quota := public.df20_solo_quota(v_key);
  if not (v_quota->>'allowed')::boolean then
    raise exception 'DF20_SOLO_LIMIT';
  end if;

  select * into v_lib from public.category_library where id = p_library_id;
  if not found then raise exception 'DF20_NO_SUCH_CATEGORY'; end if;

  /* category_library IS the free shelf — every row in it is premade and open
     to anyone, which is why there is no gate here. A host-supplied list lives
     in user_categories or wikipedia_cache and this mode does not read either,
     so the premium boundary is drawn by which TABLE is reachable rather than
     by a flag. Adding saved decks later means adding that gate with it. */

  select count(*) into v_n from public.category_library_items
   where library_id = v_lib.id and image_url is not null;
  /* PICTURES ARE THE POINT of a flip-through, so the deck is drawn only from
     items that have one. A category with too few is refused rather than
     dealing blank cards. */
  if v_n < v_slots then raise exception 'DF20_CATEGORY_TOO_SMALL'; end if;

  loop
    v_code := public.df20_gen_code();
    exit when not exists (select 1 from public.lineups where code = v_code);
  end loop;

  insert into public.lineups (code, owner_profile_id, solo_key, category_name,
                              library_id, slot_count, revealed)
  values (v_code, v_uid, v_key, v_lib.name, v_lib.id, v_slots, 1)
  returning id into v_id;

  -- all five dealt NOW, and hidden. Dealing lazily would mean the deck could
  -- be influenced by what the player has already placed.
  insert into public.lineup_cards (lineup_id, position, item_name, image_url, image_license)
  select v_id, row_number() over (order by random()), i.name, i.image_url, i.image_license
    from (select name, image_url, image_license
            from public.category_library_items
           where library_id = v_lib.id and image_url is not null
           order by random() limit v_slots) i;

  return public.df20_lineup_state(v_id)
         || jsonb_build_object('token', (select session_token from public.lineups where id = v_id));
end $$;
revoke all on function public.create_lineup(uuid, text, int) from public;
grant execute on function public.create_lineup(uuid, text, int) to anon, authenticated;

-- ── place the card in front of you ────────────────────────────────────────
create or replace function public.place_lineup_card(
  p_code text, p_token uuid, p_slot int
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v public.lineups; v_card public.lineup_cards;
begin
  -- serialize: two taps on two slots must not both place the same card
  select * into v from public.lineups
   where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_LINEUP'; end if;
  if v.session_token is distinct from p_token then raise exception 'DF20_BAD_TOKEN'; end if;
  if v.status <> 'live' then raise exception 'DF20_ALREADY_DONE'; end if;

  if p_slot is null or p_slot < 1 or p_slot > v.slot_count then
    raise exception 'DF20_BAD_SLOT';
  end if;
  if exists (select 1 from public.lineup_cards
              where lineup_id = v.id and slot = p_slot) then
    raise exception 'DF20_SLOT_TAKEN';
  end if;

  select * into v_card from public.lineup_cards
   where lineup_id = v.id and position = v.revealed and slot is null;
  if not found then raise exception 'DF20_NO_CARD'; end if;

  begin
    update public.lineup_cards set slot = p_slot, placed_at = now()
     where lineup_id = v.id and position = v_card.position;
  exception when unique_violation then
    raise exception 'DF20_SLOT_TAKEN';
  end;

  if v.revealed >= v.slot_count then
    update public.lineups set status = 'complete', completed_at = now()
     where id = v.id;
  else
    update public.lineups set revealed = revealed + 1 where id = v.id;
  end if;

  return public.df20_lineup_state(v.id);
end $$;
revoke all on function public.place_lineup_card(text, uuid, int) from public;
grant execute on function public.place_lineup_card(text, uuid, int) to anon, authenticated;

-- ── resume, after a refresh ───────────────────────────────────────────────
create or replace function public.my_lineup_state(p_code text, p_token uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v public.lineups;
begin
  select * into v from public.lineups where code = upper(btrim(p_code));
  if not found then raise exception 'DF20_NO_LINEUP'; end if;
  if v.session_token is distinct from p_token then raise exception 'DF20_BAD_TOKEN'; end if;
  return public.df20_lineup_state(v.id);
end $$;
revoke all on function public.my_lineup_state(text, uuid) from public;
grant execute on function public.my_lineup_state(text, uuid) to anon, authenticated;

-- ── the finished thing, for anyone holding the link ───────────────────────
-- COMPLETE ONLY. A live lineup is one card from being spoiled, and the link
-- is meant to be shared, so a half-finished one answers "not yet" rather
-- than handing over the slots placed so far.
create or replace function public.public_lineup(p_code text)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v public.lineups;
begin
  select * into v from public.lineups where code = upper(btrim(p_code));
  if not found then raise exception 'DF20_NO_LINEUP'; end if;
  if v.status <> 'complete' then
    return jsonb_build_object('ready', false, 'code', v.code);
  end if;

  return jsonb_build_object(
    'ready', true,
    'code', v.code,
    'category', v.category_name,
    'completed_at', v.completed_at,
    'by', (select nullif(btrim(coalesce(p.handle, '')), '')
             from public.profiles p where p.id = v.owner_profile_id),
    'slots', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'slot', c.slot, 'name', c.item_name,
                 'image_url', c.image_url, 'image_license', c.image_license)
               order by c.slot)
          from public.lineup_cards c
         where c.lineup_id = v.id and c.slot is not null), '[]'::jsonb));
end $$;
revoke all on function public.public_lineup(text) from public;
grant execute on function public.public_lineup(text) to anon, authenticated;

-- ── the tally, earned ─────────────────────────────────────────────────────
-- BLIND UNTIL YOU RATE IT, exactly as the draft's audience vote is. Seeing
-- the average first is how you end up agreeing with it.
create or replace function public.lineup_rating_state(p_code text, p_voter_key text)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v public.lineups; v_key text; v_mine int;
begin
  select * into v from public.lineups where code = upper(btrim(p_code));
  if not found then raise exception 'DF20_NO_LINEUP'; end if;

  v_key := public.df20_clean_text(p_voter_key, 64);
  select score into v_mine from public.lineup_ratings
   where lineup_id = v.id and voter_key = v_key;

  if v_mine is null then
    return jsonb_build_object('voted', false, 'mine', null,
                              'count', null, 'average', null);
  end if;

  return (select jsonb_build_object(
            'voted', true, 'mine', v_mine,
            'count', count(*), 'average', round(avg(score)::numeric, 1))
            from public.lineup_ratings where lineup_id = v.id);
end $$;
revoke all on function public.lineup_rating_state(text, text) from public;
grant execute on function public.lineup_rating_state(text, text) to anon, authenticated;

create or replace function public.rate_lineup(
  p_code text, p_voter_key text, p_score int
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v public.lineups; v_key text;
begin
  v_key := public.df20_clean_text(p_voter_key, 64);
  if length(v_key) < 16 then raise exception 'DF20_BAD_VOTE'; end if;
  if p_score is null or p_score < 1 or p_score > 10 then
    raise exception 'DF20_BAD_VOTE';
  end if;

  select * into v from public.lineups where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_LINEUP'; end if;
  if v.status <> 'complete' then raise exception 'DF20_NOT_COMPLETE'; end if;

  if not public.df20_rate_limit('lineup_rate', v_key, 30, 3600) then
    raise exception 'DF20_RATE_LIMITED';
  end if;

  -- one rating per voter, and it is final: do nothing rather than update, so
  -- nobody can watch the average move by re-voting
  insert into public.lineup_ratings (lineup_id, voter_key, score)
  values (v.id, v_key, p_score)
  on conflict (lineup_id, voter_key) do nothing;

  return public.lineup_rating_state(v.code, v_key);
end $$;
revoke all on function public.rate_lineup(text, text, int) from public;
grant execute on function public.rate_lineup(text, text, int) to anon, authenticated;

-- ── the images the flip riffles through ───────────────────────────────────
-- Every picture in the CATEGORY, which is public the moment it is picked.
-- Forty images say nothing about which five were dealt.
create or replace function public.lineup_flip_images(p_library_id uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_lib public.category_library;
begin
  select * into v_lib from public.category_library where id = p_library_id;
  if not found then raise exception 'DF20_NO_SUCH_CATEGORY'; end if;

  return coalesce((
    select jsonb_agg(i.image_url order by random())
      from (select image_url from public.category_library_items
             where library_id = v_lib.id and image_url is not null
             limit 60) i), '[]'::jsonb);
end $$;
revoke all on function public.lineup_flip_images(uuid) from public;
grant execute on function public.lineup_flip_images(uuid) to anon, authenticated;

-- ── selfcheck ─────────────────────────────────────────────────────────────
create or replace function public.df20_selfcheck_lineups()
returns text language plpgsql
set search_path = public, pg_temp as $$
declare r text;
begin
  foreach r in array array[
    'public.create_lineup(uuid,text,integer)',
    'public.place_lineup_card(text,uuid,integer)',
    'public.my_lineup_state(text,uuid)',
    'public.public_lineup(text)',
    'public.rate_lineup(text,text,integer)',
    'public.lineup_rating_state(text,text)',
    'public.lineup_flip_images(uuid)',
    'public.df20_lineup_state(uuid)'
  ] loop
    if to_regprocedure(r) is null then
      raise exception 'DF20_SELFCHECK: % is missing', r; end if;
  end loop;

  foreach r in array array['lineups','lineup_cards','lineup_ratings'] loop
    if to_regclass('public.' || r) is null then
      raise exception 'DF20_SELFCHECK: table % is missing', r; end if;
  end loop;

  -- the deck rule: no client role may read the cards table directly, or the
  -- undealt four are one PostgREST call away
  if has_table_privilege('anon', 'public.lineup_cards', 'select')
     or has_table_privilege('authenticated', 'public.lineup_cards', 'select') then
    raise exception 'DF20_SELFCHECK: lineup_cards is readable by a client role';
  end if;

  return 'lineups ok';
end $$;
revoke all on function public.df20_selfcheck_lineups() from public;

select public.df20_selfcheck_lineups();
