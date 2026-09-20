-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0057 · one free category lookup, so the paywall has a memory
--
-- "Type your own" is the feature worth paying for and the one nobody has
-- seen. A padlock in front of it asks for money against an imagined benefit.
-- This gives every signed-in free account ONE room built from a typed
-- category — full size, nothing held back — and puts the wall at the second
-- one, where the pitch is "again" rather than "at all".
--
-- WHY THE UNIT IS A LOOKUP AND NOT A DECK. save_room_deck() has always been
-- free, but a free account can only ever save a room it was allowed to
-- create, which means a shelf category — a copy of something already on the
-- shelf. There is no free path to original content, so "one free saved deck"
-- would hand somebody a duplicate and teach them nothing. The lookup is the
-- moment that sells the tier; that is what has to be given away.
--
-- WHY NOT A CREDIT COLUMN. The allowance is counted from rooms that exist:
--
--   not exists (select 1 from rooms where host_profile_id = me
--                 and pool_source = 'wikipedia')
--
-- No column to migrate, nothing to get out of step with reality, and a room
-- deleted by the 90-day purge quietly returns the credit — which is a fair
-- reading of "you have not got one any more" and cheaper than defending
-- against it.
--
-- Anonymous hosts are unchanged: v_uid is null for them, so they cannot
-- consume an allowance that has nobody to bill later. Content Creator mode
-- and the other pool sources are untouched.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.create_room(
  p_title text, p_roster_size int, p_bankroll_cents int, p_min_bid_cents int,
  p_timer_seconds int, p_host_name text, p_is_private boolean default true,
  p_gives_per_player int default 2, p_brand_accent text default null,
  p_brand_logo_url text default null,
  p_pool_source text default 'builtin', p_pool_ref uuid default null,
  p_content_mode text default 'standard',
  p_allow_broke boolean default true
) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $BODY$

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

  -- FREE IS THE SHELF. builtin and library stay open to everyone, signed in
  -- or not; anything the host supplies themselves is premium — with one
  -- deliberate exception, below.
  if coalesce(p_pool_source, 'builtin') not in ('builtin', 'library')
     and (v_uid is null or not public.df20_premium_active(v_uid)) then

    /* ONE FREE LOOKUP, EVER. A padlock on "type your own" asks people to pay
       for a thing they have never seen work. This lets a signed-in free
       account build ONE room from a typed category, at full size with
       nothing crippled, so the pitch becomes "you have done this once" —
       and the wall arrives the moment they want to do it again.

       Counted from rooms actually created, not from an allowance column, so
       there is no state to get out of step and nothing to reset. Only
       'wikipedia' qualifies: 'saved' and 'manual' both depend on content a
       free account has no way to produce, so giving those away free would
       unlock an empty room rather than the feature. */
    if coalesce(p_pool_source, '') = 'wikipedia'
       and v_uid is not null
       and not exists (select 1 from public.rooms r
                        where r.host_profile_id = v_uid
                          and r.pool_source = 'wikipedia') then
      null;   -- their one free build; fall through and make the room
    else
      raise exception 'DF20_PREMIUM_REQUIRED';
    end if;
  end if;

  -- CONTENT CREATOR is chosen here, at creation, and never changes. The
  -- room's whole layout is decided by this column, so letting it be flipped
  -- mid-draft would mean re-laying-out a board somebody is streaming.
  p_content_mode := coalesce(nullif(btrim(lower(p_content_mode)), ''), 'standard');
  if p_content_mode not in ('standard', 'creator') then
    raise exception 'DF20_BAD_CONTENT_MODE';
  end if;
  if p_content_mode = 'creator'
     and (v_uid is null or not public.df20_premium_active(v_uid)) then
    raise exception 'DF20_PREMIUM_REQUIRED';
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
  -- 0 is the no-limit sentinel; 1 and 2 seconds are still nonsense
  if p_timer_seconds is null
     or not (p_timer_seconds = 0 or p_timer_seconds between 3 and 300)
    then raise exception 'DF20_BAD_TIMER'; end if;
  if p_gives_per_player is null or p_gives_per_player < 0 or p_gives_per_player > 30
    then raise exception 'DF20_BAD_GIVES'; end if;

  v_accent := public.df20_clean_text(p_brand_accent, 9);
  if v_accent = '' then v_accent := null; end if;
  if v_accent is not null and v_accent !~ '^#[0-9A-Fa-f]{6}$'
    then raise exception 'DF20_BAD_ACCENT'; end if;

  insert into public.rooms (code, title, roster_size, starting_bankroll_cents,
                            min_bid_cents, timer_seconds, gives_per_player,
                            is_private, brand_accent, brand_logo_url, host_profile_id,
                            content_mode, allow_broke)
  values (public.df20_gen_code(), p_title, p_roster_size, p_bankroll_cents,
          p_min_bid_cents, p_timer_seconds, p_gives_per_player,
          coalesce(p_is_private, true), v_accent,
          public.df20_clean_logo_url(p_brand_logo_url), v_uid,
          p_content_mode, coalesce(p_allow_broke, true))
  returning * into v_room;

  v_n := public.df20_fill_pool(v_room.id, coalesce(p_pool_source, 'builtin'), p_pool_ref);
  if v_n < p_roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;

  insert into public.players (room_id, seat, display_name, bankroll_cents, is_host, profile_id)
  values (v_room.id, 1, p_host_name, p_bankroll_cents, true, v_uid)
  returning * into v_pl;

  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code,
                            'player_id', v_pl.id, 'session_token', v_pl.session_token,
                            'seat', 1, 'pool_size', v_n,
                            'content_mode', v_room.content_mode);
end 
$BODY$;
grant execute on function public.create_room(
  text,int,int,int,int,text,boolean,int,text,text,text,uuid,text,boolean) to anon, authenticated;

-- how many free lookups this account has left, for the button that offers it
create or replace function public.my_free_lookup()
returns jsonb language sql stable security definer
set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'signed_in', (select auth.uid()) is not null,
    'used', (select auth.uid()) is not null and exists (
              select 1 from public.rooms r
               where r.host_profile_id = (select auth.uid())
                 and r.pool_source = 'wikipedia'));
$$;
grant execute on function public.my_free_lookup() to anon, authenticated;

notify pgrst, 'reload schema';
