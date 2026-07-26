-- Saap-Sidi — Tidy up abandoned test rooms
--
-- WHY THIS EXISTS
-- During development we walked away from several games without finishing them.
-- As far as the database is concerned those rooms are still 'playing'.
--
-- That matters because join_lobby's very first question is "am I already in a
-- game that hasn't finished?" — the reconnect feature. So opening the app can
-- drop you back into a stale half-played game instead of a fresh lobby, which
-- looks exactly like a bug but isn't.
--
-- WHAT THIS DOES
-- It closes off old abandoned games by marking them 'finished'. It does NOT
-- delete anything: every room, every player and the whole move history stays
-- exactly where it is. We are only saying "this game is over", which is the
-- truth — nobody has touched them in days.
--
-- THE 6-HOUR GUARD
-- Only rooms untouched for more than 6 hours are affected, so this can never
-- reach in and kill a game that is actually being played right now. It is safe
-- to run more than once.

update games
   set status        = 'finished',
       current_seat  = null,
       turn_deadline = null,

       -- Backdate the finish time to when the room was last opened. This matters:
       -- join_lobby treats a room that finished in the LAST 2 HOURS as still
       -- yours (so a reload on the winner screen returns you to your friends).
       -- Stamping these with the current time would make these dead rooms start
       -- claiming people all over again. Backdating retires them properly.
       finished_at   = coalesce(finished_at, lobby_opened_at)

 where status = 'playing'
   and lobby_opened_at < now() - interval '6 hours';

-- Show what is left, so you can see the result rather than take it on trust.
select status,
       count(*) as rooms
  from games
 group by status
 order by status;
