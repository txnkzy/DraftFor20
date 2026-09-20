-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0063 · PG names, and a name that is already taken says so
--
-- TWO RULES, BOTH IN POSTGRES.
--
-- join_room is called straight from the browser (JoinClient.tsx), so a JS
-- profanity package in an API route would filter precisely nobody — the RPC
-- is reachable with curl and the anon key is public. Same reason every money
-- check lives down here. The word list is the Shutterstock/LDNOOBW list
-- (List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words), seeded as data so
-- it can be edited in the table editor without a deploy.
--
-- THE SCUNTHORPE PROBLEM IS HANDLED EXPLICITLY. Substring-matching short
-- terms blocks Cassandra, Scunthorpe, Hitchcock, Middlesex, Montenegro,
-- raccoon, among, analysis and canal. So each term carries whole_word:
--   whole_word = true   -> matches only as its own word  (ass, tit, sex, cunt)
--   whole_word = false  -> matches anywhere              (fuck -> fuckface)
-- 66 of the 385 terms are whole-word; the rest match as substrings, which is
-- what catches the compounds people actually try.
--
-- Evasion is normalised away first: leetspeak (4ss, fück -> no, sh1t, $hit),
-- and separators (f.u.c.k, f u c k, f-u-c-k) both collapse into the squashed
-- form before matching.
--
-- ⚠ OVERLAPS 0058_username_word_filter, WRITTEN IN PARALLEL. That migration
-- built blocked_handle_words + df20_handle_explicit() for profiles.handle,
-- with the same Scunthorpe reasoning and a different word list. This one's
-- trigger ALSO guards profiles.handle. Handles are therefore checked twice,
-- against two lists that will drift, and a word on one but not the other
-- produces a different error depending on which fires first.
--
-- Neither is wrong; having both is. They should converge on one list — this
-- one is seeded from LDNOOBW and covers display names, room titles and
-- handles; that one has an allow-list pass and a token/substring mode per
-- word, which is the better matching design. Whoever picks: keep 0058's
-- match modes and allow list, point them at df20_profanity, and drop the
-- handle branch from df20_guard_profile_name below.
--
-- Re-runnable.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── normalisation ─────────────────────────────────────────────────────────
-- Two forms, because the two match modes need different things:
--   words()  keeps separators as single spaces, so whole-word matching works
--   squash() removes them entirely, so "f u c k" and "f.u.c.k" both collapse
create or replace function public.df20_name_leet(p_in text)
returns text language sql immutable as $$
  select translate(lower(coalesce(p_in,'')),
                   '0134578@$!|+', 'oieastbasiit')
$$;

create or replace function public.df20_name_words(p_in text)
returns text language sql immutable as $$
  select btrim(regexp_replace(
           regexp_replace(public.df20_name_leet(p_in), '[^a-z0-9]+', ' ', 'g'),
           '\s+', ' ', 'g'))
$$;

create or replace function public.df20_name_squash(p_in text)
returns text language sql immutable as $$
  select regexp_replace(public.df20_name_leet(p_in), '[^a-z0-9]+', '', 'g')
$$;

-- ── the list ──────────────────────────────────────────────────────────────
create table if not exists public.df20_profanity (
  term        text primary key,
  term_words  text not null,
  term_squash text not null,
  whole_word  boolean not null default false
);
alter table public.df20_profanity enable row level security;
revoke all on public.df20_profanity from anon, authenticated;

create index if not exists df20_profanity_whole_idx
  on public.df20_profanity (whole_word);

