-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0066 · one word filter, not two
--
-- 0058 and 0063 were written in parallel and both ended up guarding
-- profiles.handle: 0058 through df20_handle_explicit(), 0063 through the
-- df20_guard_profile_name trigger. Two lists, two matching strategies, and a
-- word on one but not the other gave a different error depending on which
-- fired first. This converges them.
--
-- 0058'S MATCHER WINS, and it is not close. Three things it does that 0063
-- did not:
--   * the ALLOW LIST RUNS FIRST, blanking innocent words out of the string
--     before matching, so 'scunthorpe' is gone before 'cunt' can see it.
--     0063 leaned entirely on per-term whole-word flags, which is the same
--     idea done later and less well.
--   * REPEAT COLLAPSING — 'fuuuck' folds to 'fuck'. 0063 missed this
--     completely and would have passed it.
--   * a SEPARATOR-SPLIT token pass, so 'a_s_s' is caught.
--
-- 0063'S LIST AND COVERAGE WIN. 382 terms from the Shutterstock/LDNOOBW list
-- against 0058's hand-written 46, and triggers on players.display_name and
-- rooms.title rather than handles alone. A filter that only guards the
-- username on a leaderboard leaves the name printed on the results card.
--
-- SO: 0058's tables and algorithm become the one source of truth, generalised
-- from handles to any text; 0063's terms are folded into them and its
-- df20_profanity table is dropped; 0063's trigger keeps its reach but stops
-- checking handles, because df20_handle_problem already does.
--
-- TERMS ARE STORED PRE-FOLDED. The matcher compares against a leet-folded,
-- letter-only, repeat-collapsed string, so a term stored raw can never match.
-- '2 girls 1 cup' is stored as 'girlscup'; anything folding shorter than
-- three characters is dropped rather than stored as a trap.
--
-- Re-runnable.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── the matcher, generalised ──────────────────────────────────────────────
-- Byte for byte 0058's df20_handle_explicit, with one change: it takes any
-- text. Handles are [a-z0-9_]; display names carry spaces, punctuation and
-- unicode. Folding already strips all of that, and the token pass splits on
-- any non-letter, so nothing about the algorithm needed to change.
create or replace function public.df20_explicit_text(p_text text)
returns boolean language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_raw text; v_leet text; w text;
begin
  v_raw := lower(btrim(coalesce(p_text, '')));
  if v_raw = '' then return false; end if;

  -- from/to must be the SAME LENGTH or translate silently shifts the map
  v_leet := translate(v_raw, '0134578@$!', 'oieastbasi');
  v_leet := regexp_replace(v_leet, '[^a-z]', '', 'g');
  v_leet := regexp_replace(v_leet, '(.)\1{2,}', '\1', 'g');

  for w in select word from public.allowed_handle_words loop
    v_leet := replace(v_leet, w, '.');
  end loop;

  if exists (select 1 from public.blocked_handle_words b
              where b.mode = 'substring' and position(b.word in v_leet) > 0)
  then return true; end if;

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
revoke all on function public.df20_explicit_text(text) from public;
grant execute on function public.df20_explicit_text(text) to anon, authenticated;

-- the handle check becomes a thin call, so the two can never diverge again
create or replace function public.df20_handle_explicit(p_handle text)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select public.df20_explicit_text(p_handle)
$$;
revoke all on function public.df20_handle_explicit(text) from public;

-- df20_has_bad_word keeps its name and its callers (three triggers and
-- check_display_name) and loses its own list.
create or replace function public.df20_has_bad_word(p_in text)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select public.df20_explicit_text(p_in)
      or coalesce(p_in,'') like '%🖕%'
      or coalesce(p_in,'') like '%💩%'
$$;
grant execute on function public.df20_has_bad_word(text) to anon, authenticated;

-- ── 0063's list, folded into 0058's table ─────────────────────────────────
-- Folded IN SQL from df20_profanity rather than pasted as a literal: the
-- transformation is the matcher's own, so a copied list could drift from it
-- and this cannot. 'token' where 0063 said whole_word — the two flags mean
-- the same thing — plus anything folding to three characters or fewer, which
-- is too short to substring-match safely. Terms folding shorter are dropped
-- rather than stored as a trap that can never match.
--
-- Runs BEFORE the drop below, obviously.
insert into public.blocked_handle_words (word, mode)
select f.w,
       case when p.whole_word or length(f.w) <= 3 then 'token' else 'substring' end
  from public.df20_profanity p,
       lateral (select regexp_replace(
                  regexp_replace(
                    translate(lower(p.term), '0134578@$!', 'oieastbasi'),
                    '[^a-z]', '', 'g'),
                  '(.)\1{2,}', '\1', 'g') as w) f
 where length(f.w) >= 3
