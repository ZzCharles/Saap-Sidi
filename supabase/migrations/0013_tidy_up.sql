-- Saap-Sidi — housekeeping (Layer 2)
--
-- No new features. This clears out three bits of debris found while auditing
-- the database against the code.
--
-- Nothing here touches the rules of the game, and nothing here deletes a real
-- game you played. Safe to run more than once.

-- ---------------------------------------------------------------------------
-- 1) Remove a test game that Claude created while checking the new single
--    player function actually worked.
--
--    Verifying that a function exists means calling it, and calling
--    start_solo_game does exactly what it says: it dealt a real game to a
--    throwaway anonymous account. Harmless, but it is litter, and litter in a
--    database has a habit of turning into a confusing bug six months later.
--
--    Identified precisely by the name used for the probe, so this can only
--    ever match that one game.
-- ---------------------------------------------------------------------------
delete from games g
 where g.mode = 'solo'
   and exists (
     select 1 from players p
      where p.game_id = g.id
        and p.display_name = '__probe__'
   );

-- ---------------------------------------------------------------------------
-- 2) Close rooms that were walked away from mid-game.
--
--    Same reasoning as 0006, and the same 6-hour guard so it can never reach
--    into a game being played right now. It marks them finished rather than
--    deleting them — the move history stays intact.
--
--    This matters because join_lobby's first question is "am I already in a
--    game that hasn't finished?" A stale half-played room answers yes, and
--    opening the app drops you into it instead of a fresh lobby.
-- ---------------------------------------------------------------------------
update games
   set status        = 'finished',
       current_seat  = null,
       turn_deadline = null,
       finished_at   = coalesce(finished_at, lobby_opened_at)
 where status = 'playing'
   and lobby_opened_at < now() - interval '6 hours';

-- ---------------------------------------------------------------------------
-- 3) A note about roll_dice, deliberately NOT acted on yet.
--
--    roll_in_game (0011) replaces roll_dice, because the old one found "the
--    running game this person is in" and assumed there was only one — the
--    assumption single player breaks.
--
--    But the published app still calls roll_dice. Dropping it now would break
--    the live game for anyone playing. It gets retired in the same change that
--    updates the app, not before.
--
--    Left here as a reminder rather than a comment in a file nobody opens:
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_proc where proname = 'roll_dice') then
    raise notice 'Reminder: roll_dice is superseded by roll_in_game. Retire it in the same release that updates the app.';
  end if;
end $$;

-- What is left, so you can see the result rather than take it on trust.
select mode, status, count(*) as rooms
  from games
 group by mode, status
 order by mode, status;
