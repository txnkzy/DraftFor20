-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0036 · a tally a spectator can poll without breaking the blind
--
-- The vote page opens a realtime connection PER VIEWER. One popular link can
-- therefore consume more realtime connections on its own than every live game
-- combined — during exactly the spike this is meant to survive. Polling is the
-- right trade for a number that changes every few seconds.
--
-- But polling needs an endpoint, and the obvious one breaks the blind rule:
-- a public "give me the tally" RPC hands the answer to anyone who never voted,
-- and the anon key is in every browser.
--
-- So the rule stays in the database. This returns the tally ONLY to a voter
-- key that has actually voted in that room. Calling it directly with the anon
-- key gets you nothing you had not already earned.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.get_audience_tally_for_voter(
  p_code text, p_voter_key text
) returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_ref text;
begin
  v_ref := btrim(coalesce(p_code, ''));
  if v_ref ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into v_room from public.rooms where id = v_ref::uuid;
  else
    select * into v_room from public.rooms where code = upper(v_ref);
  end if;
  if not found or v_room.status <> 'complete' then
    return jsonb_build_object('status','gone');
  end if;

  -- THE BLIND RULE, still enforced here and not in the route
  if not exists (select 1 from public.audience_votes
                  where room_id = v_room.id
                    and voter_key = coalesce(p_voter_key, '')) then
    return jsonb_build_object('status','not_voted');
  end if;

  return jsonb_build_object('status','open',
                            'tally', public.df20_audience_tally(v_room.id));
end $$;
grant execute on function public.get_audience_tally_for_voter(text, text) to anon, authenticated;
