-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0008 · abuse control and brand uploads
-- ═══════════════════════════════════════════════════════════════════════════

-- ── fixed-window rate limiter ──────────────────────────────────────────────
-- Called from Next route handlers with the caller's IP. Returns true if the
-- request is allowed. A table rather than Redis because this has to work on
-- serverless with no extra infrastructure.
create or replace function public.df20_rate_limit(
  p_bucket text, p_subject text, p_limit int, p_window_seconds int
) returns boolean language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_start timestamptz; v_count int;
begin
  if p_window_seconds < 1 then p_window_seconds := 60; end if;
  v_start := to_timestamp(
    floor(extract(epoch from now()) / p_window_seconds) * p_window_seconds);

  insert into public.rate_limits (bucket, subject, window_start, count)
  values (left(p_bucket, 40), left(p_subject, 100), v_start, 1)
  on conflict (bucket, subject, window_start)
  do update set count = public.rate_limits.count + 1
  returning count into v_count;

  return v_count <= p_limit;
end $$;
grant execute on function public.df20_rate_limit(text, text, int, int) to anon, authenticated;

-- ── host brand logos ───────────────────────────────────────────────────────
-- 512KB cap, raster only. SVG is deliberately excluded: it can carry script
-- and this file gets rendered onto other people's shareable cards.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('brand', 'brand', true, 524288,
        array['image/png','image/jpeg','image/webp'])
on conflict (id) do update
  set public = true,
      file_size_limit = 524288,
      allowed_mime_types = array['image/png','image/jpeg','image/webp'];

-- a signed-in host may only write inside a folder named after their own uid
drop policy if exists brand_read   on storage.objects;
drop policy if exists brand_insert on storage.objects;
drop policy if exists brand_update on storage.objects;
drop policy if exists brand_delete on storage.objects;

create policy brand_read on storage.objects
  for select to anon, authenticated using (bucket_id = 'brand');

create policy brand_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'brand'
              and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy brand_update on storage.objects
  for update to authenticated
  using (bucket_id = 'brand'
         and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy brand_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'brand'
         and (storage.foldername(name))[1] = (select auth.uid())::text);

-- ── brand logo URLs must be https and must point at our own storage ───────
-- Anything else is a URL a stranger controls being rendered into someone
-- else's shareable card.
create or replace function public.df20_clean_logo_url(p_in text)
returns text language plpgsql immutable as $$
declare v text;
begin
  v := public.df20_clean_text(p_in, 500);
  if v = '' then return null; end if;
  if v !~ '^https://[A-Za-z0-9.-]+\.supabase\.co/storage/v1/object/public/brand/' then
    raise exception 'DF20_BAD_LOGO_URL';
  end if;
  return v;
end $$;

create or replace function public.create_room(
  p_title text, p_roster_size int, p_bankroll_cents int, p_min_bid_cents int,
  p_timer_seconds int, p_host_name text, p_is_private boolean default true,
  p_gives_per_player int default 2, p_brand_accent text default null,
  p_brand_logo_url text default null
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_pl public.players; v_uid uuid; v_pool int; v_accent text;
begin
  v_uid := auth.uid();

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

  -- accent must be a plain hex colour, never arbitrary CSS
  v_accent := public.df20_clean_text(p_brand_accent, 9);
  if v_accent = '' then v_accent := null; end if;
  if v_accent is not null and v_accent !~ '^#[0-9A-Fa-f]{6}$'
    then raise exception 'DF20_BAD_ACCENT'; end if;

  select count(*) into v_pool from public.nfl_players;
  if v_pool < p_roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;

  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, gives_per_player,
                            is_private, brand_accent, brand_logo_url, host_profile_id)
  values (public.df20_gen_code(), p_title, p_roster_size, p_bankroll_cents,
          p_min_bid_cents, p_timer_seconds, p_gives_per_player,
          coalesce(p_is_private, true), v_accent,
          public.df20_clean_logo_url(p_brand_logo_url), v_uid)
  returning * into v_room;

  insert into public.players (room_id, seat, display_name, bankroll_cents, is_host, profile_id)
  values (v_room.id, 1, p_host_name, p_bankroll_cents, true, v_uid)
  returning * into v_pl;

  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code,
                            'player_id', v_pl.id, 'session_token', v_pl.session_token,
                            'seat', 1);
end $$;
grant execute on function public.create_room(text, int, int, int, int, text, boolean, int, text, text) to anon, authenticated;
