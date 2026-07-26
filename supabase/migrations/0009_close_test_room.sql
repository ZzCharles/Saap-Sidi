-- Saap-Sidi — Close the room left behind by the ghost test
--
-- Proving the away-detection fix meant actually starting a round, which left a
-- real game in progress containing a made-up player called "TestPhone". If we
-- left it, opening the app would reconnect you into that test game — because
-- rejoining an unfinished game is exactly what the app is supposed to do.
--
-- SAFETY NOTE: checked against the live database first — at the time of writing
-- there was exactly ONE room in 'playing' state (this test room) and four
-- finished ones. That is why targeting every 'playing' room is safe here. Do not
-- copy this file as a general-purpose tidy-up; use 0006, which has a time guard
-- so it can never touch a game that is genuinely being played.

-- 1) Remove the players that never existed outside the test.
delete from players
 where display_name in ('TestPhone', 'GhostPhone');

-- 2) Retire the test room. finished_at is backdated by a day on purpose, so the
--    room does not look "just finished" and start claiming people under the
--    2-hour rule from 0005. The next person to open the app gets a fresh lobby.
update games
   set status        = 'finished',
       current_seat  = null,
       turn_deadline = null,
       finished_at   = now() - interval '1 day'
 where status = 'playing';

-- Show what's left. Expect: finished 5, and no 'playing' row at all.
select status, count(*) as rooms
  from games
 group by status
 order by status;
