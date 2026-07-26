-- Saap-Sidi — turns get faster (Layer 2)
--
-- 20 seconds was chosen before anyone had actually played. In practice it is
-- too long: the game sags while everyone waits for the timer rather than for
-- the player. Down to 15.
--
-- Worth remembering WHY this is a single number in the database and not
-- something each phone decides: the countdown every player sees is drawn from
-- the server's deadline. If phones chose their own, a fast phone could rush
-- someone. Changing it here changes it for everybody at once.

-- New rooms get 15 seconds.
alter table games alter column turn_seconds set default 15;

-- So do the rooms that already exist, including any lobby sitting open right
-- now. A game currently mid-turn keeps its present deadline and picks up the
-- shorter clock on the next turn — nobody gets time snatched away from them
-- while they are looking at the board.
update games set turn_seconds = 15 where turn_seconds <> 15;
