-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0011 · shared library seed
--
-- Real, factual lists of public things. Curated for PLAY, not for reference:
-- they are chosen to be recognisable and arguable, and none of them claims to
-- be exhaustive. A draft only needs enough good options that passing on one
-- hurts.
--
-- Edit freely. Re-running is safe; each category upserts by normalised name.
-- ═══════════════════════════════════════════════════════════════════════════

-- the loader
create or replace function public.df20_seed_category(p_name text, p_items text[])
returns int language plpgsql security definer
set search_path = public, pg_temp as $fn$
declare v_id uuid; s text; v_clean text; v_n int;
begin
  insert into public.category_library (name, name_norm)
  values (p_name, public.df20_norm_category(p_name))
  on conflict (name_norm) do update set name = excluded.name
  returning id into v_id;

  foreach s in array p_items loop
    v_clean := public.df20_clean_text(s, 60);
    if length(v_clean) >= 1 then
      insert into public.category_library_items (library_id, name)
      values (v_id, v_clean) on conflict do nothing;
    end if;
  end loop;

  select count(*) into v_n from public.category_library_items where library_id = v_id;
  return v_n;
end $fn$;
revoke all on function public.df20_seed_category(text, text[]) from anon, authenticated;

-- Football Draft · 268 items
-- Seeded explicitly rather than relying on the nfl_players migration in
-- 0009: if that table was already dropped by an earlier partial run, the
-- built-in pool would otherwise be gone for good and every default room
-- would fail with DF20_POOL_TOO_SMALL.
select public.df20_seed_category('Football Draft', string_to_array($ff$Patrick Mahomes
Josh Allen
Lamar Jackson
Joe Burrow
Jalen Hurts
Justin Herbert
C.J. Stroud
Jayden Daniels
Caleb Williams
Bo Nix
Dak Prescott
Tua Tagovailoa
Trevor Lawrence
Kyler Murray
Brock Purdy
Jared Goff
Matthew Stafford
Baker Mayfield
Geno Smith
Kirk Cousins
Aaron Rodgers
Russell Wilson
Derek Carr
Sam Darnold
Anthony Richardson
Will Levis
Drake Maye
Michael Penix Jr.
J.J. McCarthy
Bryce Young
Daniel Jones
Justin Fields
Gardner Minshew
Jacoby Brissett
Mac Jones
Aidan O'Connell
Jimmy Garoppolo
Andy Dalton
Cooper Rush
Malik Willis
Christian McCaffrey
Saquon Barkley
Bijan Robinson
Jahmyr Gibbs
Jonathan Taylor
Derrick Henry
Josh Jacobs
Kyren Williams
Breece Hall
De'Von Achane
Kenneth Walker III
Rachaad White
Travis Etienne Jr.
James Cook
Alvin Kamara
Joe Mixon
Aaron Jones
Najee Harris
David Montgomery
Isiah Pacheco
Tony Pollard
Rhamondre Stevenson
Zamir White
Javonte Williams
D'Andre Swift
Chuba Hubbard
Brian Robinson Jr.
Zack Moss
Tyjae Spears
Jaylen Warren
Austin Ekeler
Nick Chubb
J.K. Dobbins
Gus Edwards
Ezekiel Elliott
Raheem Mostert
Jerome Ford
Devin Singletary
Antonio Gibson
Roschon Johnson
Blake Corum
Jonathon Brooks
Trey Benson
MarShawn Lloyd
Ray Davis
Bucky Irving
Jaylen Wright
Braelon Allen
Isaac Guerendo
Audric Estime
Tyrone Tracy Jr.
Kimani Vidal
Justin Jefferson
Ja'Marr Chase
CeeDee Lamb
Tyreek Hill
A.J. Brown
Amon-Ra St. Brown
Puka Nacua
Garrett Wilson
Chris Olave
Drake London
DK Metcalf
Mike Evans
Davante Adams
Stefon Diggs
Deebo Samuel
Brandon Aiyuk
Nico Collins
Tee Higgins
DeVonta Smith
Terry McLaurin
Jaylen Waddle
Marvin Harrison Jr.
Malik Nabers
Rome Odunze
Brian Thomas Jr.
Ladd McConkey
Xavier Worthy
Keon Coleman
Ricky Pearsall
Adonai Mitchell
Xavier Legette
Jayden Reed
Zay Flowers
Jordan Addison
Rashee Rice
Christian Watson
George Pickens
Michael Pittman Jr.
Courtland Sutton
Jerry Jeudy
Amari Cooper
Keenan Allen
Cooper Kupp
Calvin Ridley
Diontae Johnson
Tyler Lockett
Jakobi Meyers
Darnell Mooney
Curtis Samuel
Tank Dell
Josh Downs
Wan'Dale Robinson
Khalil Shakir
Rashid Shaheed
Jalen McMillan
Jermaine Burton
Troy Franklin
Malachi Corley
Luke McCaffrey
Roman Wilson
Ja'Lynn Polk
Devontez Walker
Brenden Rice
Jalen Coker
Travis Kelce
Sam LaPorta
Mark Andrews
T.J. Hockenson
George Kittle
Trey McBride
Evan Engram
Dalton Kincaid
Kyle Pitts
David Njoku
Jake Ferguson
Cole Kmet
Pat Freiermuth
Dallas Goedert
Hunter Henry
Tyler Higbee
Isaiah Likely
Brock Bowers
Ben Sinnott
Ja'Tavion Sanders
Cade Otton
Tucker Kraft
Luke Musgrave
Michael Mayer
Zach Ertz
Noah Fant
Juwan Johnson
Chigoziem Okonkwo
Myles Garrett
Micah Parsons
T.J. Watt
Nick Bosa
Maxx Crosby
Aidan Hutchinson
Will Anderson Jr.
Danielle Hunter
Trey Hendrickson
Brian Burns
Montez Sweat
Rashan Gary
Chris Jones
Dexter Lawrence
Quinnen Williams
Jeffery Simmons
Vita Vea
Cameron Heyward
Fred Warner
Roquan Smith
Bobby Wagner
Lavonte David
Zack Baun
Jordyn Brooks
Devin White
Patrick Queen
Derwin James
Minkah Fitzpatrick
Kyle Hamilton
Antoine Winfield Jr.
Budda Baker
Jessie Bates III
Talanoa Hufanga
Sauce Gardner
Patrick Surtain II
Jalen Ramsey
Marlon Humphrey
Trent McDuffie
Devon Witherspoon
Christian Gonzalez
Charvarius Ward
Denzel Ward
Jaycee Horn
Riq Woolen
Cooper DeJean
Quinyon Mitchell
Terrion Arnold
Nate Wiggins
Jared Verse
Laiatu Latu
Dallas Turner
Byron Murphy II
Chop Robinson
Edgerrin Cooper
Payton Wilson
Justin Tucker
Harrison Butker
Brandon Aubrey
Jake Elliott
Younghoe Koo
Tyler Bass
Jason Sanders
Cameron Dicker
Chris Boswell
Ka'imi Fairbairn
Trent Williams
Penei Sewell
Lane Johnson
Tristan Wirfs
Laremy Tunsil
Christian Darrisaw
Rashawn Slater
Quenton Nelson
Zack Martin
Creed Humphrey
Frank Ragnow
Joe Thuney
Landon Dickerson
Chris Lindstrom
Tyler Smith
Joe Alt
Olu Fashanu
JC Latham
Amarius Mims$ff$, E'\n'));

