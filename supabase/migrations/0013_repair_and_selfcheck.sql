-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0013 · repair create_room, and stop this class of bug
--
-- ROOT CAUSE of "function public.df20_clean_logo_url(text) does not exist":
--   create_room was rewritten in 0010 and calls df20_clean_logo_url, which was
--   defined in 0008. 0008 was never applied, so the caller existed without the
--   callee. plpgsql does not validate function bodies at creation, so the
--   migration reported success and the failure only surfaced on a real click.
--
-- Fixed three ways. The third is the one that matters.
--   1. df20_clean_logo_url now lives beside its only caller.
--   2. It returns early when there is no logo, so creating a room never
--      depends on branding machinery existing at all.
--   3. df20_selfcheck() asserts every dependency is present, so a partial
--      apply fails LOUDLY here instead of silently at click time.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── carried from 0008, which is missing on at least one live database ─────
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

-- ── the function that was missing, now beside its caller ──────────────────
create or replace function public.df20_clean_logo_url(p_in text)
returns text language plpgsql immutable as $$
declare v text;
begin
  -- the common case by a mile: no logo. Creating a room must not depend on
  -- any of the branding validation below being reachable.
  if p_in is null or btrim(p_in) = '' then return null; end if;

  v := public.df20_clean_text(p_in, 500);
  if v = '' then return null; end if;

  -- https, and our own storage only. Anything else is a URL a stranger
  -- controls being rendered into someone else's shareable card.
  if v !~ '^https://[A-Za-z0-9.-]+\.supabase\.co/storage/v1/object/public/brand/' then
    raise exception 'DF20_BAD_LOGO_URL';
  end if;
  return v;
end $$;

-- ── brand bucket, also from 0008 ──────────────────────────────────────────
do $$
begin
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('brand', 'brand', true, 524288, array['image/png','image/jpeg','image/webp'])
  on conflict (id) do update
    set public = true, file_size_limit = 524288,
        allowed_mime_types = array['image/png','image/jpeg','image/webp'];
exception when others then
  raise notice 'storage schema unavailable; skipping brand bucket';
end $$;

-- ── WHAT MUST EXIST FOR THE APP TO WORK ───────────────────────────────────
-- Every entry here is something an RPC calls at runtime. Postgres will not
-- check these for us, so we check them ourselves.
create or replace function public.df20_selfcheck()
returns text language plpgsql as $$
declare
  v_missing text[] := '{}';
  f text;
  v_required text[] := array[
    -- money and game loop
    'public.df20_max_legal_bid(integer,integer,integer)',
    'public.df20_open_slots(uuid,uuid)',
    'public.df20_opponent(uuid,uuid)',
    'public.df20_can_outbid(uuid,uuid,integer)',
    'public.df20_is_broke(uuid,uuid)',
    'public.df20_add_to_roster(uuid,uuid,text,integer,boolean)',
    'public.df20_resolve_lot(uuid,text)',
    'public.df20_resolve_gift(uuid,uuid)',
    'public.df20_reveal_next(uuid)',
    'public.df20_advance(uuid)',
    'public.df20_public_state(uuid)',
    'public.df20_broadcast(uuid)',
    'public.df20_touch(uuid)',
    'public.df20_gen_code()',
    -- text safety, the pair that broke
    'public.df20_clean_text(text,integer)',
    'public.df20_clean_logo_url(text)',
    -- categories
    'public.df20_norm_category(text)',
    'public.df20_token_overlap(text,text)',
    'public.df20_match_category(text,integer)',
    'public.df20_fill_pool(uuid,text,uuid)',
    'public.df20_seed_category(text,text[])',
    'public.df20_cache_wikipedia(text,text,text,text[])',
    'public.df20_looks_like_person(text)',
    'public.df20_person_oriented_category(text)',
    -- abuse control
    'public.df20_rate_limit(text,text,integer,integer)',
    'public.df20_ensure_profile()',
    -- the client API
    'public.create_room(text,integer,integer,integer,integer,text,boolean,integer,text,text,text,uuid)',
    'public.create_pending_room()',
    'public.get_setup_state(uuid)',
    'public.setup_lock_items(uuid,text,text[],integer,integer,integer,integer,integer)',
    'public.join_room(text,text)',
    'public.start_draft(text,uuid)',
    'public.offer_decide(text,uuid,text)',
    'public.place_bid(text,uuid,integer,integer)',
    'public.pass_turn(text,uuid,integer)',
    'public.expire_turn(text)',
    'public.submit_vote(text,uuid,uuid)',
    'public.get_room_state(text)',
    'public.offer_library_optin(uuid)',
    'public.submit_library_optin(uuid,boolean)'
  ];
  v_tables text[] := array['rooms','players','room_deck','room_pool','roster_entries',
                           'lots','bid_events','votes','rate_limits','category_library',
                           'category_library_items','category_library_aliases',
                           'wikipedia_cache','wikipedia_cache_items','profiles','templates'];
  t text;
begin
  foreach f in array v_required loop
    if to_regprocedure(f) is null then v_missing := v_missing || f; end if;
  end loop;
  foreach t in array v_tables loop
    if to_regclass('public.' || t) is null then v_missing := v_missing || ('table ' || t); end if;
  end loop;

  if coalesce(array_length(v_missing, 1), 0) > 0 then
    raise exception E'DF20_SELFCHECK_FAILED\nmissing:\n  %',
      array_to_string(v_missing, E'\n  ');
  end if;

  return format('ok - %s functions and %s tables present',
                array_length(v_required, 1), array_length(v_tables, 1));
end $$;
revoke all on function public.df20_selfcheck() from anon, authenticated;
