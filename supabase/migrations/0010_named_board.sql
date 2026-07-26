-- Saap-Sidi — the board gets characters (Layer 2)
--
-- Two things happen here.
--
-- 1) We swap the classic board for the designed one from board-config.json:
--    7 snakes and 8 ladders instead of 10 and 9. The board is now less crowded
--    and more deliberate.
--
-- 2) Every snake and ladder gets a NAME. This is the real point. It is what
--    lets the game say "RK walked straight into Nibble" instead of "RK went
--    down a snake" — you cannot be teased about an anonymous snake.
--
-- NOT included on purpose: the "hidden squares" idea (a snake and a ladder
-- that are invisible until triggered, at positions that shuffle each game).
-- board-config.json marks that PROPOSED and un-balance-tested, and its own
-- notes say to re-run the simulator before switching it on. So Kaal and the
-- first ladder are ordinary visible ones for now.
--
-- Note this retires an old quirk: the classic board had an 80 -> 100 ladder,
-- so landing on 80 won instantly. The new board's top ladder is 81 -> 99, so
-- that no longer happens — you still have to roll the exact 1.

-- ---------------------------------------------------------------------------
-- Give the board room for names.
-- ---------------------------------------------------------------------------
alter table board_jumps add column if not exists name    text;
alter table board_jumps add column if not exists char_id text;
alter table board_jumps add column if not exists zone    text;

-- ---------------------------------------------------------------------------
-- Out with the classic layout, in with the designed one.
--
-- Safe to wipe: the board is a lookup sheet, not history. Past games recorded
-- whether each move was a snake or a ladder in their own rows, so old games
-- keep making sense.
-- ---------------------------------------------------------------------------
delete from board_jumps;

insert into board_jumps (from_square, to_square, kind, char_id, name, zone) values
  -- SNAKES (down) -----------------------------------------------------------
  (17, 4,  'snake', 'nibble', 'Nibble',          'riverbank'),
  (32, 13, 'snake', 'dozer',  'Dozer',           'jungle'),
  (46, 25, 'snake', 'slick',  'Slick',           'jungle'),
  (62, 18, 'snake', 'vyra',   'Vyra',            'ruins'),
  (74, 43, 'snake', 'kaal',   'Kaal',            'temple'),
  (88, 50, 'snake', 'maya',   'Maya',            'temple'),

  -- The King has a WIDE HEAD: squares 97 and 98 both feed the same snake.
  -- Two rows, one character. This is deliberate — it raises his appearance
  -- rate from roughly a third of games to about half, so the board's biggest
  -- character actually turns up.
  (97, 24, 'snake', 'king',   'The King',        'shrine'),
  (98, 24, 'snake', 'king',   'The King',        'shrine'),

  -- LADDERS (up) ------------------------------------------------------------
  -- board-config.json noted that eight anonymous sticks were facing seven
  -- named snakes, which is an unfair fight for the player's affection. So the
  -- ladders are named too.
  (2,  23, 'ladder', 'reedstalk',  'Reedstalk',      'riverbank'),
  (9,  34, 'ladder', 'driftwood',  'Driftwood',      'riverbank'),
  (20, 44, 'ladder', 'monkey',     'Monkey Bridge',  'jungle'),
  (28, 59, 'ladder', 'oldvine',    'The Old Vine',   'jungle'),
  (40, 66, 'ladder', 'column',     'Cracked Column', 'ruins'),
  (54, 77, 'ladder', 'arch',       'Fallen Arch',    'ruins'),
  (63, 86, 'ladder', 'prayer',     'Prayer Steps',   'temple'),
  -- Must stay visible and obvious. Its whole value is that everyone can see
  -- it and races each other for it.
  (81, 99, 'ladder', 'golden',     'The Golden Stair', 'temple');

-- ---------------------------------------------------------------------------
-- THE SAFETY CHECK
--
-- board-config.json asks for these to be verified whenever the board changes,
-- and calls a failure "a config error, not a runtime error" — meaning it
-- should blow up HERE, loudly, rather than confuse a player mid-game.
--
-- If any line below is wrong, this whole file refuses to run and nothing
-- changes. A broken board never reaches the game.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bad integer;
begin
  -- A ladder must never drop you straight onto a snake's head, and a snake
  -- must never drop you straight onto a ladder. Those are chains: one roll
  -- flinging you across the whole board, which feels broken rather than fun.
  select count(*) into v_bad
  from board_jumps a join board_jumps b on a.to_square = b.from_square;
  if v_bad > 0 then
    raise exception 'Board error: % chain(s) found — a jump lands on another jump', v_bad;
  end if;

  -- Every square may do at most one job. (from_square is already the primary
  -- key, so this catches a landing square doubling as a starting square.)
  select count(*) into v_bad
  from board_jumps a join board_jumps b on a.to_square = b.to_square
  where a.from_square <> b.from_square and a.char_id is distinct from b.char_id;
  if v_bad > 0 then
    raise exception 'Board error: two different characters share a landing square';
  end if;

  -- Snakes must go down, ladders must go up.
  select count(*) into v_bad from board_jumps
  where (kind = 'snake' and to_square >= from_square)
     or (kind = 'ladder' and to_square <= from_square);
  if v_bad > 0 then
    raise exception 'Board error: % jump(s) point the wrong way', v_bad;
  end if;

  -- Nothing may start on the winning square.
  if exists (select 1 from board_jumps where from_square = 100) then
    raise exception 'Board error: something starts on square 100';
  end if;

  -- Everything must be named, or the game cannot tease anyone.
  if exists (select 1 from board_jumps where name is null or char_id is null) then
    raise exception 'Board error: an unnamed snake or ladder slipped through';
  end if;

  raise notice 'Board OK: % snakes/ladders, all named, no chains.',
    (select count(distinct char_id) from board_jumps);
end $$;
