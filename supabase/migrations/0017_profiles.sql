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
