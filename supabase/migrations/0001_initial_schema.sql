-- Saap-Sidi — Database setup (Layer 1)
-- This turns our "three notebooks" plan into real tables.
-- Plain-language notes are in the comments so it stays readable.
--
-- Golden rule baked in here: phones may READ, but only the server (the referee)
-- may WRITE. That is what stops cheating.

-- ---------------------------------------------------------------------------
-- Notebook 1: GAMES  (one row per game room)
-- ---------------------------------------------------------------------------
create table if not exists games (
  id              uuid primary key default gen_random_uuid(),

  -- 'waiting' (lobby), 'playing' (in progress), or 'finished'
  status          text not null default 'waiting'
                    check (status in ('waiting', 'playing', 'finished')),

  is_private      boolean not null default false,   -- future: private rooms
  join_code       text,                             -- future: code to join a room

  turn_seconds    integer not null default 20,      -- seconds per turn

  -- Whose turn it is, tracked by seat number (1,2,3…). Null while waiting.
  current_seat    integer,

  -- The strict turn counter. Every completed turn bumps this up by 1.
  turn_number     integer not null default 0,

  -- When the current turn auto-plays if the player hasn't acted.
  turn_deadline   timestamptz,

  -- The owner ("master") account. Marked as leader whenever present.
  owner_user_id   uuid,

  -- Set when someone reaches exactly 100.
  winner_player_id uuid,

  created_at      timestamptz not null default now(),
  started_at      timestamptz,
  finished_at     timestamptz
);

-- ---------------------------------------------------------------------------
-- Notebook 2: PLAYERS  (one row per seat in a game)
-- ---------------------------------------------------------------------------
create table if not exists players (
  id            uuid primary key default gen_random_uuid(),
  game_id       uuid not null references games(id) on delete cascade,

  -- Who this is. Comes from Supabase login (works the same for the automatic
  -- anonymous ID or a real sign-in — so we can switch later for free).
  user_id       uuid not null,
  display_name  text not null default 'Player',

  seat          integer not null,                 -- turn order / join order
  position      integer not null default 0        -- square 0..100
                  check (position between 0 and 100),

  is_ready      boolean not null default false,   -- pressed "ready" in lobby
  is_connected  boolean not null default true,    -- online right now? (display only)
  is_master     boolean not null default false,   -- is this the owner's phone?

  joined_at     timestamptz not null default now(),
  last_seen_at  timestamptz not null default now(),

  -- One seat per person per game, and no two people share a seat number.
  unique (game_id, user_id),
  unique (game_id, seat)
);

-- ---------------------------------------------------------------------------
-- Notebook 3: MOVES  (permanent history — one row per turn taken)
-- ---------------------------------------------------------------------------
create table if not exists moves (
  id            uuid primary key default gen_random_uuid(),
  game_id       uuid not null references games(id) on delete cascade,
  player_id     uuid not null references players(id) on delete cascade,

  turn_number   integer not null,                 -- which turn this was
  dice          integer not null check (dice between 1 and 6),
  from_position integer not null,
  to_position   integer not null,

  -- Did this move slide down a snake, climb a ladder, or neither?
  jump_type     text not null default 'none'
                  check (jump_type in ('none', 'snake', 'ladder')),

  was_autoplay  boolean not null default false,   -- did the timer roll for them?
  created_at    timestamptz not null default now(),

  -- *** THE SECRET INGREDIENT ***
  -- Only ONE row can ever exist for a given turn in a given game. If a real tap
  -- and an AutoPlay both try to write turn 7, the first wins and the second is
  -- rejected. This is what makes AutoPlay and reconnect safe.
  unique (game_id, turn_number)
);

-- Helpful lookups (speed only; no behavior change).
create index if not exists idx_players_game on players(game_id);
create index if not exists idx_moves_game   on moves(game_id);

-- ---------------------------------------------------------------------------
-- Lock the notebooks: phones may READ, only the server may WRITE.
-- ---------------------------------------------------------------------------
alter table games   enable row level security;
alter table players enable row level security;
alter table moves   enable row level security;

-- Anyone logged in (including the automatic anonymous ID) may READ.
-- Because it is one shared friends' lobby, reading everything is fine.
create policy "read games"   on games   for select to authenticated using (true);
create policy "read players" on players for select to authenticated using (true);
create policy "read moves"   on moves   for select to authenticated using (true);

-- No write policies on purpose: phones cannot insert/update/delete directly.
-- All changes go through the server functions (the referee), which are allowed
-- to bypass these locks. This is the anti-cheat guarantee.
