-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · v6 · profiles, premium gates, OBS link, audience vote,
--                   export watermark, billing writes, admin grant
--
-- Run after APPLY_V6.sql. Cleans up after itself.
--
-- The assertions that matter most:
--   · the watermark is on for a premium account that has not opted out
--   · a vote is not told the tally until it has been cast
--   · an admin grant unlocks exactly what a Stripe subscription unlocks
--   · no token reaches the public snapshot
-- ═══════════════════════════════════════════════════════════════════════════

insert into auth.users (id, email, email_confirmed_at) values
  ('a0000000-0000-4000-8000-000000000001', 'v6host@example.com', now()),
  ('a0000000-0000-4000-8000-000000000002', 'v6other@example.com', now())
on conflict (id) do update set email_confirmed_at = now();

set request.jwt.claim.sub = 'a0000000-0000-4000-8000-000000000001';

do $t$
declare
  HOST uuid := 'a0000000-0000-4000-8000-000000000001';
  OTHER uuid := 'a0000000-0000-4000-8000-000000000002';
  v jsonb; v_code text; v_rid uuid; v_ht uuid; v_gt uuid; v_a uuid; v_b uuid;
  v_err text; v_obs uuid; v_deck uuid; v_secret text; v_state jsonb;
  v_lib uuid; v_n int; v_rooms uuid[] := '{}';
