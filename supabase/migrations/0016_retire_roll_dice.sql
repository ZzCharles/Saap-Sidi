-- Saap-Sidi — retire roll_dice (Layer 2)
--
-- RUN THIS ONLY AFTER THE NEW APP IS LIVE AND WORKING ON YOUR PHONE.
--
-- roll_dice found "the running game this person is in" and assumed there was
-- only one. Single player is exactly the thing that breaks that assumption: a
-- person with a solo game AND a seat in the friends' room has two, and the old
-- function picked between them at random.
--
-- roll_in_game (0011) replaced it by being told which game outright. The app
-- now calls that instead, so the old one is dead weight — and dead weight in a
-- database is worse than dead weight in a file, because it still works. Left
-- alone it would sit there for years, quietly available to any old copy of the
-- app still cached on somebody's phone.
--
-- If you run this and something breaks, migration 0004 holds the original and
-- can be re-run to bring it back.

drop function if exists roll_dice(integer);

-- ---------------------------------------------------------------------------
-- While we are here: close solo games nobody came back to.
--
-- Every test game played during development is still sitting there marked
-- 'playing'. They harm nothing — a solo game is private and never touches the
-- friends' lobby — but they are clutter, and clutter turns into a confusing
-- bug eventually.
--
-- The 6-hour guard means this can never reach into a game being played now.
-- ---------------------------------------------------------------------------
update games
   set status        = 'finished',
       current_seat  = null,
       turn_deadline = null,
       finished_at   = coalesce(finished_at, lobby_opened_at)
 where mode = 'solo'
   and status = 'playing'
   and lobby_opened_at < now() - interval '6 hours';

-- What is left, so you can see the result rather than take it on trust.
select mode, status, count(*) as rooms
  from games
 group by mode, status
 order by mode, status;
