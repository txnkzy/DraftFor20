-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0000 · reset v1
--
-- v1 auctioned category slots that players nominated by typing. v2 has no
-- positions and no nomination: the server deals from a hidden deck. The shapes
-- are different enough that altering in place would leave the schema carrying
-- a model we abandoned, so this drops the game objects and 0001 rebuilds.
--
-- Only DraftFor20's own objects are touched. Nothing Supabase manages is.
-- ═══════════════════════════════════════════════════════════════════════════

do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and (p.proname like 'df20\_%' escape '\'
            or p.proname in ('create_room','join_room','start_draft','nominate',
                             'place_bid','pass_turn','expire_turn','force_or_take',
                             'submit_vote','get_room_state','offer_decide'))
  loop
    execute 'drop function if exists ' || r.sig || ' cascade';
  end loop;
end $$;

drop table if exists
  public.votes, public.bid_events, public.lots, public.roster_entries,
  public.room_deck, public.slots, public.players, public.rooms,
  public.templates, public.rate_limits, public.nfl_players
cascade;
