-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0057 · a username people choose, and a board they appear on
--
-- THIS REVERSES 0031, DELIBERATELY. That migration locked the handle and
-- argued it is a user ID: assigned, not chosen, because "an identifier people
-- can swap around is a poor one — it breaks any reference anybody wrote
-- down". That was right for what the handle did then, which was stand in for
-- an email on an admin screen. A leaderboard changes the job: a name nobody
-- picked is a name nobody wants to be seen under, and 'k3m9x2pq' at the top
-- of a public table is worth nothing to the person who earned it.
--
-- The 0031 objection is answered rather than ignored: NOTHING references a
-- handle. It appears on the admin list and nowhere else — no URL, no share
-- card (that is export_handle, a different column), no foreign key. The
-- account's identity is still its uuid; the handle is now display only.
--
-- handle_chosen separates the two states, because "auto-generated" cannot be
-- detected from the string itself — df20_gen_handle draws from the same
-- alphabet a person might type. Without the flag there is no way to know who
-- still needs prompting.
--
-- Re-runnable.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.profiles
  add column if not exists handle_chosen boolean not null default false,
  add column if not exists handle_updated_at timestamptz;

comment on column public.profiles.handle_chosen is
  'true once the account picked its own handle. false means df20_gen_handle '
  'minted it and the user should still be asked. Not derivable from the '
  'string: the generator uses the same alphabet a person would type.';

-- ── validation, in ONE place ──────────────────────────────────────────────
-- Returns a machine-readable reason or null when the name is fine. Every
-- caller — the signup trigger, the rename RPC, the availability check — asks
-- this, so the rules cannot drift between the form that checks and the
-- function that enforces.
create or replace function public.df20_handle_problem(p_handle text)
returns text language plpgsql immutable as $$
declare v text;
begin
  v := lower(btrim(coalesce(p_handle, '')));

  if length(v) = 0                then return 'required';   end if;
  if length(v) < 3                then return 'too_short';  end if;
  if length(v) > 20               then return 'too_long';   end if;
  if v !~ '^[a-z0-9_]+$'          then return 'charset';    end if;
  if v !~ '^[a-z0-9]'             then return 'edge';       end if;  -- no leading _
  if v !~ '[a-z0-9]$'             then return 'edge';       end if;  -- no trailing _
  if v ~ '__'                     then return 'edge';       end if;

  -- Names that would let somebody pose as the site or as staff, plus the
  -- top-level route names, so a username can never read as a page path.
  if v = any (array[
      'admin','administrator','root','staff','mod','moderator','support','help',
      'system','official','draftfor20','draft420','df20','team','owner',
      'api','auth','login','signin','signup','logout','profile','settings',
      'billing','pricing','room','rooms','new','vote','votes','results','setup',
      'leaderboard','dev','obs','privacy','terms','about','contact','null',
      'undefined','anonymous','anon','you','everyone','host','guest'])
  then return 'reserved'; end if;

  return null;
end $$;

-- ── is it free? ───────────────────────────────────────────────────────────
-- Answers for the CALLER, so their own current handle never reads as taken.
-- Deliberately does not say who holds a name.
create or replace function public.handle_available(p_handle text)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v text; v_problem text; v_uid uuid;
begin
  v_problem := public.df20_handle_problem(p_handle);
  if v_problem is not null then
    return jsonb_build_object('available', false, 'problem', v_problem);
  end if;

  v := lower(btrim(p_handle));
  v_uid := auth.uid();
  if exists (select 1 from public.profiles
              where lower(handle) = v
                and (v_uid is null or id <> v_uid)) then
    return jsonb_build_object('available', false, 'problem', 'taken');
  end if;

  return jsonb_build_object('available', true, 'problem', null);
end $$;
revoke all on function public.handle_available(text) from public;
grant execute on function public.handle_available(text) to anon, authenticated;