on conflict (word) do nothing;

-- Widen the allow list with the false positives 0063's own assertions
-- covered, since they now have to survive a different matcher.
insert into public.allowed_handle_words (word) values
  ('montenegro'),('raccoon'),('among'),('mongoose'),('mongolia'),
  ('harpoon'),('spoon'),('lampoon'),('tycoon'),('cocoon'),
  ('scatter'),('scattered'),('despicable'),('suspicion'),('spice'),
  ('uranus'),('manuscript'),('butter'),('button'),('buttress'),
  ('dickens'),('dickinson'),('hitchcock'),('shuttlecock'),
  ('cassandra'),('kassandra'),('vandyke'),('wang'),('proof'),
  ('scrape'),('drape'),('therapeutic'),('titus'),('titanic'),
  ('constitution'),('substitute'),('nudge'),('denude'),('prudence')
on conflict (word) do nothing;

-- ── the trigger stops double-guarding handles ─────────────────────────────
-- df20_handle_problem() already returns 'explicit' for a bad handle, which is
-- the error the username form is built to render. The trigger firing as well
-- produced DF20_BAD_WORD from a different list — two answers to one question.
create or replace function public.df20_guard_profile_name()
returns trigger language plpgsql
set search_path = public, pg_temp as $$
begin
  if new.display_name is not null
     and public.df20_has_bad_word(new.display_name) then
    raise exception 'DF20_BAD_WORD';
  end if;
  -- handles are NOT checked here any more: set_my_handle -> handle_available
  -- -> df20_handle_problem() owns that, and gives a better error doing it.
  return new;
end $$;

drop trigger if exists df20_profiles_clean_name on public.profiles;
create trigger df20_profiles_clean_name
  before insert or update of display_name on public.profiles
  for each row execute function public.df20_guard_profile_name();

-- ── the old list goes ─────────────────────────────────────────────────────
-- Nothing reads it once df20_has_bad_word delegates. Leaving it would be a
-- second list that looks authoritative and is not — which is the bug.
drop table if exists public.df20_profanity;
drop function if exists public.df20_name_words(text);
drop function if exists public.df20_name_squash(text);
drop function if exists public.df20_name_leet(text);

-- ── both directions, asserted ─────────────────────────────────────────────
do $$
declare v_bad text[] := '{}'; w text;
begin
  foreach w in array array[
    'fuck','FUCK','f.u.c.k','f u c k','fuuuck','a_s_s','sh1t','$hit','4ss',
    'fuckface','motherfucker','bitch','wanker','n1gger','cunt','big_ass',
    'BigT1ts','a55hole'
  ] loop
    if not public.df20_has_bad_word(w) then
      v_bad := v_bad || ('should be blocked: ' || w); end if;
  end loop;

  foreach w in array array[
    'Cassandra','Scunthorpe','Hitchcock','Middlesex','Montenegro','raccoon',
    'among','analysis','canal','Dickens','Titus','classic','assassin',
    'peacock','bassist','cocktail','shiitake','Essex','Sussex','grape',
    'scrape','spoon','harpoon','button','butter','accumulate','circumstance',
    'Uranus','mongoose','despicable','scatter','proof','Wang','Mason','Logan',
    'ok_name1','The House'
  ] loop
    if public.df20_has_bad_word(w) then
      v_bad := v_bad || ('ordinary name wrongly blocked: ' || w); end if;
  end loop;

  -- the two entry points must now agree, which was the whole point
  if public.df20_handle_problem('fuck_this') is distinct from 'explicit'
    then v_bad := v_bad || 'handle validator disagrees with the trigger'; end if;
  if public.df20_handle_problem('classic') is not null
    then v_bad := v_bad || 'handle validator rejects an innocent name'; end if;

  if coalesce(array_length(v_bad,1),0) > 0 then
    raise exception E'DF20_WORD_FILTER_FAILED\n  %', array_to_string(v_bad, E'\n  ');
  end if;
  raise notice 'one word filter: % terms, % allowed, both entry points agree',
    (select count(*) from public.blocked_handle_words),
    (select count(*) from public.allowed_handle_words);
end $$;