insert into public.df20_profanity (term, term_words, term_squash, whole_word)
select t,
       public.df20_name_words(t),
       public.df20_name_squash(t),
       -- whole-word if it is on the Scunthorpe list above, or is three
       -- characters or fewer. NOT four: 'fuck', 'shit', 'slut', 'clit',
       -- 'jizz', 'twat' and 'wank' are all four long, and making them
       -- whole-word-only would let every compound through — 'fuckface'
       -- would sail past the filter. Four-letter terms that DO appear
       -- inside ordinary words are on the explicit list instead.
       t = any(array[
    '2g1c', 'anal', 'anus', 'ass', 'bbw', 'boob', 'boobs', 'busty', 'butt',
    'cock', 'cocks', 'coon', 'coons', 'cum', 'cunt', 'dick', 'dvda',
    'ecchi', 'fag', 'guro', 'horny', 'juggs', 'kike', 'milf', 'mong',
    'negro', 'nsfw', 'nude', 'orgy', 'paki', 'panty', 'pikey', 'poof',
    'poon', 'porn', 'pubes', 'quim', 'rape', 's&m', 'scat', 'semen', 'sex',
    'sexo', 'sexy', 'shota', 'smut', 'spic', 'suck', 'sucks', 'tit', 'tits',
    'tushy', 'twink', 'vulva', 'xx', 'yaoi'
       ]) or length(public.df20_name_squash(t)) <= 3
  from unnest(array[
    '2g1c', '2 girls 1 cup', 'acrotomophilia', 'alabama hot pocket',
    'alaskan pipeline', 'anal', 'anilingus', 'anus', 'apeshit', 'arsehole',
    'ass', 'asshole', 'assmunch', 'auto erotic', 'autoerotic', 'babeland',
    'baby batter', 'baby juice', 'ball gag', 'ball gravy', 'ball kicking',
    'ball licking', 'ball sack', 'ball sucking', 'bangbros', 'bangbus',
    'bareback', 'barely legal', 'barenaked', 'bastard', 'bastardo',
    'bastinado', 'bbw', 'bdsm', 'beaner', 'beaners', 'beaver cleaver',
    'beaver lips', 'beastiality', 'bestiality', 'big black', 'big breasts',
    'big knockers', 'big tits', 'bimbos', 'birdlock', 'bitch', 'bitches',
    'black cock', 'blonde action', 'blonde on blonde action', 'blowjob',
    'blow job', 'blow your load', 'blue waffle', 'blumpkin', 'bollocks',
    'bondage', 'boner', 'boob', 'boobs', 'booty call', 'brown showers',
    'brunette action', 'bukkake', 'bulldyke', 'bullet vibe', 'bullshit',
    'bung hole', 'bunghole', 'busty', 'butt', 'buttcheeks', 'butthole',
    'camel toe', 'camgirl', 'camslut', 'camwhore', 'carpet muncher',
    'carpetmuncher', 'chocolate rosebuds', 'cialis', 'circlejerk',
    'cleveland steamer', 'clit', 'clitoris', 'clover clamps', 'clusterfuck',
    'cock', 'cocks', 'coprolagnia', 'coprophilia', 'cornhole', 'coon',
    'coons', 'creampie', 'cum', 'cumming', 'cumshot', 'cumshots',
    'cunnilingus', 'cunt', 'darkie', 'date rape', 'daterape', 'deep throat',
    'deepthroat', 'dendrophilia', 'dick', 'dildo', 'dingleberry',
    'dingleberries', 'dirty pillows', 'dirty sanchez', 'doggie style',
    'doggiestyle', 'doggy style', 'doggystyle', 'dog style', 'dolcett',
    'domination', 'dominatrix', 'dommes', 'donkey punch', 'double dong',
    'double penetration', 'dp action', 'dry hump', 'dvda', 'eat my ass',
    'ecchi', 'ejaculation', 'erotic', 'erotism', 'escort', 'eunuch', 'fag',
    'faggot', 'fecal', 'felch', 'fellatio', 'feltch', 'female squirting',
    'femdom', 'figging', 'fingerbang', 'fingering', 'fisting',
    'foot fetish', 'footjob', 'frotting', 'fuck', 'fuck buttons', 'fuckin',
    'fucking', 'fucktards', 'fudge packer', 'fudgepacker', 'futanari',
    'gangbang', 'gang bang', 'gay sex', 'genitals', 'giant cock', 'girl on',
    'girl on top', 'girls gone wild', 'goatcx', 'goatse', 'god damn',
    'gokkun', 'golden shower', 'goodpoop', 'goo girl', 'goregasm', 'grope',
    'group sex', 'g-spot', 'guro', 'hand job', 'handjob', 'hard core',
    'hardcore', 'hentai', 'homoerotic', 'honkey', 'hooker', 'horny',
    'hot carl', 'hot chick', 'how to kill', 'how to murder', 'huge fat',
    'humping', 'incest', 'intercourse', 'jack off', 'jail bait', 'jailbait',
    'jelly donut', 'jerk off', 'jigaboo', 'jiggaboo', 'jiggerboo', 'jizz',
    'juggs', 'kike', 'kinbaku', 'kinkster', 'kinky', 'knobbing',
    'leather restraint', 'leather straight jacket', 'lemon party',
    'livesex', 'lolita', 'lovemaking', 'make me come', 'male squirting',
    'masturbate', 'masturbating', 'masturbation', 'menage a trois', 'milf',
    'missionary position', 'mong', 'motherfucker', 'mound of venus',
    'mr hands', 'muff diver', 'muffdiving', 'nambla', 'nawashi', 'negro',
    'neonazi', 'nigga', 'nigger', 'nig nog', 'nimphomania', 'nipple',
    'nipples', 'nsfw', 'nsfw images', 'nude', 'nudity', 'nutten', 'nympho',
    'nymphomania', 'octopussy', 'omorashi', 'one cup two girls',
    'one guy one jar', 'orgasm', 'orgy', 'paedophile', 'paki', 'panties',
    'panty', 'pedobear', 'pedophile', 'pegging', 'penis', 'phone sex',
    'piece of shit', 'pikey', 'pissing', 'piss pig', 'pisspig', 'playboy',
    'pleasure chest', 'pole smoker', 'ponyplay', 'poof', 'poon', 'poontang',
    'punany', 'poop chute', 'poopchute', 'porn', 'porno', 'pornography',
    'prince albert piercing', 'pthc', 'pubes', 'pussy', 'queaf', 'queef',
    'quim', 'raghead', 'raging boner', 'rape', 'raping', 'rapist', 'rectum',
    'reverse cowgirl', 'rimjob', 'rimming', 'rosy palm',
    'rosy palm and her 5 sisters', 'rusty trombone', 'sadism', 'santorum',
    'scat', 'schlong', 'scissoring', 'semen', 'sex', 'sexcam', 'sexo',
    'sexy', 'sexual', 'sexually', 'sexuality', 'shaved beaver',
    'shaved pussy', 'shemale', 'shibari', 'shit', 'shitblimp', 'shitty',
    'shota', 'shrimping', 'skeet', 'slanteye', 'slut', 's&m', 'smut',
    'snatch', 'snowballing', 'sodomize', 'sodomy', 'spastic', 'spic',
    'splooge', 'splooge moose', 'spooge', 'spread legs', 'spunk',
    'strap on', 'strapon', 'strappado', 'strip club', 'style doggy', 'suck',
    'sucks', 'suicide girls', 'sultry women', 'swastika', 'swinger',
    'tainted love', 'taste my', 'tea bagging', 'threesome', 'throating',
    'thumbzilla', 'tied up', 'tight white', 'tit', 'tits', 'titties',
    'titty', 'tongue in a', 'topless', 'tosser', 'towelhead', 'tranny',
    'tribadism', 'tub girl', 'tubgirl', 'tushy', 'twat', 'twink', 'twinkie',
    'two girls one cup', 'undressing', 'upskirt', 'urethra play',
    'urophilia', 'vagina', 'venus mound', 'viagra', 'vibrator',
    'violet wand', 'vorarephilia', 'voyeur', 'voyeurweb', 'voyuer', 'vulva',
    'wank', 'wetback', 'wet dream', 'white power', 'whore', 'worldsex',
    'wrapping men', 'wrinkled starfish', 'xx', 'xxx', 'yaoi',
    'yellow showers', 'yiffy', 'zoophilia'
  ]) as t
