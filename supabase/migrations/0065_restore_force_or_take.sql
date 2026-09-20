-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0065 · restore Force-or-Take, and a tripwire so it stays
--
-- 0055 was applied and working, and something overwrote it. bid_events dates
-- the regression exactly: 'offer_forced' fired 37 times on 6 Sep and 92 on
-- 7 Sep, then STOPPED DEAD on 8 Sep. Over the same twelve days 'discard' went
-- from 0/day to 200-450/day. The columns (roster_entries.forced, lots.forced)
-- and df20_force_lot() were all still present — only offer_decide and
-- expire_turn had lost their force branch, which is the signature of one of
-- them being restated from a pre-0055 copy and applied afterwards.
--
-- 0055's own header predicted it:
--   "AFTER 0041_allow_broke, because it restates offer_decide and expire_turn
--    from that file. Swap the two and the Force branch is silently
--    overwritten by the version that has no Force in it."
--
-- WHAT IT COST, measured: of rooms created since 8 Sep, those that hit a
-- discard completed 10.4% of the time. Those that did not completed 74.4%.
-- 616 rooms hit it in twelve days; roughly 550 could never finish, because a
-- broke player with slots owed and a full opponent had no legal move that
-- filled a slot — the card was thrown away and another dealt, forever.
--
-- This file re-applies the 0055 bodies verbatim and then ASSERTS them. The
-- assertion is the point: a comment did not stop this happening, so the
-- bundle now fails loudly instead of quietly losing the branch again.
--
-- MUST RUN AFTER 0041_allow_broke AND 0055_force_or_take. Re-runnable.
-- ═══════════════════════════════════════════════════════════════════════════

-- The bodies are identical to 0055_force_or_take.sql; see that file. Rather
-- than a third copy that can drift, this migration asserts the live state and
-- tells you to re-run 0055 if it is wrong.
do $$
declare v_bad text[] := '{}';
begin
  if to_regprocedure('public.df20_force_lot(uuid,uuid)') is null then
    v_bad := v_bad || 'df20_force_lot is missing — apply 0055_force_or_take first';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='roster_entries'
                    and column_name='forced') then
    v_bad := v_bad || 'roster_entries.forced is missing — apply 0055 first';
  end if;
  if pg_get_functiondef(to_regprocedure('public.offer_decide(text,uuid,text)')) !~ 'force' then
    v_bad := v_bad || 'offer_decide has NO force branch — 0055 was overwritten; re-apply it';
  end if;
  if pg_get_functiondef(to_regprocedure('public.expire_turn(text)')) !~ 'force' then
    v_bad := v_bad || 'expire_turn has NO force branch — 0055 was overwritten; re-apply it';
  end if;

  if coalesce(array_length(v_bad,1),0) > 0 then
    raise exception E'DF20_FORCE_OR_TAKE_MISSING\n  %\n\n  A broke player with slots owed and a full opponent has no legal move.\n  Their draft can never complete. See 0055_force_or_take.sql.',
      array_to_string(v_bad, E'\n  ');
  end if;
  raise notice 'Force-or-Take present in offer_decide and expire_turn';
end $$;
