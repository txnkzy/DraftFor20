-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0037 · a global budget for somebody else's API
--
-- The per-account limit (10 lookups/hour) protects US from one user. It does
-- nothing about a thousand hosts each making their first perfectly legitimate
-- lookup during a spike — every one within its own budget, all of it landing
-- on Wikimedia at once. Getting the app's egress IP throttled or blocked by
-- Wikidata is a self-inflicted outage that no per-account rule can prevent.
--
-- So there is a second, GLOBAL budget on top. When aggregate lookups exceed
-- it in a short window, the category chain stops calling out and falls
-- straight to the manual-setup path — which already exists, already works,
-- and is a far better outcome than being blocked for a day.
--
-- Reuses df20_rate_limit: same fixed-window table, same failure posture
-- (fails OPEN, because a broken limiter must not take down room creation).
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.df20_external_budget(p_service text)
returns boolean language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_limit int; v_window int := 60;
begin
  -- Per MINUTE, aggregate across every account. Wikimedia's published
  -- courtesy guidance is well above these; the point is to stay obviously
  -- polite under a surge, not to run near any documented ceiling.
  v_limit := case p_service
               when 'wikidata'  then 30   -- SPARQL is the expensive one
               when 'wikipedia' then 60
               when 'pageviews' then 60
               else 30
             end;

  return public.df20_rate_limit('global_' || p_service, 'all', v_limit, v_window);
end $$;
grant execute on function public.df20_external_budget(text) to anon, authenticated;