on conflict (term) do update
  set term_words  = excluded.term_words,
      term_squash = excluded.term_squash,
      whole_word  = excluded.whole_word;

-- ── the check ─────────────────────────────────────────────────────────────
-- SECURITY DEFINER: df20_profanity is revoked from anon and authenticated
-- (it is a moderation list, not public data). Without definer rights this
-- works inside join_room — which is itself definer — and dies with
-- "permission denied for table df20_profanity" the moment the join form
-- calls it directly. It reads one lookup table and returns a boolean.
create or replace function public.df20_has_bad_word(p_in text)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.df20_profanity p
     where case when p.whole_word
                then ' ' || public.df20_name_words(p_in) || ' '
                       like '% ' || p.term_words || ' %'
                else public.df20_name_squash(p_in)
                       like '%' || p.term_squash || '%'
           end
  )
  -- the list's one emoji entry, plus its obvious sibling. Postgres regex has
  -- no \U escape, so these are the literal characters.
  or coalesce(p_in,'') like '%🖕%'
  or coalesce(p_in,'') like '%💩%'
$$;
grant execute on function public.df20_has_bad_word(text) to anon, authenticated;

-- ── enforcement ───────────────────────────────────────────────────────────
-- join_room gains two checks. Restated in full rather than patched, because
-- it is the only way to be sure the seat-assignment logic from 0017 is intact
-- (the "first FREE seat, not seat 2" fix); ONLY the two blocks marked NEW
-- below differ from that version.
create or replace function public.join_room(p_code text, p_display_name text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_pl public.players; v_n int; v_seat int;
        v_host boolean; v_uid uuid;
begin
  select * into v_room from public.rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'DF20_NO_ROOM'; end if;
  if v_room.status <> 'lobby' then raise exception 'DF20_ALREADY_STARTED'; end if;

  p_display_name := public.df20_clean_text(p_display_name, 24);
  if length(p_display_name) = 0 then raise exception 'DF20_BAD_NAME'; end if;

  -- NEW: keep it PG
  if public.df20_has_bad_word(p_display_name) then
    raise exception 'DF20_BAD_WORD';
  end if;

  -- NEW: two people called "Mason" in one room makes the board unreadable and
  -- the results card a lie. Compared on the squashed form, so "Mason" and
  -- "m a s o n" collide the way a person would expect them to.
  if exists (select 1 from public.players
              where room_id = v_room.id
                and public.df20_name_squash(display_name)
                    = public.df20_name_squash(p_display_name)) then
    raise exception 'DF20_NAME_TAKEN';
  end if;

  select count(*) into v_n from public.players where room_id = v_room.id;
  if v_n >= 2 then raise exception 'DF20_ROOM_FULL'; end if;

  select min(s) into v_seat from generate_series(1,2) s
   where not exists (select 1 from public.players
                      where room_id = v_room.id and seat = s);

  v_host := not exists (select 1 from public.players
                         where room_id = v_room.id and is_host);

  begin
    v_uid := public.df20_ensure_profile();
  exception when others then v_uid := null;
  end;

  insert into public.players (room_id, seat, display_name, bankroll_cents, is_host, profile_id)
  values (v_room.id, v_seat, p_display_name, v_room.starting_bankroll_cents, v_host, v_uid)
  returning * into v_pl;

  perform public.df20_touch(v_room.id);
  perform public.df20_broadcast(v_room.id);
  return jsonb_build_object('room_id', v_room.id, 'code', v_room.code,
                            'player_id', v_pl.id, 'session_token', v_pl.session_token,
                            'seat', v_pl.seat);
end $$;
grant execute on function public.join_room(text, text) to anon, authenticated;

-- ── a name the joiner can check BEFORE they commit ────────────────────────
-- The room code is already enough to read public state, so this leaks
-- nothing new: it answers the two questions the join form needs and nothing
-- else. Returns ok=false with a reason rather than raising, because this is
-- called while the user is still typing.
-- SECURITY DEFINER for the same reason: rooms and players are deny-all. It
-- returns a boolean and a reason code, never a row, and the caller must
-- already hold the room code — which get_room_state already trades for both
-- players' display names.
create or replace function public.check_display_name(p_code text, p_name text)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_room public.rooms; v_clean text;
begin
  v_clean := public.df20_clean_text(p_name, 24);
  if length(v_clean) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'DF20_BAD_NAME');
  end if;
  if public.df20_has_bad_word(v_clean) then
    return jsonb_build_object('ok', false, 'reason', 'DF20_BAD_WORD');
  end if;

  -- no room supplied: name-only validity, used by the create-a-room form
  if coalesce(btrim(p_code), '') = '' then
    return jsonb_build_object('ok', true, 'name', v_clean);
  end if;

  select * into v_room from public.rooms where code = upper(btrim(p_code));
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'DF20_NO_ROOM');
  end if;
  if exists (select 1 from public.players
              where room_id = v_room.id
                and public.df20_name_squash(display_name)
                    = public.df20_name_squash(v_clean)) then
    return jsonb_build_object('ok', false, 'reason', 'DF20_NAME_TAKEN');
  end if;
  return jsonb_build_object('ok', true, 'name', v_clean);
