-- ═══════════════════════════════════════════════════════════════════════════
-- DraftFor20 · 0001 · schema
--
-- All money is INTEGER CENTS. $20.00 is 2000. No floats anywhere.
-- A team is a FLAT LIST of roster_size players. There are no positions.
-- ═══════════════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto;

-- ── the auctionable pool. A NAME AND NOTHING ELSE. ─────────────────────────
-- No position, no rating, no image. The app must never hint at who is good;
-- that judgement is the entire game.
create table public.nfl_players (
  id   serial primary key,
  name text not null unique
);

-- ── optional host accounts ─────────────────────────────────────────────────
-- Deliberately NOT dropped by 0000: this is tied to auth.users and holds real
-- host accounts. Its shape did not change between v1 and v2, so it is created
-- only if missing and survives a re-run.
create table if not exists public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  email          text,
  display_name   text,
  brand_logo_url text,
  brand_accent   text,
  created_at     timestamptz not null default now()
);

create table public.templates (
  id                        uuid primary key default gen_random_uuid(),
  owner_id                  uuid not null references public.profiles(id) on delete cascade,
  name                      text not null,
  default_roster_size       int  not null default 5,
  default_bankroll_cents    int  not null default 2000,
  default_min_bid_cents     int  not null default 100,
  default_timer_seconds     int  not null default 15,
  default_gives_per_player  int  not null default 2,
  created_at                timestamptz not null default now()
);
create index templates_owner_idx on public.templates(owner_id);

-- ── rooms ──────────────────────────────────────────────────────────────────
create table public.rooms (
  id                      uuid primary key default gen_random_uuid(),
  code                    text not null unique,
  title                   text not null,
  status                  text not null default 'lobby'
                            check (status in ('lobby','live','complete','abandoned')),
  phase                   text not null default 'lobby'
                            check (phase in ('lobby','offering','bidding','complete')),

  roster_size             int not null check (roster_size between 1 and 30),
  starting_bankroll_cents int not null check (starting_bankroll_cents >= 0),
  min_bid_cents           int not null check (min_bid_cents >= 0),
  timer_seconds           int not null default 15 check (timer_seconds between 3 and 300),
  -- how many times each player may hand a card to their opponent for free.
  -- Without a cap, both players dumping every card is a stable equilibrium
  -- that ends the draft with two random rosters and zero bids placed.
  gives_per_player        int not null default 2 check (gives_per_player >= 0),

  is_private              boolean not null default true,
  brand_accent            text,
  brand_logo_url          text,
  host_profile_id         uuid references public.profiles(id) on delete set null,

  opener_seat             int not null default 1 check (opener_seat in (1,2)),
  version                 bigint not null default 0,
  created_at              timestamptz not null default now(),
  started_at              timestamptz,
  completed_at            timestamptz
);

-- ── the two humans ─────────────────────────────────────────────────────────
create table public.players (
  id             uuid primary key default gen_random_uuid(),
  room_id        uuid not null references public.rooms(id) on delete cascade,
  seat           int not null check (seat in (1,2)),
  display_name   text not null,
  session_token  uuid not null default gen_random_uuid(),   -- SECRET, never read out
  profile_id     uuid references public.profiles(id) on delete set null,
  bankroll_cents int not null,
  is_host        boolean not null default false,
  gives_used     int not null default 0,
  last_seen_at   timestamptz not null default now(),
  created_at     timestamptz not null default now(),
  unique (room_id, seat)
);
create index players_room_idx on public.players(room_id);
create unique index players_token_idx on public.players(session_token);

-- ── THE HIDDEN DECK ────────────────────────────────────────────────────────
-- The explicit shuffled order, not a seed, so there is nothing a client could
-- replay to regenerate it. RLS denies everything and df20_public_state never
-- reads an unrevealed row, so upcoming cards are unreachable from a browser.
create table public.room_deck (
  room_id       uuid not null references public.rooms(id) on delete cascade,
  position      int not null,
  nfl_player_id int not null references public.nfl_players(id),
  revealed_at   timestamptz,
  primary key (room_id, position),
  unique (room_id, nfl_player_id)
);
create index room_deck_next_idx on public.room_deck(room_id, position)
  where revealed_at is null;

-- ── what each player has won. A flat list, ordered by pick. ────────────────
create table public.roster_entries (
  id            uuid primary key default gen_random_uuid(),
  room_id       uuid not null references public.rooms(id) on delete cascade,
  player_id     uuid not null references public.players(id) on delete cascade,
  pick_number   int  not null,
  nfl_player_id int  references public.nfl_players(id),
  item_name     text not null,
  price_cents   int  not null default 0 check (price_cents >= 0),
  gifted        boolean not null default false,
  won_at        timestamptz not null default now(),
  unique (room_id, player_id, pick_number),
  unique (room_id, nfl_player_id)          -- one room, one home per card
);
create index roster_room_idx on public.roster_entries(room_id);

-- ── one auction ────────────────────────────────────────────────────────────
create table public.lots (
  id                     uuid primary key default gen_random_uuid(),
  room_id                uuid not null references public.rooms(id) on delete cascade,
  nfl_player_id          int  references public.nfl_players(id),
  item_name              text not null,
  opener_player_id       uuid references public.players(id) on delete set null,
  status                 text not null default 'offered'
                           check (status in ('offered','bidding','resolved','void')),
  current_bid_cents      int not null default 0,
  high_bidder_player_id  uuid references public.players(id) on delete set null,
  on_the_clock_player_id uuid references public.players(id) on delete set null,
  turn_expires_at        timestamptz,          -- SERVER AUTHORITATIVE COUNTDOWN
  turn_seq               int not null default 0,
  winner_player_id       uuid references public.players(id) on delete set null,
  final_price_cents      int,
  gifted                 boolean not null default false,
  created_at             timestamptz not null default now(),
  resolved_at            timestamptz
);
create index lots_room_idx on public.lots(room_id, created_at);
create unique index lots_one_open_per_room on public.lots(room_id)
  where status in ('offered','bidding');

-- ── history. drives the results card and the replay strip. ─────────────────
create table public.bid_events (
  id           bigserial primary key,
  room_id      uuid not null references public.rooms(id) on delete cascade,
  lot_id       uuid not null references public.lots(id) on delete cascade,
  player_id    uuid references public.players(id) on delete set null,
  action       text not null check (action in
                 ('reveal','offer_take','offer_give','discard','raise',
                  'pass','timeout_pass','won','blocked_win')),
  amount_cents int,
  turn_seq     int not null default 0,
  created_at   timestamptz not null default now()
);
create index bid_events_room_idx on public.bid_events(room_id, id);

create table public.votes (
  id               uuid primary key default gen_random_uuid(),
  room_id          uuid not null references public.rooms(id) on delete cascade,
  voter_player_id  uuid not null references public.players(id) on delete cascade,
  winner_player_id uuid not null references public.players(id) on delete cascade,
  created_at       timestamptz not null default now(),
  unique (room_id, voter_player_id)
);

-- ── abuse control (used by the Next route handlers in front of the RPCs) ───
create table public.rate_limits (
  bucket       text not null,
  subject      text not null,
  window_start timestamptz not null,
  count        int not null default 0,
  primary key (bucket, subject, window_start)
);
create index rate_limits_sweep_idx on public.rate_limits(window_start);
