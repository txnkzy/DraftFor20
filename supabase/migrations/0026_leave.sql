-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0026 · leaving a draft
--
-- `abandoned` has been a legal value in rooms.status since 0001 and NOTHING
-- HAS EVER SET IT. Closing the tab mid-draft left the other player watching a
-- clock that would tick forever: expire_turn keeps resolving lots on their
-- behalf, the deck keeps dealing, and the room only really ends when the
-- 90-day purge deletes it.
--
-- This is the minimal honest version of leaving:
--   · the room is marked abandoned, with WHO left and WHEN
--   · any open lot is voided, so nobody is left on the clock
--   · the state is broadcast, so the other client finds out immediately
--
-- Deliberately NOT here: no forfeit, no scoring, no winner. Somebody walking
-- out is not a result, and inventing one would be inventing a rule the game
-- does not have.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.rooms
  add column if not exists abandoned_by uuid references public.players(id) on delete set null,
  add column if not exists abandoned_at timestamptz;

create or replace function public.leave_room(p_code text, p_token uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_me public.players;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;

  select * into v_me from public.players
   where room_id = v_room.id and session_token = p_token;
  if not found then raise exception 'DF20_BAD_TOKEN'; end if;

  -- a finished draft has nothing left to abandon; leaving is just navigation
  if v_room.status = 'complete' then
    return jsonb_build_object('status', 'complete', 'left', false);
  end if;
  if v_room.status = 'abandoned' then
    return jsonb_build_object('status', 'abandoned', 'left', false);
  end if;

  -- nobody should be sitting on a clock in a room that is over
  update public.lots
     set status = 'void', on_the_clock_player_id = null,
         turn_expires_at = null, resolved_at = now()
   where room_id = v_room.id and status in ('offered','bidding');

  update public.rooms
     set status = 'abandoned',
         phase = 'complete',
         abandoned_by = v_me.id,
         abandoned_at = now(),
         completed_at = coalesce(completed_at, now())
   where id = v_room.id;

  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);

  return jsonb_build_object('status', 'abandoned', 'left', true,
                            'by', v_me.display_name);
end $$;
grant execute on function public.leave_room(text, uuid) to anon, authenticated;
