-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0002 · Row Level Security
--
-- Deny-all is the design, not an oversight. RLS is enabled on every table and
-- anonymous clients get NO policies, so no browser can read or write any table
-- directly. Every read goes through get_room_state and every write through a
-- SECURITY DEFINER function that authenticates the caller by session token.
--
-- This is what keeps room_deck secret. A client cannot ask the database what
-- is coming up next, because a client cannot ask the database anything.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.profiles       enable row level security;
alter table public.templates      enable row level security;
alter table public.rooms          enable row level security;
alter table public.players        enable row level security;
alter table public.room_deck      enable row level security;
alter table public.roster_entries enable row level security;
alter table public.lots           enable row level security;
alter table public.bid_events     enable row level security;
alter table public.votes          enable row level security;
alter table public.rate_limits    enable row level security;
alter table public.nfl_players    enable row level security;

-- host accounts own their own row and nothing else. profiles survives a
-- re-run, so its policies have to be replaced rather than created.
drop policy if exists profiles_select_own on public.profiles;
drop policy if exists profiles_insert_own on public.profiles;
drop policy if exists profiles_update_own on public.profiles;
drop policy if exists templates_all_own   on public.templates;

create policy profiles_select_own on public.profiles
  for select to authenticated using (id = (select auth.uid()));
create policy profiles_insert_own on public.profiles
  for insert to authenticated with check (id = (select auth.uid()));
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy templates_all_own on public.templates
  for all to authenticated
  using (owner_id = (select auth.uid())) with check (owner_id = (select auth.uid()));

-- Defence in depth. RLS already denies these; the revoke means a future policy
-- added by accident still cannot expose them.
revoke all on public.players        from anon, authenticated;
revoke all on public.rooms          from anon, authenticated;
revoke all on public.room_deck      from anon, authenticated;
revoke all on public.lots           from anon, authenticated;
revoke all on public.roster_entries from anon, authenticated;
revoke all on public.bid_events     from anon, authenticated;
revoke all on public.votes          from anon, authenticated;
revoke all on public.rate_limits    from anon, authenticated;
revoke all on public.nfl_players    from anon, authenticated;