end $$;
grant execute on function public.check_display_name(text, text) to anon, authenticated;

-- ── every other way a name reaches the database ───────────────────────────
-- create_room (host name + room title), save_profile (display name) and any
-- future writer all land in one of these two tables. A trigger catches them
-- without restating create_room, which now takes fourteen arguments and is
-- exactly the kind of function that breaks when it is retyped — 0041 rebuilt
-- it and left df20_selfcheck() failing on a healthy database for days.
create or replace function public.df20_guard_player_name()
returns trigger language plpgsql
set search_path = public, pg_temp as $$
begin
  if public.df20_has_bad_word(new.display_name) then
    raise exception 'DF20_BAD_WORD';
  end if;
  return new;
end $$;

drop trigger if exists df20_players_clean_name on public.players;
create trigger df20_players_clean_name
  before insert or update of display_name on public.players
  for each row execute function public.df20_guard_player_name();

create or replace function public.df20_guard_room_text()
returns trigger language plpgsql
set search_path = public, pg_temp as $$
begin
  if public.df20_has_bad_word(new.title) then
    raise exception 'DF20_BAD_WORD';
  end if;
  return new;
end $$;

drop trigger if exists df20_rooms_clean_title on public.rooms;
create trigger df20_rooms_clean_title
  before insert or update of title on public.rooms
  for each row execute function public.df20_guard_room_text();

