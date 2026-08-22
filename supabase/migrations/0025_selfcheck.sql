-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0025 · what must exist for v7 to work
--
-- Same job as 0013 and 0020, extended again. plpgsql still does not validate function
-- bodies at creation, so a half-applied bundle still reports success and
-- still fails on a real click. This is the thing that makes it fail loudly
-- here instead. KEEP IT UPDATED WHEN YOU ADD AN RPC.
-- ═══════════════════════════════════════════════════════════════════════════

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
    -- text safety
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
    'public.list_free_categories()',
    -- abuse control and accounts
    'public.df20_rate_limit(text,text,integer,integer)',
    'public.df20_ensure_profile()',
    'public.df20_require_verified()',
    -- the client API
    'public.create_room(text,integer,integer,integer,integer,text,boolean,integer,text,text,text,uuid,text)',
    'public.create_pending_room(text)',
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
    'public.submit_library_optin(uuid,boolean)',
    -- v6: profiles, decks, premium
    'public.df20_premium_active(uuid)',
    'public.my_premium()',
    'public.my_profile_stats()',
    'public.df20_manual_winner(uuid)',
    'public.save_export_style(boolean,text,text,text)',
    'public.df20_export_style(text)',
    'public.save_room_deck(text,text)',
    'public.my_decks()',
    'public.delete_deck(uuid)',
    -- v6: content tab
    'public.mint_obs_token(text,uuid)',
    'public.rotate_obs_token(text,uuid)',
    'public.get_obs_state(uuid)',
    'public.df20_audience_tally(uuid)',
    'public.get_audience_state(text,text)',
    'public.cast_audience_vote(text,text,uuid)',
    'public.get_audience_hub(text,uuid)',
    -- v6: billing
    'public.df20_apply_billing_event(text,text,uuid,text,text,text,timestamptz,text,integer)',
    'public.df20_revoke_premium(text,text,text,text)',
    'public.df20_billing_profile(text,uuid)',
    'public.df20_is_admin()',
    'public.admin_list_profiles(text)',
    'public.admin_set_premium(uuid,integer)',
    -- v7: the clock, the scouting report, the console
    'public.df20_turn_deadline(integer)',
    'public.my_scouting_report()',
    'public.admin_library_queue()',
    'public.admin_review_library(uuid,boolean)',
    'public.admin_library_list()',
    'public.admin_library_remove(uuid)',
    'public.admin_activity()',
    'public.admin_recent_events(integer)',
    'public.df20_log_billing_failure(text,text,text,text)',
    'public.leave_room(text,uuid)'
  ];
  v_tables text[] := array['rooms','players','room_deck','room_pool','roster_entries',
                           'lots','bid_events','votes','rate_limits','category_library',
                           'category_library_items','category_library_aliases',
                           'wikipedia_cache','wikipedia_cache_items','profiles','templates',
                           'df20_config','user_categories','user_category_items',
                           'audience_votes','billing_events'];
  v_columns text[] := array['profiles.premium_until','profiles.premium_source',
                            'profiles.subscription_status','profiles.stripe_customer_id',
                            'profiles.export_watermark','rooms.obs_token',
                            'rooms.content_mode','billing_events.status',
                            'rooms.abandoned_by'];
  t text; c text;
begin
  foreach f in array v_required loop
    if to_regprocedure(f) is null then v_missing := v_missing || f; end if;
  end loop;
  foreach t in array v_tables loop
    if to_regclass('public.' || t) is null then v_missing := v_missing || ('table ' || t); end if;
  end loop;
  foreach c in array v_columns loop
    if not exists (select 1 from information_schema.columns
                    where table_schema = 'public'
                      and table_name = split_part(c, '.', 1)
                      and column_name = split_part(c, '.', 2))
    then v_missing := v_missing || ('column ' || c); end if;
  end loop;

  if coalesce(array_length(v_missing, 1), 0) > 0 then
    raise exception E'DF20_SELFCHECK_FAILED\nmissing:\n  %',
      array_to_string(v_missing, E'\n  ');
  end if;

  return format('ok - %s functions, %s tables and %s columns present',
                array_length(v_required, 1), array_length(v_tables, 1),
                array_length(v_columns, 1));
end $$;
revoke all on function public.df20_selfcheck() from anon, authenticated;

-- two defaults that are product decisions rather than implementation detail,
-- so they are asserted rather than assumed
do $$
declare v_default text;
begin
  select column_default into v_default from information_schema.columns
   where table_schema = 'public' and table_name = 'profiles'
     and column_name = 'export_watermark';
  if v_default is null or v_default not like 'true%' then
    raise exception 'DF20_WATERMARK_DEFAULT_WRONG: profiles.export_watermark defaults to %', v_default;
  end if;
end $$;

do $$
declare v_default text;
begin
  select column_default into v_default from information_schema.columns
   where table_schema = 'public' and table_name = 'rooms'
     and column_name = 'content_mode';
  if v_default is null or v_default not like '''standard''%' then
    raise exception 'DF20_CONTENT_MODE_DEFAULT_WRONG: rooms.content_mode defaults to %', v_default;
  end if;
end $$;
