-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0058 · usernames stay clean, and say so
--
-- An explicit name came back "Taken — try another", which was both untrue and
-- useless: the name is free, and the person is told to guess again with no
-- idea what was wrong. It gets its own reason code so the form can say what
-- it means.
--
-- THE LIST IS A TABLE, NOT A CONSTANT. Words are added by an operator with an
-- INSERT rather than a deploy, the list stays out of the repo, and it is
-- never shipped to a browser — lib/username.ts deliberately does NOT mirror
-- this rule, unlike every other one. The form still cannot submit a bad name
-- because it waits for handle_available() to answer.
--
-- TWO MATCH MODES, because one does not work. 'substring' is for words that
-- essentially never sit inside an innocent one. 'token' is for the short
-- ambiguous ones — matching those as substrings is the Scunthorpe problem,
-- and it blocks classic, assassin, analysis, peacock, compass and bassist.
-- Those match only as a whole word, with an underscore or digit as boundary.
--
-- The allow list runs FIRST, blanking known-innocent words out of the string
-- so their letters cannot go on to trigger a substring hit.
--
-- Re-runnable.
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists public.blocked_handle_words (
  word text primary key,
  mode text not null default 'substring' check (mode in ('substring','token')),
  added_at timestamptz not null default now()
);
alter table public.blocked_handle_words enable row level security;
revoke all on table public.blocked_handle_words from public, anon, authenticated;

create table if not exists public.allowed_handle_words (
  word text primary key,
  added_at timestamptz not null default now()
);
alter table public.allowed_handle_words enable row level security;
revoke all on table public.allowed_handle_words from public, anon, authenticated;

insert into public.allowed_handle_words (word) values
  ('scunthorpe'),('assassin'),('assess'),('assign'),('assist'),('asset'),
  ('class'),('classic'),('grass'),('brass'),('glass'),('compass'),('embassy'),
  ('massive'),('passion'),('password'),('bassist'),('analysis'),('analyst'),
  ('canal'),('banal'),('arsenal'),('shiitake'),('cockpit'),('cocktail'),
  ('peacock'),('hancock'),('titan'),('title'),('competition'),('sussex'),
  ('essex'),('middlesex'),('document'),('mishit'),('cumulative'),('circumstance'),
  ('accumulate'),('scrap'),('therapist'),('grape'),('grapes')
on conflict (word) do nothing;

insert into public.blocked_handle_words (word, mode) values
  ('fuck','substring'),('shit','substring'),('cunt','substring'),
  ('bitch','substring'),('whore','substring'),('slut','substring'),
  ('rape','substring'),('rapist','substring'),('molest','substring'),
  ('pedo','substring'),('paedo','substring'),('incest','substring'),
  ('bestiality','substring'),('nigger','substring'),('nigga','substring'),
  ('faggot','substring'),('retard','substring'),('wank','substring'),
  ('asshole','substring'),('arsehole','substring'),('dickhead','substring'),
  ('cocksuck','substring'),('motherfuck','substring'),('bollock','substring'),
  ('jizz','substring'),('handjob','substring'),('blowjob','substring'),
  ('ass','token'),('anal','token'),('cum','token'),('tit','token'),
  ('tits','token'),('crap','token'),('damn','token'),('cock','token'),
  ('dick','token'),('sex','token'),('pussy','token'),('penis','token'),
  ('vagina','token'),('boob','token'),('boobs','token'),('poop','token'),
  ('fag','token'),('hoe','token'),('milf','token'),('bastard','token')
on conflict (word) do nothing;

create or replace function public.df20_handle_explicit(p_handle text)
returns boolean language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_raw text; v_leet text; w text;
begin
  v_raw := lower(btrim(coalesce(p_handle, '')));
  if v_raw = '' then return false; end if;

  -- leet-fold, drop separators, collapse a letter repeated three or more
  -- times, so fuuuck and f_u_c_k reduce to the same string.
  -- from/to must be the SAME LENGTH or translate silently shifts the map:
  -- a stray space in the to-string made ! map to blank and shifted nothing
  -- else, which is the kind of bug that only shows up on one input.
  v_leet := translate(v_raw, '0134578@$!', 'oieastbasi');
  v_leet := regexp_replace(v_leet, '[^a-z]', '', 'g');
  v_leet := regexp_replace(v_leet, '(.)\1{2,}', '\1', 'g');

  for w in select word from public.allowed_handle_words loop
    v_leet := replace(v_leet, w, '.');
  end loop;

  if exists (select 1 from public.blocked_handle_words b
              where b.mode = 'substring' and position(b.word in v_leet) > 0)
  then return true; end if;

  -- A token word spelled with separators — a_s_s — survives the split into
  -- single letters, so test the folded string as a whole too. EXACT match
  -- only: as a substring these are the Scunthorpe problem.
  if exists (select 1 from public.blocked_handle_words b
              where b.mode = 'token' and b.word = v_leet)
  then return true; end if;

  if exists (
    select 1 from public.blocked_handle_words b
     where b.mode = 'token'
       and b.word = any (regexp_split_to_array(v_raw, '[^a-z]+'))
  ) then return true; end if;

  return false;
