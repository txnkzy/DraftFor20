-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0014 · six more free categories, and the free-shelf listing
--
-- Real, factual lists of public things. Curated for PLAY, not reference: no
-- list claims to be exhaustive, they claim to be arguable.
-- ═══════════════════════════════════════════════════════════════════════════

-- Disney Animated Movies · 52 items
select public.df20_seed_category('Disney Animated Movies', string_to_array($it$Snow White and the Seven Dwarfs
Pinocchio
Fantasia
Dumbo
Bambi
Cinderella
Alice in Wonderland
Peter Pan
Lady and the Tramp
Sleeping Beauty
One Hundred and One Dalmatians
The Sword in the Stone
The Jungle Book
The Aristocats
Robin Hood
The Rescuers
The Fox and the Hound
The Black Cauldron
The Great Mouse Detective
Oliver and Company
The Little Mermaid
Beauty and the Beast
Aladdin
The Lion King
Pocahontas
The Hunchback of Notre Dame
Hercules
Mulan
Tarzan
Dinosaur
The Emperor's New Groove
Atlantis: The Lost Empire
Lilo and Stitch
Treasure Planet
Brother Bear
Home on the Range
Chicken Little
Meet the Robinsons
Bolt
The Princess and the Frog
Tangled
Winnie the Pooh
Wreck-It Ralph
Frozen
Big Hero 6
Zootopia
Moana
Ralph Breaks the Internet
Frozen II
Raya and the Last Dragon
Encanto
Wish$it$, E'\n'));
select public.df20_add_alias('Disney Animated Movies', array['disney movies','disney films','disney','animated disney movies']);