-- ── rename ────────────────────────────────────────────────────────────────
-- Replaces the operator-only body 0031 left behind, and takes back the grant
-- it removed. The unique index is still what actually decides: two people can
-- pass the availability check in the same millisecond and exactly one insert
-- wins, which is why the collision is caught as an exception rather than
-- trusted to the SELECT above it.
create or replace function public.set_my_handle(p_handle text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_uid uuid; v text; v_problem text;
begin
  v_uid := public.df20_ensure_profile();
  if v_uid is null then raise exception 'DF20_SIGNIN_REQUIRED'; end if;

  v_problem := public.df20_handle_problem(p_handle);
  if v_problem is not null then
    raise exception 'DF20_HANDLE_%', upper(v_problem);
  end if;

  v := lower(btrim(p_handle));

  begin
    update public.profiles
       set handle = v, handle_chosen = true,
           handle_updated_at = now(), updated_at = now()
     where id = v_uid;
  exception when unique_violation then
    raise exception 'DF20_HANDLE_TAKEN';
  end;

  return jsonb_build_object('ok', true, 'handle', v);
end $$;
revoke all on function public.set_my_handle(text) from public;
grant execute on function public.set_my_handle(text) to authenticated;

comment on function public.set_my_handle(text) is
  'User-settable again since 0057. 0031 locked it when the handle was an '
  'assigned user ID; it is a display name now and nothing references it.';

-- ── the handle asked for at signup ────────────────────────────────────────
-- Supabase creates the auth user before this app ever sees a session, so the
-- chosen name rides in on raw_user_meta_data and is claimed here. If it is
-- taken by the time the row lands — two signups racing for one name — the
-- account still gets created with a generated handle and handle_chosen stays
-- false, which is what makes the profile page ask again. Signup must never
-- fail over a username.
create or replace function public.df20_on_auth_user_created()
returns trigger language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_want text; v_chosen boolean := false;
begin
  v_want := lower(btrim(coalesce(new.raw_user_meta_data->>'handle', '')));

  if public.df20_handle_problem(v_want) is not null
     or exists (select 1 from public.profiles where lower(handle) = v_want) then
    v_want := public.df20_gen_handle();
  else
    v_chosen := true;
  end if;

  insert into public.profiles (id, email, handle, handle_chosen, handle_updated_at)
  values (new.id, new.email, v_want, v_chosen,
          case when v_chosen then now() end)
  on conflict (id) do nothing;
  return new;
exception when others then
  -- unchanged from 0032: a profile that cannot be written must never block
  -- the signup itself. df20_ensure_profile() still backstops.
  return new;
end $$;

-- ── my_handle says whether the name was picked ────────────────────────────
-- Same signature, so df20_selfcheck's assertion of public.my_handle() holds.
create or replace function public.my_handle()
returns jsonb language sql stable security definer
set search_path = public, pg_temp as $$
  select jsonb_build_object(
           'handle', p.handle,
           'chosen', coalesce(p.handle_chosen, false))
    from public.profiles p where p.id = (select auth.uid())
$$;

-- ── the board ─────────────────────────────────────────────────────────────
-- WINS ARE df20_manual_winner AND NOTHING ELSE. The profile page has counted
-- them that way since 0017 — the audience vote's majority, with a tie
-- returning null and scoring for nobody. Recomputing "winner" here with a
-- second rule would let a player's own profile and the public board disagree
-- about the same draft, and there would be no way to say which was lying.
--
-- Only completed rooms, and only players attached to an account: an
-- anonymous seat has no identity to rank. That is most seats today, which is
-- the honest reason this board starts small.
create or replace function public.df20_leaderboard(p_sort text default 'wins',
                                                   p_limit int default 50)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_sort text; v_limit int; v_min_drafts constant int := 5;
begin
  v_sort  := coalesce(nullif(btrim(lower(p_sort)), ''), 'wins');
  if v_sort not in ('wins', 'drafts', 'rate') then v_sort := 'wins'; end if;
  v_limit := least(greatest(coalesce(p_limit, 50), 1), 100);

  return coalesce((
    select jsonb_agg(row_to_json(t) order by t.rank)
      from (
        select row_number() over (
                 order by
                   case when v_sort = 'drafts' then s.drafts
                        when v_sort = 'rate'
                             and s.drafts >= v_min_drafts then s.win_pct
                        when v_sort = 'rate' then -1
                        else s.wins end desc,
                   s.wins desc, s.drafts desc, s.handle asc
               )::int as rank,
               s.handle, s.display_name, s.drafts, s.wins, s.losses,
               s.undecided, s.win_pct, s.avg_leftover_cents
          from (
            select pr.handle,
                   nullif(btrim(coalesce(pr.display_name, '')), '') as display_name,
                   count(*)::int as drafts,
                   count(*) filter (where w.winner = w.me)::int as wins,
                   count(*) filter (where w.winner is not null
                                      and w.winner <> w.me)::int as losses,
                   count(*) filter (where w.winner is null)::int as undecided,
                   -- rate is over DECIDED drafts: a draft nobody voted on is
                   -- not a loss, and counting it as one would punish the
                   -- players whose audience never showed up
                   case when count(*) filter (where w.winner is not null) > 0
                        then round(100.0 * count(*) filter (where w.winner = w.me)
                                   / count(*) filter (where w.winner is not null), 1)
                        else 0 end as win_pct,
                   round(avg(w.leftover))::int as avg_leftover_cents
              from (
                select p.profile_id, p.id as me, p.bankroll_cents as leftover,
                       public.df20_manual_winner(r.id) as winner
                  from public.rooms r
                  join public.players p
                    on p.room_id = r.id and p.profile_id is not null
                 where r.status = 'complete'
              ) w
              join public.profiles pr on pr.id = w.profile_id
             where pr.handle is not null
             group by pr.handle, pr.display_name
          ) s
         where case when v_sort = 'rate' then s.drafts >= v_min_drafts else true end
         order by rank
         limit v_limit
      ) t
  ), '[]'::jsonb);
end $$;
revoke all on function public.df20_leaderboard(text, int) from public;
grant execute on function public.df20_leaderboard(text, int) to anon, authenticated;

comment on function public.df20_leaderboard(text, int) is
  'Public board. Returns handle, display name and counts only — never email, '
  'never a profile id, never a room code.';

-- ── the indexes the board leans on ────────────────────────────────────────
create index if not exists players_profile_idx on public.players(profile_id)
  where profile_id is not null;
create index if not exists rooms_status_idx on public.rooms(status);
create index if not exists votes_room_idx on public.votes(room_id);

-- ── selfcheck ─────────────────────────────────────────────────────────────
create or replace function public.df20_selfcheck_usernames()
returns text language plpgsql
set search_path = public, pg_temp as $$
declare r text;
begin
  foreach r in array array[
    'public.df20_handle_problem(text)',
    'public.handle_available(text)',
    'public.set_my_handle(text)',
    'public.df20_leaderboard(text,integer)'
  ] loop
    if to_regprocedure(r) is null then
      raise exception 'DF20_SELFCHECK: % is missing', r;
    end if;
  end loop;

  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='profiles'
                    and column_name='handle_chosen') then
    raise exception 'DF20_SELFCHECK: profiles.handle_chosen is missing';
  end if;

  -- 0031 removed this grant on purpose; 0057 takes it back on purpose. If it
  -- is missing again, someone re-applied 0031 over the top and every rename
  -- in the app is failing with a permission error.
  if not has_function_privilege('authenticated', 'public.set_my_handle(text)', 'execute') then
    raise exception 'DF20_SELFCHECK: authenticated cannot call set_my_handle — 0031 re-applied?';
  end if;

  if public.df20_handle_problem('ok_name1') is not null then
    raise exception 'DF20_SELFCHECK: a valid handle was rejected';
  end if;
  if public.df20_handle_problem('admin') is distinct from 'reserved'
     or public.df20_handle_problem('ab') is distinct from 'too_short'
     or public.df20_handle_problem('_lead') is distinct from 'edge'
     or public.df20_handle_problem('has space') is distinct from 'charset' then
    raise exception 'DF20_SELFCHECK: handle validation is not enforcing its rules';
  end if;

  return 'usernames + leaderboard ok';
end $$;
revoke all on function public.df20_selfcheck_usernames() from public;

select public.df20_selfcheck_usernames();