create or replace function public.df20_guard_profile_name()
returns trigger language plpgsql
set search_path = public, pg_temp as $$
begin
  -- display_name is nullable here; a null name is not a dirty one
  if new.display_name is not null
     and public.df20_has_bad_word(new.display_name) then
    raise exception 'DF20_BAD_WORD';
  end if;

  -- 0057 made the handle something people CHOOSE and put it on a public
  -- leaderboard, so it needs the same filter. Only chosen handles are
  -- checked: df20_gen_handle draws random characters, and on the
  -- astronomically unlikely day it emits a matching run, breaking signup is
  -- a far worse outcome than one ugly auto-handle nobody picked. A person
  -- who then chooses a handle is checked like everyone else.
  if new.handle_chosen
     and new.handle is not null
     and public.df20_has_bad_word(new.handle) then
    raise exception 'DF20_BAD_WORD';
  end if;

  return new;
end $$;

drop trigger if exists df20_profiles_clean_name on public.profiles;
create trigger df20_profiles_clean_name
  before insert or update of display_name, handle, handle_chosen
  on public.profiles
  for each row execute function public.df20_guard_profile_name();

-- ── the assertions ────────────────────────────────────────────────────────
-- Both halves, the way v6_premium.sql asserts the watermark: the words that
-- must be caught, AND the ordinary names that must NOT be. The second list is
-- the one that matters — a filter nobody can put their real name past is a
-- worse bug than a rude room title.
do $$
declare v_bad text[] := '{}'; w text;
begin
  foreach w in array array[
    'fuck','FUCK','F u c k','f.u.c.k','sh1t','$hit','4ss','fuckface',
    'bitch','wanker','MotherFucker','n1gger','cunt','pussy'
  ] loop
    if not public.df20_has_bad_word(w) then
      v_bad := v_bad || ('should be blocked but is not: ' || w);
    end if;
  end loop;

  foreach w in array array[
    'Cassandra','Scunthorpe','Hitchcock','Middlesex','Montenegro','raccoon',
    'among','analysis','canal','Dickens','Titus','classic','Butters','Bass',
    'Mason','Logan','shiitake','Essex','Sussex','cocktail','peacock','grape',
    'scrape','spoon','harpoon','button','butter','accumulate','circumstance',
    'Uranus','mongoose','despicable','scatter','proof','Van Dyke','Wang'
  ] loop
    if public.df20_has_bad_word(w) then
      v_bad := v_bad || ('ordinary name wrongly blocked: ' || w);
    end if;
  end loop;

  if coalesce(array_length(v_bad,1),0) > 0 then
    raise exception E'DF20_PROFANITY_CHECK_FAILED\n  %',
      array_to_string(v_bad, E'\n  ');
  end if;
  raise notice 'profanity filter ok - % terms, Scunthorpe safe',
    (select count(*) from public.df20_profanity);
end $$;