end $$;
revoke all on function public.df20_handle_explicit(text) from public;

-- Wired into the one validator everything already calls. No longer immutable:
-- it reads the word tables now. Every caller was stable or volatile already.
create or replace function public.df20_handle_problem(p_handle text)
returns text language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v text;
begin
  v := lower(btrim(coalesce(p_handle, '')));
  if length(v) = 0                then return 'required';   end if;
  if length(v) < 3                then return 'too_short';  end if;
  if length(v) > 20               then return 'too_long';   end if;
  if v !~ '^[a-z0-9_]+$'          then return 'charset';    end if;
  if v !~ '^[a-z0-9]'             then return 'edge';       end if;
  if v !~ '[a-z0-9]$'             then return 'edge';       end if;
  if v ~ '__'                     then return 'edge';       end if;
  if v = any (array[
      'admin','administrator','root','staff','mod','moderator','support','help',
      'system','official','draftfor20','draft420','df20','team','owner',
      'api','auth','login','signin','signup','logout','profile','settings',
      'billing','pricing','room','rooms','new','vote','votes','results','setup',
      'leaderboard','dev','obs','privacy','terms','about','contact','null',
      'undefined','anonymous','anon','you','everyone','host','guest'])
  then return 'reserved'; end if;
  if public.df20_handle_explicit(v) then return 'explicit'; end if;
  return null;
end $$;

create or replace function public.df20_selfcheck_usernames()
returns text language plpgsql
set search_path = public, pg_temp as $$
declare r text;
begin
  foreach r in array array[
    'public.df20_handle_problem(text)','public.handle_available(text)',
    'public.set_my_handle(text)','public.df20_handle_explicit(text)',
    'public.df20_leaderboard(text,integer)'
  ] loop
    if to_regprocedure(r) is null then
      raise exception 'DF20_SELFCHECK: % is missing', r; end if;
  end loop;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='profiles'
                    and column_name='handle_chosen') then
    raise exception 'DF20_SELFCHECK: profiles.handle_chosen is missing'; end if;
  if not has_function_privilege('authenticated','public.set_my_handle(text)','execute') then
    raise exception 'DF20_SELFCHECK: authenticated cannot call set_my_handle - 0031 re-applied?'; end if;
  if public.df20_handle_problem('ok_name1') is not null then
    raise exception 'DF20_SELFCHECK: a valid handle was rejected'; end if;
  if public.df20_handle_problem('admin') is distinct from 'reserved'
     or public.df20_handle_problem('ab') is distinct from 'too_short'
     or public.df20_handle_problem('_lead') is distinct from 'edge'
     or public.df20_handle_problem('has space') is distinct from 'charset' then
    raise exception 'DF20_SELFCHECK: handle validation is not enforcing its rules'; end if;
  -- plain, leet, padded and separator-split spellings
  if public.df20_handle_problem('fuck_this') is distinct from 'explicit'
     or public.df20_handle_problem('big_ass') is distinct from 'explicit'
     or public.df20_handle_problem('sh1t') is distinct from 'explicit'
     or public.df20_handle_problem('fuuuck') is distinct from 'explicit'
     or public.df20_handle_problem('a_s_s') is distinct from 'explicit' then
    raise exception 'DF20_SELFCHECK: the word filter is not catching'; end if;
  -- and NOT the innocent words that make a naive substring match unusable
  if public.df20_handle_problem('classic') is not null
     or public.df20_handle_problem('assassin') is not null
     or public.df20_handle_problem('analysis') is not null
     or public.df20_handle_problem('peacock') is not null
     or public.df20_handle_problem('bassist') is not null
     or public.df20_handle_problem('cocktail') is not null then
    raise exception 'DF20_SELFCHECK: the word filter is rejecting innocent names'; end if;
  return 'usernames + leaderboard ok';
end $$;
revoke all on function public.df20_selfcheck_usernames() from public;

select public.df20_selfcheck_usernames();