-- NFL Teams · 32 items
select public.df20_seed_category('NFL Teams', string_to_array($items$Arizona Cardinals
Atlanta Falcons
Baltimore Ravens
Buffalo Bills
Carolina Panthers
Chicago Bears
Cincinnati Bengals
Cleveland Browns
Dallas Cowboys
Denver Broncos
Detroit Lions
Green Bay Packers
Houston Texans
Indianapolis Colts
Jacksonville Jaguars
Kansas City Chiefs
Las Vegas Raiders
Los Angeles Chargers
Los Angeles Rams
Miami Dolphins
Minnesota Vikings
New England Patriots
New Orleans Saints
New York Giants
New York Jets
Philadelphia Eagles
Pittsburgh Steelers
San Francisco 49ers
Seattle Seahawks
Tampa Bay Buccaneers
Tennessee Titans
Washington Commanders$items$, E'\n'));

-- NBA Teams · 30 items
select public.df20_seed_category('NBA Teams', string_to_array($items$Atlanta Hawks
Boston Celtics
Brooklyn Nets
Charlotte Hornets
Chicago Bulls
Cleveland Cavaliers
Dallas Mavericks
Denver Nuggets
Detroit Pistons
Golden State Warriors
Houston Rockets
Indiana Pacers
LA Clippers
Los Angeles Lakers
Memphis Grizzlies
Miami Heat
Milwaukee Bucks
Minnesota Timberwolves
New Orleans Pelicans
New York Knicks
Oklahoma City Thunder
Orlando Magic
Philadelphia 76ers
Phoenix Suns
Portland Trail Blazers
Sacramento Kings
San Antonio Spurs
Toronto Raptors
Utah Jazz
Washington Wizards$items$, E'\n'));