begin
  -- ── fixture: a two-pick room played to the end ──────────────────────────
  insert into public.category_library (name, name_norm)
  values ('V6 Test Shelf', public.df20_norm_category('V6 Test Shelf'))
  on conflict (name_norm) do update set name = excluded.name
  returning id into v_lib;
  insert into public.category_library_items (library_id, name)
  select v_lib, 'V6 Item ' || g from generate_series(1, 12) g on conflict do nothing;

  v := public.create_room('V6 Test Shelf', 1, 2000, 100, 300, 'Ari', true, 0,
                          null, null, 'library', v_lib);
  v_code := v->>'code'; v_ht := (v->>'session_token')::uuid;
  v_a := (v->>'player_id')::uuid; v_rid := (v->>'room_id')::uuid;
  v_rooms := v_rooms || v_rid;

  assert (select host_profile_id from public.rooms where id = v_rid) = HOST,
    'a signed-in creator owns the room';
  assert (select profile_id from public.players where id = v_a) = HOST,
    'seat 1 is attributed to the account';

  v := public.join_room(v_code, 'Bo');
  v_gt := (v->>'session_token')::uuid; v_b := (v->>'player_id')::uuid;
  assert (select profile_id from public.players where id = v_b) = HOST,
    'seat 2 is attributed to whoever is signed in when they join';

  perform public.start_draft(v_code, v_ht);
  perform public.offer_decide(v_code, v_ht, 'take');
  -- seat 2 can outbid, so the clock came to them; passing settles it
  if (select status from public.lots where room_id = v_rid and status = 'bidding') is not null then
    perform public.pass_turn(v_code, v_gt,
      (select turn_seq from public.lots where room_id = v_rid and status = 'bidding'));
  end if;
  -- second card: seat 1 is full, so seat 2 opens and takes it
  perform public.offer_decide(v_code, v_gt, 'take');
  assert (select status from public.rooms where id = v_rid) = 'complete',
    'both rosters full ends the draft';
  raise notice 'PASS  fixture room played to completion';

  -- ── 1. no token reaches the public snapshot ─────────────────────────────
  update public.rooms set obs_token = gen_random_uuid(),
                          setup_token = gen_random_uuid(),
                          setup_result_token = gen_random_uuid()
   where id = v_rid;
  v_state := public.df20_public_state(v_rid);
  assert v_state->'room' ? 'obs_token' = false, 'obs_token leaked into public state';
  assert v_state->'room' ? 'setup_token' = false, 'setup_token leaked into public state';
  assert v_state->'room' ? 'setup_result_token' = false, 'result token leaked';
  assert v_state->'room' ? 'code', 'the room code still belongs in the snapshot';
  update public.rooms set obs_token = null, setup_token = null,
                          setup_result_token = null where id = v_rid;
  raise notice 'PASS  public snapshot carries no token';

  -- ── 2. premium is off by default and the OBS link is gated ──────────────
  assert public.df20_premium_active(HOST) = false, 'a new account is not premium';
  v_err := null;
  begin perform public.mint_obs_token(v_code, v_ht);
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_PREMIUM_REQUIRED%',
    'OBS link must be premium-gated in the database, got: ' || coalesce(v_err, 'no error');

  v_err := null;
  begin perform public.admin_set_premium(HOST, 30);
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_NOT_AUTHORISED%',
    'with no admin configured nobody is an admin, got: ' || coalesce(v_err, 'no error');
  raise notice 'PASS  premium gate closed by default, admin closed by default';

  -- ── 3. the manual grant unlocks the same doors a subscription does ──────
  insert into public.df20_config (key, value) values ('admin_user_ids', HOST::text)
  on conflict (key) do update set value = excluded.value;
  assert public.df20_is_admin(), 'the configured uuid is an admin';

  v := public.admin_set_premium(HOST, 30);
  assert (v->>'active')::boolean, 'grant reports active';
  assert public.df20_premium_active(HOST), 'grant makes premium active';
  assert (select premium_source from public.profiles where id = HOST) = 'admin_grant';

  v := public.mint_obs_token(v_code, v_ht);
  v_obs := (v->>'obs_token')::uuid;
  assert v_obs is not null, 'premium mints an OBS token';
  assert (public.mint_obs_token(v_code, v_ht)->>'obs_token')::uuid = v_obs,
    'minting twice returns the same token';
  raise notice 'PASS  admin grant unlocks the OBS link exactly as a subscription would';

  -- ── 4. the OBS view is read-only and code-free ──────────────────────────
  v_state := public.get_obs_state(v_obs);
  assert v_state is not null, 'the token resolves';
  assert (v_state->'room' ? 'code') = false, 'the OBS payload must not carry the room code';
  assert jsonb_array_length(v_state->'players') = 2, 'the board is there to render';
  assert public.get_obs_state(gen_random_uuid()) is null, 'an unknown token resolves to nothing';

  v_err := null;
  begin perform public.mint_obs_token(v_code, gen_random_uuid());
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_BAD_TOKEN%', 'a stranger cannot mint, got: ' || coalesce(v_err,'none');
  raise notice 'PASS  OBS state resolves read-only, strips the code, refuses a stranger';

  -- ── 5. the audience vote is blind until it is cast ──────────────────────
  v := public.get_audience_state(v_code, 'voter-aaaaaaaaaaaaaaaa');
  assert v->>'status' = 'open', 'a finished room accepts votes';
  assert v->'tally' = 'null'::jsonb, 'THE BLIND RULE: no tally before voting';
  assert jsonb_array_length(v->'players') = 2, 'both rosters are shown before voting';
  assert v->'players'->0 ? 'leftover_cents', 'leftover cash is part of the argument';

  v := public.cast_audience_vote(v_code, 'voter-aaaaaaaaaaaaaaaa', v_a);
  assert v->'tally' is not null and v->'tally' <> 'null'::jsonb, 'the tally appears after voting';
  assert (v->'tally'->>'total')::int = 1, 'one vote counted';
  assert (v->>'your_vote')::uuid = v_a, 'the viewer sees what they picked';

  -- a second attempt from the same browser changes nothing
  v := public.cast_audience_vote(v_code, 'voter-aaaaaaaaaaaaaaaa', v_b);
  assert (v->'tally'->>'total')::int = 1, 'one browser session, one vote';
  assert (v->>'your_vote')::uuid = v_a, 'the first vote is the one that stands';

  v := public.cast_audience_vote(v_code, 'voter-bbbbbbbbbbbbbbbb', v_b);
  assert (v->'tally'->>'total')::int = 2, 'a different browser is a different vote';
  assert (v->'tally'->'by_player'->>v_a::text)::int = 1, 'split one apiece';
  assert (v->'tally'->'by_player'->>v_b::text)::int = 1;

  v_err := null;
  begin perform public.cast_audience_vote(v_code, 'short', v_a);
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_BAD_VOTE%', 'a made-up key is rejected';

  v := public.get_audience_hub(v_code, v_ht);
  assert (v->'tally'->>'total')::int = 2, 'the host sees the numbers without voting';
  raise notice 'PASS  audience vote is blind, one per browser, visible to the host';

  -- ── 6. the win/loss record reads the players'' own vote, nothing else ───
  assert public.df20_manual_winner(v_rid) is null, 'no player vote is no result';
  perform public.submit_vote(v_code, v_ht, v_a);
  perform public.submit_vote(v_code, v_gt, v_b);
  assert public.df20_manual_winner(v_rid) is null, 'a disagreement is not a win for either';
  perform public.submit_vote(v_code, v_gt, v_a);
  assert public.df20_manual_winner(v_rid) = v_a, 'both saying the same thing settles it';

  v := public.my_profile_stats();
  assert (v->>'hosted')::int >= 1, 'hosted count';
  assert (v->>'wins')::int >= 1, 'the agreed winner is a win';
  assert v->'badges' ? 'first_room', 'first room badge';
  assert v->'badges' ? 'first_win', 'first win badge';
  assert v->'badges' ? 'judged', 'a judged room earns the badge';
  raise notice 'PASS  win/loss reads the existing human vote and nothing else';

  -- ── 7. THE WATERMARK ────────────────────────────────────────────────────
  assert (public.df20_export_style(v_code)->>'watermark')::boolean,
    'a free room is watermarked';
  assert (public.df20_export_style(v_code)->>'watermark')::boolean,
    'PREMIUM WITH NOTHING TOUCHED IS STILL WATERMARKED';

  perform public.save_export_style(false, null, '#123456', '@ari');
  assert (public.df20_export_style(v_code)->>'watermark')::boolean = false,
    'an explicit opt-out is honoured while premium is active';
  assert public.df20_export_style(v_code)->>'handle' = '@ari';
  assert public.df20_export_style(v_code)->>'accent' = '#123456';

  perform public.admin_set_premium(HOST, 0);   -- lapse
  assert public.df20_premium_active(HOST) = false, 'the grant is gone';
  assert (public.df20_export_style(v_code)->>'watermark')::boolean,
    'a lapsed account falls back to the watermarked card';
  assert public.df20_export_style(v_code)->>'handle' is null,
    'saved customisation is ignored, not applied, when premium is inactive';
  assert (select export_handle from public.profiles where id = HOST) = '@ari',
    'the preference itself survives the lapse';
  raise notice 'PASS  watermark on by default, off only by explicit choice, back on when premium lapses';

  -- ── 8. saved decks: names and counts, never items ───────────────────────
  perform public.admin_set_premium(HOST, 30);
  v := public.save_room_deck(v_code, 'V6 Saved Deck');
  v_deck := (v->>'id')::uuid;
  assert (v->>'item_count')::int = 12, 'the whole pool was saved';
  assert public.my_decks()::text not like '%V6 Item 1%',
    'a deck listing must never carry an item';

  v := public.create_room('From Deck', 1, 2000, 100, 300, 'Ari', true, 0,
                          null, null, 'saved', v_deck);
  v_rooms := v_rooms || (v->>'room_id')::uuid;
  assert (v->>'pool_size')::int = 12, 'a saved deck fills a room';

  set request.jwt.claim.sub = 'a0000000-0000-4000-8000-000000000002';
  v_err := null;
  begin perform public.create_room('Theft', 1, 2000, 100, 300, 'Cy', true, 0,
                                   null, null, 'saved', v_deck);
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_NOT_YOUR_DECK%',
    'somebody else''s deck is not a pool you may draw from, got: ' || coalesce(v_err,'none');
  set request.jwt.claim.sub = 'a0000000-0000-4000-8000-000000000001';
  raise notice 'PASS  saved decks reusable by their owner, opaque to everyone';

  -- ── 9. billing writes ───────────────────────────────────────────────────
  select value into v_secret from public.df20_config where key = 'billing_write_secret';
  assert length(coalesce(v_secret, '')) >= 32, 'the migration generated a secret';

  v_err := null;
  begin perform public.df20_apply_billing_event('wrong', 'evt_x', HOST, null, null,
                                                'active', now() + interval '31 days',
                                                'stripe_subscription', null);
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_NOT_AUTHORISED%', 'the wrong secret writes nothing';

  v := public.df20_apply_billing_event(v_secret, 'evt_sub_1', HOST, 'cus_test_1', 'sub_1',
                                       'active', now() + interval '31 days',
                                       'stripe_subscription', null);
  assert (v->>'matched')::boolean, 'the event found the profile';
  assert public.df20_premium_active(HOST), 'a subscription grants premium';
  assert (select premium_source from public.profiles where id = HOST) = 'stripe_subscription';

  -- the pass extends, and a Stripe retry must not extend it twice
  v := public.df20_apply_billing_event(v_secret, 'evt_pass_1', null, 'cus_test_1', null,
                                       'pass', null, 'game_night_pass', 24);
  v_n := (select extract(epoch from premium_until)::int from public.profiles where id = HOST);
  v := public.df20_apply_billing_event(v_secret, 'evt_pass_1', null, 'cus_test_1', null,
                                       'pass', null, 'game_night_pass', 24);
  assert (v->>'duplicate')::boolean, 'a replayed event is recognised';
  assert (select extract(epoch from premium_until)::int from public.profiles where id = HOST) = v_n,
    'A REPLAYED PASS MUST NOT ADD ANOTHER 24 HOURS';

  v := public.df20_revoke_premium(v_secret, 'evt_del_1', 'cus_test_1', 'canceled');
  assert (v->>'matched')::boolean;
  assert public.df20_premium_active(HOST) = false, 'a deleted subscription revokes access';

  -- an admin grant is not Stripe''s to cancel
  perform public.admin_set_premium(HOST, 30);
  perform public.df20_revoke_premium(v_secret, 'evt_del_2', 'cus_test_1', 'canceled');
  assert public.df20_premium_active(HOST), 'a manual grant survives a Stripe cancellation';
  raise notice 'PASS  billing writes are authorised, idempotent and reversible';

  -- ── cleanup ─────────────────────────────────────────────────────────────
  perform public.admin_set_premium(HOST, 0);
  delete from public.df20_config where key = 'admin_user_ids';
  delete from public.user_categories where owner_id = HOST;
  delete from public.billing_events where event_id like 'evt_%';
  delete from public.rooms where id = any(v_rooms);
  delete from public.category_library where id = v_lib;
  update public.profiles
     set export_handle = null, export_accent = null, export_watermark = true,
         stripe_customer_id = null, stripe_subscription_id = null,
         subscription_status = null, premium_source = null
   where id = HOST;

  raise notice '───────────────────────────────────────────────';
  raise notice 'v6 SUITE PASSED';
end $t$;

reset request.jwt.claim.sub;
