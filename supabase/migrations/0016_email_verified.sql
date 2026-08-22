-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0016 · confirmed email required for the premium paths
--
-- Deliberately NOT folded into df20_ensure_profile(): that runs on every
-- create_room including the free shelf, so raising there would lock an
-- unconfirmed account out of Football Draft too. Verification gates the
-- premium paths only.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.df20_require_verified()
returns uuid language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_uid uuid; v_confirmed timestamptz;
begin
  v_uid := public.df20_ensure_profile();
  if v_uid is null then raise exception 'DF20_SIGNIN_REQUIRED'; end if;

  -- If the project has "Confirm email" switched off, Supabase stamps this at
  -- creation and the check simply always passes.
  begin
    select u.email_confirmed_at into v_confirmed from auth.users u where u.id = v_uid;
  exception when others then
    v_confirmed := now();   -- column absent: do not invent a lockout
  end;

  if v_confirmed is null then raise exception 'DF20_EMAIL_UNVERIFIED'; end if;
  return v_uid;
end $$;
revoke all on function public.df20_require_verified() from anon, authenticated;

-- ── the setup-link handoff ────────────────────────────────────────────────
create or replace function public.create_pending_room()
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_uid uuid;
begin
  v_uid := public.df20_require_verified();

  if not public.df20_rate_limit('pending_room', v_uid::text, 20, 3600) then
    raise exception 'DF20_RATE_LIMITED';
  end if;

  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, host_profile_id,
                            setup_token, setup_expires_at, pool_source)
  values (null, 'Untitled draft', 5, 2000, 100, 15, v_uid,
          gen_random_uuid(), now() + interval '24 hours', 'manual')
  returning * into v_room;

  return jsonb_build_object('setup_token', v_room.setup_token,
                            'expires_at', v_room.setup_expires_at,
                            'room_id', v_room.id);
end $$;
grant execute on function public.create_pending_room() to anon, authenticated;

-- ── the typed-category pool ───────────────────────────────────────────────
-- Only the wikipedia branch is gated. builtin and library stay free, and an
-- unconfirmed account can still play everything on the shelf.
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
  if coalesce(p_pool_source, 'builtin') = 'wikipedia' then
    v_uid := public.df20_require_verified();
  else
    v_uid := public.df20_ensure_profile();   -- null when signed out, which is fine
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