-- MLB Teams · 30 items
select public.df20_seed_category('MLB Teams', string_to_array($items$Arizona Diamondbacks
Athletics
Atlanta Braves
Baltimore Orioles
Boston Red Sox
Chicago Cubs
Chicago White Sox
Cincinnati Reds
Cleveland Guardians
Colorado Rockies
Detroit Tigers
Houston Astros
Kansas City Royals
Los Angeles Angels
Los Angeles Dodgers
Miami Marlins
Milwaukee Brewers
Minnesota Twins
New York Mets
New York Yankees
Philadelphia Phillies
Pittsburgh Pirates
San Diego Padres
San Francisco Giants
Seattle Mariners
St. Louis Cardinals
Tampa Bay Rays
Texas Rangers
Toronto Blue Jays
Washington Nationals$items$, E'\n'));

-- US States · 50 items
select public.df20_seed_category('US States', string_to_array($items$Alabama
Alaska
Arizona
Arkansas
California
Colorado
Connecticut
Delaware
Florida
Georgia
Hawaii
Idaho
Illinois
Indiana
Iowa
Kansas
Kentucky
Louisiana
Maine
Maryland
Massachusetts
Michigan
Minnesota
Mississippi
Missouri
Montana
Nebraska
Nevada
New Hampshire
New Jersey
New Mexico
New York
North Carolina
North Dakota
Ohio
Oklahoma
Oregon
Pennsylvania
Rhode Island
South Carolina
South Dakota
Tennessee
Texas
Utah
Vermont
Virginia
Washington
West Virginia
Wisconsin
Wyoming$items$, E'\n'));

-- Breakfast Cereals · 50 items
select public.df20_seed_category('Breakfast Cereals', string_to_array($items$Lucky Charms
Cheerios
Honey Nut Cheerios
Frosted Flakes
Froot Loops
Cinnamon Toast Crunch
Rice Krispies
Corn Flakes
Raisin Bran
Special K
Cocoa Puffs
Trix
Apple Jacks
Cap'n Crunch
Crunch Berries
Golden Grahams
Cookie Crisp
Reese's Puffs
Honey Bunches of Oats
Frosted Mini-Wheats
Life
Kix
Wheaties
Grape-Nuts
Shredded Wheat
Corn Chex
Rice Chex
Honeycomb
Fruity Pebbles
Cocoa Pebbles
Alpha-Bits
Count Chocula
Franken Berry
Boo Berry
Corn Pops
Honey Smacks
Krave
Raisin Nut Bran
Total
Oatmeal Crisp
Puffins
Cracklin' Oat Bran
Mueslix
Basic 4
French Toast Crunch
Waffle Crisp
Frosted Cheerios
Multi Grain Cheerios
Peanut Butter Crunch
Golden Crisp$items$, E'\n'));