-- TV Sitcoms · 52 items
select public.df20_seed_category('TV Sitcoms', string_to_array($it$Friends
Seinfeld
The Office
Parks and Recreation
30 Rock
Cheers
Frasier
I Love Lucy
The Simpsons
Family Guy
South Park
King of the Hill
Arrested Development
Community
Brooklyn Nine-Nine
How I Met Your Mother
The Big Bang Theory
Modern Family
Scrubs
It's Always Sunny in Philadelphia
Curb Your Enthusiasm
Malcolm in the Middle
Everybody Loves Raymond
Will and Grace
The Golden Girls
Full House
Family Matters
The Fresh Prince of Bel-Air
Boy Meets World
Home Improvement
Roseanne
Married with Children
Three's Company
Happy Days
Taxi
Night Court
WKRP in Cincinnati
The Mary Tyler Moore Show
All in the Family
Sanford and Son
Good Times
The Jeffersons
Perfect Strangers
Saved by the Bell
Spin City
NewsRadio
The Good Place
Superstore
Veep
Ted Lasso
Abbott Elementary
Schitt's Creek$it$, E'\n'));
select public.df20_add_alias('TV Sitcoms', array['sitcoms','tv comedies','comedy shows','tv shows']);

-- Movie Villains · 52 items
select public.df20_seed_category('Movie Villains', string_to_array($it$Darth Vader
Hannibal Lecter
Norman Bates
The Joker
Lord Voldemort
Sauron
Freddy Krueger
Michael Myers
Jason Voorhees
Hans Gruber
Nurse Ratched
Anton Chigurh
The Terminator
Agent Smith
Scar
Ursula
Maleficent
Cruella de Vil
Jafar
Gaston
Hades
Captain Hook
The Wicked Witch of the West
Bane
Two-Face
The Penguin
Green Goblin
Doctor Octopus
Thanos
Loki
Magneto
Emperor Palpatine
Kylo Ren
Saruman
Amon Goeth
Colonel Kurtz
Annie Wilkes
Patrick Bateman
Keyser Soze
Bill the Butcher
Immortan Joe
Pennywise
Chucky
Ghostface
Leatherface
HAL 9000
Lord Farquaad
Syndrome
Randall Boggs
Shere Khan
Regina George
Nurse Mildred$it$, E'\n'));
select public.df20_add_alias('Movie Villains', array['villains','film villains','bad guys','movie bad guys']);

-- 2000s Songs · 56 items
select public.df20_seed_category('2000s Songs', string_to_array($it$Hey Ya!
Crazy in Love
Toxic
Since U Been Gone
Mr. Brightside
Seven Nation Army
Lose Yourself
In Da Club
Hot in Herre
Get the Party Started
Complicated
Beautiful Day
Clocks
Yellow
Boulevard of Broken Dreams
American Idiot
Bring Me to Life
Numb
In the End
Chop Suey!
Last Resort
The Middle
All the Small Things
Sk8er Boi
Fallin'
A Thousand Miles
Drops of Jupiter
How You Remind Me
Kryptonite
Bye Bye Bye
Oops!... I Did It Again
Survivor
Independent Women
Dilemma
Yeah!
Gold Digger
Stronger
Umbrella
Single Ladies
Poker Face
I Gotta Feeling
Boom Boom Pow
Party in the U.S.A.
Use Somebody
Viva la Vida
Chasing Cars
Hips Don't Lie
SexyBack
Promiscuous
Rehab
Take Me Out
Somebody Told Me
Float On
Maps
Feel Good Inc.
Paper Planes$it$, E'\n'));
select public.df20_add_alias('2000s Songs', array['2000s music','00s songs','2000s hits','noughties songs']);

-- 90s Songs · 55 items
select public.df20_seed_category('90s Songs', string_to_array($it$Smells Like Teen Spirit
Wonderwall
Creep
Losing My Religion
Black Hole Sun
Under the Bridge
Give It Away
Jeremy
Alive
Basket Case
When I Come Around
Longview
Come As You Are
Lithium
Heart-Shaped Box
No Rain
Bittersweet Symphony
Song 2
Common People
Live Forever
Don't Look Back in Anger
Torn
Zombie
Linger
Iris
One Headlight
Semi-Charmed Life
Everybody Hurts
Man in the Box
Would?
Interstate Love Song
Plush
1979
Today
Bullet with Butterfly Wings
Loser
Where It's At
Sabotage
Intergalactic
Killing in the Name
Bulls on Parade
I Will Always Love You
Vogue
...Baby One More Time
Wannabe
No Scrubs
Waterfalls
Gangsta's Paradise
California Love
Juicy
Big Poppa
Hypnotize
Jump Around
Groove Is in the Heart
Believe$it$, E'\n'));
select public.df20_add_alias('90s Songs', array['90s music','1990s songs','90s hits','nineties songs']);

-- Halloween Candy · 50 items
select public.df20_seed_category('Halloween Candy', string_to_array($it$Reese's Peanut Butter Cups
Snickers
Kit Kat
Twix
Milky Way
3 Musketeers
Butterfinger
Baby Ruth
Almond Joy
Mounds
Hershey's Milk Chocolate
Hershey's Kisses
M&M's
Peanut M&M's
Skittles
Starburst
Sour Patch Kids
Swedish Fish
Nerds
Laffy Taffy
Airheads
Jolly Rancher
Tootsie Roll
Tootsie Pops
Blow Pops
Dum Dums
Smarties
Sweet Tarts
Pixy Stix
Fun Dip
Candy Corn
Mellowcreme Pumpkins
Milk Duds
Whoppers
Junior Mints
Raisinets
Whatchamacallit
100 Grand
Take 5
Payday
Nestle Crunch
Rolo
York Peppermint Pattie
Werther's Original
Now and Later
Mike and Ike
Hot Tamales
Good and Plenty
Bit-O-Honey
Charleston Chew$it$, E'\n'));
select public.df20_add_alias('Halloween Candy', array['halloween sweets','trick or treat candy','halloween treats']);

-- ── the free shelf, for the picker and the Random button ──────────────────
-- Names and counts only. Items never cross this boundary, same as every other
-- read path in the app.
create or replace function public.list_free_categories()
returns jsonb language sql stable security definer
set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(x order by x->>'name'), '[]'::jsonb)
    from (
      select jsonb_build_object(
               'id', l.id,
               'name', l.name,
               'item_count', (select count(*) from public.category_library_items i
                               where i.library_id = l.id)) as x
        from public.category_library l
    ) s
   where (x->>'item_count')::int >= 20;
$$;
grant execute on function public.list_free_categories() to anon, authenticated;

do $$
declare v_c int; v_i int;
begin
  select count(*) into v_c from public.category_library;
  select count(*) into v_i from public.category_library_items;
  raise notice 'library now holds % categories and % items', v_c, v_i;
end $$;