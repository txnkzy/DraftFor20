-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · v8 · leaving a draft
--
-- The assertion that matters is that NOBODY IS LEFT ON THE CLOCK. Before
-- leave_room existed, closing the tab left the other player watching
-- expire_turn resolve lots on behalf of somebody who had gone.
-- ═══════════════════════════════════════════════════════════════════════════

insert into auth.users (id, email, email_confirmed_at)
values ('d0000000-0000-4000-8000-000000000001','leave@example.com',now())
on conflict (id) do update set email_confirmed_at = now();
set request.jwt.claim.sub = 'd0000000-0000-4000-8000-000000000001';
do $t$
declare v jsonb; v_code text; v_rid uuid; v_ht uuid; v_gt uuid; v_lib uuid; v_err text;
begin
  select id into v_lib from public.category_library
   where name_norm = public.df20_norm_category('Football Draft');

  v := public.create_room('Leave Test', 3, 2000, 100, 300, 'Ari', true, 2,
                          null, null, 'library', v_lib);
  v_code := v->>'code'; v_ht := (v->>'session_token')::uuid; v_rid := (v->>'room_id')::uuid;
  v := public.join_room(v_code, 'Bo'); v_gt := (v->>'session_token')::uuid;
  perform public.start_draft(v_code, v_ht);

  assert (select count(*) from public.lots
           where room_id = v_rid and status in ('offered','bidding')) = 1,
    'a lot is open before anybody leaves';

  -- a stranger cannot close somebody else's room
  v_err := null;
  begin perform public.leave_room(v_code, gen_random_uuid());
  exception when others then v_err := sqlerrm; end;
  assert v_err like '%DF20_BAD_TOKEN%', 'a stranger cannot abandon a room';

  v := public.leave_room(v_code, v_gt);
  assert (v->>'left')::boolean, 'the guest left';
  assert v->>'by' = 'Bo', 'the room records who walked out';

  assert (select status from public.rooms where id = v_rid) = 'abandoned';
  assert (select phase  from public.rooms where id = v_rid) = 'complete';
  assert (select abandoned_by from public.rooms where id = v_rid)
         = (select id from public.players where room_id = v_rid and seat = 2),
    'and which seat it was';
  assert not exists (select 1 from public.lots
                      where room_id = v_rid and status in ('offered','bidding')),
    'NOBODY IS LEFT ON THE CLOCK';
  assert (select count(*) from public.lots
           where room_id = v_rid and turn_expires_at is not null) = 0,
    'and no deadline survives';

  -- the abandonment reaches the other client
  assert (public.get_room_state(v_code)->'room'->>'status') = 'abandoned',
    'the public snapshot says so';

  -- leaving twice is not an error
  v := public.leave_room(v_code, v_ht);
  assert (v->>'left')::boolean = false, 'a second leave is a no-op';

  delete from public.rooms where id = v_rid;
  raise notice 'PASS  leave_room: voids the clock, marks the room, names who left, idempotent';
end $t$;
reset request.jwt.claim.sub;