-- Fast Food Chains · 50 items
select public.df20_seed_category('Fast Food Chains', string_to_array($items$McDonald's
Burger King
Wendy's
Taco Bell
KFC
Subway
Chick-fil-A
Popeyes
Chipotle
Five Guys
Shake Shack
In-N-Out Burger
Whataburger
Culver's
Sonic Drive-In
Jack in the Box
Arby's
Dairy Queen
Hardee's
Carl's Jr.
White Castle
Raising Cane's
Zaxby's
Bojangles
Church's Chicken
Del Taco
Qdoba
Moe's Southwest Grill
Panera Bread
Panda Express
Jimmy John's
Jersey Mike's
Firehouse Subs
Potbelly
Quiznos
Domino's
Pizza Hut
Papa John's
Little Caesars
Wingstop
Buffalo Wild Wings
Dunkin'
Starbucks
Tim Hortons
Krispy Kreme
Auntie Anne's
Cinnabon
Checkers
Steak 'n Shake
Portillo's$items$, E'\n'));

-- Candy and Sweets · 50 items
select public.df20_seed_category('Candy and Sweets', string_to_array($items$Snickers
Milky Way
Twix
3 Musketeers
Butterfinger
Baby Ruth
Reese's Peanut Butter Cups
Kit Kat
Hershey's Milk Chocolate
Cookies 'n' Creme
Almond Joy
Mounds
Payday
100 Grand
Take 5
Whatchamacallit
Mr. Goodbar
Krackel
Heath Bar
Skor
Toblerone
Nestle Crunch
Charleston Chew
Zagnut
Bit-O-Honey
Oh Henry!
Rolo
Twizzlers
Milk Duds
Whoppers
Junior Mints
Raisinets
Goobers
Sno-Caps
Dots
Airheads
Starburst
Skittles
Sour Patch Kids
Swedish Fish
Nerds
Laffy Taffy
Jolly Rancher
Tootsie Roll
Gobstopper
Runts
Now and Later
Mike and Ike
Warheads
Ring Pop$items$, E'\n'));

-- Pizza Toppings · 40 items
select public.df20_seed_category('Pizza Toppings', string_to_array($items$Pepperoni
Italian Sausage
Mushrooms
Onions
Green Peppers
Black Olives
Bacon
Ham
Pineapple
Extra Cheese
Spinach
Fresh Tomatoes
Jalapenos
Roasted Garlic
Fresh Basil
Anchovies
Grilled Chicken
Ground Beef
Salami
Prosciutto
Artichoke Hearts
Sun-Dried Tomatoes
Red Onion
Banana Peppers
Ricotta
Feta
Goat Cheese
Blue Cheese
Broccoli
Zucchini
Eggplant
Arugula
Pesto
BBQ Sauce
Buffalo Sauce
Meatballs
Chorizo
Sweet Corn
Fried Egg
Truffle Oil$items$, E'\n'));

-- Ice Cream Flavors · 40 items
select public.df20_seed_category('Ice Cream Flavors', string_to_array($items$Vanilla
Chocolate
Strawberry
Mint Chocolate Chip
Cookies and Cream
Rocky Road
Butter Pecan
Neapolitan
Cookie Dough
Pistachio
Coffee
Salted Caramel
Chocolate Chip
Moose Tracks
Birthday Cake
Peanut Butter Cup
Mango
Coconut
Lemon Sorbet
Raspberry Ripple
Rum Raisin
Black Raspberry
Maple Walnut
Praline
Cheesecake
Tiramisu
Green Tea
Cotton Candy
Superman
Bubblegum
Banana
Peach
Pumpkin
Eggnog
Spumoni
Cannoli
S'mores
Caramel Swirl
Butterscotch
Blackberry$items$, E'\n'));

-- Soft Drinks · 40 items
select public.df20_seed_category('Soft Drinks', string_to_array($items$Coca-Cola
Diet Coke
Coke Zero
Pepsi
Diet Pepsi
Dr Pepper
Sprite
7 Up
Mountain Dew
Fanta Orange
Fanta Grape
Sunkist
Orange Crush
A&W Root Beer
Barq's
Mug Root Beer
Canada Dry Ginger Ale
Schweppes
Squirt
Fresca
Mello Yello
Big Red
Cheerwine
Moxie
Jarritos
Inca Kola
Irn-Bru
Vernors
Faygo
Shasta
RC Cola
Cherry Coke
Vanilla Coke
Diet Dr Pepper
Code Red
Wild Cherry Pepsi
Sprite Zero
Ginger Beer
Cream Soda
Root Beer Float$items$, E'\n'));

-- Dog Breeds · 50 items
select public.df20_seed_category('Dog Breeds', string_to_array($items$Labrador Retriever
Golden Retriever
German Shepherd
French Bulldog
Bulldog
Poodle
Beagle
Rottweiler
Dachshund
Yorkshire Terrier
Boxer
Siberian Husky
Great Dane
Doberman Pinscher
Australian Shepherd
Border Collie
Shih Tzu
Pomeranian
Chihuahua
Pug
Cocker Spaniel
Boston Terrier
Bernese Mountain Dog
Cavalier King Charles Spaniel
Shiba Inu
Corgi
Basset Hound
Bloodhound
Saint Bernard
Newfoundland
Mastiff
Weimaraner
Vizsla
Whippet
Greyhound
Jack Russell Terrier
Scottish Terrier
West Highland White Terrier
Samoyed
Akita
Alaskan Malamute
Papillon
Maltese
Bichon Frise
Havanese
Schnauzer
Airedale Terrier
Irish Setter
Springer Spaniel
Australian Cattle Dog$items$, E'\n'));

-- Board Games · 50 items
select public.df20_seed_category('Board Games', string_to_array($items$Monopoly
Scrabble
Risk
Clue
Catan
Ticket to Ride
Carcassonne
Pandemic
Chess
Checkers
Backgammon
Go
Battleship
Connect Four
Sorry!
Trouble
The Game of Life
Candy Land
Chutes and Ladders
Operation
Guess Who?
Yahtzee
Boggle
Trivial Pursuit
Balderdash
Taboo
Pictionary
Cranium
Codenames
Dixit
Azul
Wingspan
Splendor
7 Wonders
Dominion
Agricola
Terraforming Mars
Scythe
Gloomhaven
Betrayal at House on the Hill
Munchkin
Exploding Kittens
Uno
Skip-Bo
Phase 10
Jenga
Twister
Mancala
Stratego
Axis and Allies$items$, E'\n'));

-- Video Game Franchises · 50 items
select public.df20_seed_category('Video Game Franchises', string_to_array($items$Super Mario
The Legend of Zelda
Pokemon
Call of Duty
Grand Theft Auto
Minecraft
FIFA
Madden NFL
Halo
Final Fantasy
Resident Evil
Street Fighter
Mortal Kombat
Tekken
Sonic the Hedgehog
Metal Gear
Assassin's Creed
Far Cry
Battlefield
Doom
The Elder Scrolls
Fallout
Diablo
StarCraft
Warcraft
Overwatch
Counter-Strike
Half-Life
Portal
Left 4 Dead
BioShock
Dark Souls
Elden Ring
Monster Hunter
Animal Crossing
Kirby
Metroid
Donkey Kong
Splatoon
Fire Emblem
Civilization
SimCity
The Sims
Tomb Raider
Uncharted
God of War
The Last of Us
Gran Turismo
Forza
Need for Speed$items$, E'\n'));

-- Superheroes · 50 items
select public.df20_seed_category('Superheroes', string_to_array($items$Superman
Batman
Spider-Man
Iron Man
Captain America
Thor
Hulk
Black Widow
Hawkeye
Wonder Woman
The Flash
Aquaman
Green Lantern
Cyborg
Doctor Strange
Black Panther
Ant-Man
Wasp
Captain Marvel
Scarlet Witch
Vision
Falcon
Winter Soldier
Star-Lord
Gamora
Drax
Rocket Raccoon
Groot
Wolverine
Cyclops
Storm
Jean Grey
Professor X
Beast
Nightcrawler
Rogue
Gambit
Deadpool
Daredevil
Punisher
Jessica Jones
Luke Cage
Iron Fist
Ghost Rider
Silver Surfer
Mister Fantastic
Invisible Woman
Human Torch
The Thing
Nova$items$, E'\n'));

-- Chip Flavors · 30 items
select public.df20_seed_category('Chip Flavors', string_to_array($items$Original
Barbecue
Sour Cream and Onion
Salt and Vinegar
Cheddar and Sour Cream
Jalapeno
Dill Pickle
Honey Barbecue
Flamin' Hot
Nacho Cheese
Cool Ranch
Spicy Sweet Chili
Ranch
Buffalo
Ketchup
All Dressed
Prawn Cocktail
Cheese and Onion
Roast Chicken
Smoky Bacon
Sea Salt
Cracked Black Pepper
Chili Lime
Wasabi
Truffle
Garlic Parmesan
Everything Bagel
Pizza
Taco
Sweet Onion$items$, E'\n'));

do $$
declare v_c int; v_i int;
begin
  select count(*) into v_c from public.category_library;
  select count(*) into v_i from public.category_library_items;
  raise notice 'library now holds % categories and % items', v_c, v_i;
end $$;