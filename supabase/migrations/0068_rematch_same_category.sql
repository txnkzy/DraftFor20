-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0068 · a rematch plays the category you just played
--
-- "Run it back" dealt Football Draft no matter what you had been playing, and
-- the board still said the original category's name. Two separate bugs
-- adding up to a mislabelled game:
--
--   create_rematch called df20_fill_pool(new, pool_source, NULL), and that
--   function treats a null ref as "no category given" and falls back to
--   Football Draft. Meanwhile create_rematch copied category_name straight
--   across, and fill_pool's `coalesce(category_name, v_name)` kept the copy.
--   So the room was LABELLED with your category and DEALT from another one.
--
--   For a wikipedia or saved deck it was worse: a null ref raises
--   DF20_NO_SUCH_CATEGORY, so the button just failed.
--
-- THE POOL IS COPIED, NOT REBUILT. rooms has no pool_ref column to carry, and
-- adding one would still not cover a handoff room whose list was typed by a
-- third party and exists nowhere else. The old room's room_pool already holds
-- exactly the right items, so copy those rows. It is source-agnostic —
-- builtin, library, wikipedia, saved and manual all work the same way — and
-- it cannot drift from what was actually played.
--
-- The DECK is still drawn fresh: start_draft takes a random subset of the
-- pool, so a rematch is the same category reshuffled, never the same order.
--
-- QUICK PLAY WAS ALSO BROKEN, for a different reason. A solo room carries
-- is_solo on the room and is_bot on the opponent's seat, and create_rematch
-- copied neither. The rematch came out as a two-human room containing a seat
-- nobody holds the token for, so the bot never moved and the player sat
-- waiting on an opponent that did not exist. solo_key is copied too, which
-- also closes a quota hole: without it a rematch was not counted against the
-- three-a-day cap, so the cap could be walked around by pressing Run it back.
--
-- Re-runnable.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.create_rematch(p_code text, p_token uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_old public.rooms; v_me public.players; v_new public.rooms; v_n int;
begin
  select * into v_old from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;

  select * into v_me from public.players
   where room_id = v_old.id and session_token = p_token;
  if not found then raise exception 'DF20_NOT_IN_ROOM'; end if;

  if v_old.status not in ('complete', 'abandoned') then
    raise exception 'DF20_NOT_FINISHED';
  end if;

  -- somebody already pressed it: hand back the same room rather than making
  -- a second one, so two people tapping at once cannot fork the rematch
  select * into v_new from public.rooms where rematch_of = v_old.id limit 1;
  if found then
    return (select jsonb_build_object(
              'code', v_new.code, 'room_id', v_new.id, 'player_id', np.id,
              'token', np.session_token, 'seat', np.seat, 'created', false)
              from public.players np
             where np.room_id = v_new.id and np.seat = v_me.seat);
  end if;

  insert into public.rooms (
      code, title, roster_size, starting_bankroll_cents, min_bid_cents,
      timer_seconds, gives_per_player, is_private, brand_accent, brand_logo_url,
      host_profile_id, content_mode, allow_broke, category_name, pool_source,
      is_solo, solo_key, rematch_of)
  select public.df20_gen_code(), v_old.title, v_old.roster_size,
         v_old.starting_bankroll_cents, v_old.min_bid_cents, v_old.timer_seconds,
         v_old.gives_per_player, v_old.is_private, v_old.brand_accent,
         v_old.brand_logo_url, v_old.host_profile_id, v_old.content_mode,
         v_old.allow_broke, v_old.category_name, v_old.pool_source,
         v_old.is_solo, v_old.solo_key,
         v_old.id
  returning * into v_new;

  -- both seats, same names, fresh tokens — and is_bot, or the opponent in a
  -- Quick Play rematch is a human seat nobody can sit in
  insert into public.players (room_id, seat, display_name, bankroll_cents,
                              is_host, profile_id, is_bot)
  select v_new.id, p.seat, p.display_name, v_new.starting_bankroll_cents,
         p.is_host, p.profile_id, p.is_bot
    from public.players p where p.room_id = v_old.id;

  -- THE SAME LIST, copied rather than looked up again
  insert into public.room_pool (room_id, name, image_url, image_license)
  select v_new.id, rp.name, rp.image_url, rp.image_license
    from public.room_pool rp where rp.room_id = v_old.id
  on conflict do nothing;

  select count(*) into v_n from public.room_pool where room_id = v_new.id;

  /* Only if the old room somehow kept no pool — it is emptied by nothing
     today, but a rematch that silently deals the wrong category is the bug
     this migration exists to fix, so the fallback is the documented lookup
     rather than a default. */
  if v_n = 0 then
    v_n := public.df20_fill_pool(v_new.id, coalesce(v_old.pool_source, 'builtin'), null);
  end if;

  if v_n < v_new.roster_size * 2 then raise exception 'DF20_POOL_TOO_SMALL'; end if;

  perform public.df20_touch(v_old.id);
  perform public.df20_broadcast(v_old.id);   -- the other screen learns of it

  return (select jsonb_build_object(
            'code', v_new.code, 'room_id', v_new.id, 'player_id', np.id,
            'token', np.session_token, 'seat', np.seat, 'created', true)
            from public.players np
           where np.room_id = v_new.id and np.seat = v_me.seat);
end $$;

revoke all on function public.create_rematch(text, uuid) from public;
grant execute on function public.create_rematch(text, uuid) to anon, authenticated;

notify pgrst, 'reload schema';
