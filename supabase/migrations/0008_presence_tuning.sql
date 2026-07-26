-- Saap-Sidi — Correcting the "away" rule from 0007
--
-- WHAT WE GOT WRONG IN 0007
-- 0007 said "present = pinged in the last 30 seconds", and start_game DELETED
-- anyone who wasn't present. Testing immediately showed why that is dangerous:
-- browsers throttle background tabs and then freeze them altogether, so the ping
-- stops whenever the window isn't in front. Two players who were sitting right
-- there, tabs open, measured 47 seconds and 466 seconds since their last ping.
--
-- Under 0007's rule a friend whose phone screen simply locked would be marked
-- away and then DELETED from the round when the leader pressed Start — with no
-- way back into a game already in progress. That is a worse bug than the ghost
-- problem we set out to fix.
--
-- THE CORRECTED DESIGN — two different questions, two different answers
--
--   "Are they responding right now?"  -> 45 seconds.
--      Used to decide who holds Start and whose "ready" we wait for. Being wrong
--      here is cheap and self-correcting: they come back and they count again.
--
--   "Have they abandoned the room?"   -> 5 minutes.
--      The ONLY thing that removes somebody from the room. Being wrong here is
--      expensive and permanent, so it needs to be near-certain. Five minutes is
--      past the point where browsers freeze a hidden tab entirely, so a phone
--      still ticking over at all will never cross it.
--
-- Net effect: a ghost still cannot block the Start button (the bug we came for),
-- but a real friend who looked at their messages keeps their seat, and AutoPlay
-- covers their turns until they look back.

-- ---------------------------------------------------------------------------
-- "Responding right now?" — widened from 30s to 45s.
-- Kept as one definition so the rule cannot drift apart between places.
-- NOTE: game.js knows this too, as AWAY_AFTER_MS. Change one, change the other.
-- ---------------------------------------------------------------------------
create or replace function player_is_present(p_is_connected boolean, p_last_seen timestamptz)
returns boolean
language sql
stable
set search_path = public
as $$
  select coalesce(p_is_connected, false)
     and p_last_seen > now() - interval '45 seconds';
$$;

-- ---------------------------------------------------------------------------
-- "Abandoned the room?" — the only thing that costs you your seat.
-- Either you closed the app cleanly, or you have been silent for 5 whole minutes.
-- ---------------------------------------------------------------------------
create or replace function player_has_abandoned(p_is_connected boolean, p_last_seen timestamptz)
returns boolean
language sql
stable
set search_path = public
as $$
  select not coalesce(p_is_connected, false)
      or p_last_seen <= now() - interval '5 minutes';
$$;

-- ---------------------------------------------------------------------------
-- START: leadership and the ready-gate use "responding right now", but only a
-- genuinely abandoned player loses their seat.
-- ---------------------------------------------------------------------------
create or replace function start_game()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_uid       uuid := auth.uid();
  v_game      uuid;
  v_owner     uuid;
  v_leader    uuid;
  v_ready     integer;
  v_not_ready integer;
  v_seated    integer;
begin
  select g.id, g.owner_user_id into v_game, v_owner
  from games g join players p on p.game_id = g.id
  where p.user_id = v_uid and g.status = 'waiting'
  limit 1;

  if v_game is null then
    raise exception 'No lobby to start';
  end if;

  -- Leader: the master if they are responding, otherwise the earliest-seated
  -- player who is. A frozen or dead phone cannot hold the Start button hostage.
  select user_id into v_leader
  from players
  where game_id = v_game
    and player_is_present(is_connected, last_seen_at)
  order by (user_id = v_owner) desc, seat asc
  limit 1;

  if v_leader is distinct from v_uid then
    raise exception 'Only the leader can start the game';
  end if;

  -- We only wait on the "ready" of people who are actually responding. This is
  -- the fix for the original bug: a ghost's un-pressed ready no longer blocks
  -- everybody else.
  select count(*) filter (where is_ready),
         count(*) filter (where not is_ready)
    into v_ready, v_not_ready
  from players
  where game_id = v_game
    and player_is_present(is_connected, last_seen_at);

  if v_ready < 2 then
    raise exception 'Need at least 2 ready players';
  end if;
  if v_not_ready > 0 then
    raise exception 'Everyone must be ready first';
  end if;

  -- Only the genuinely gone lose their seat. Someone who merely tabbed away or
  -- whose screen locked KEEPS their place — AutoPlay will cover their turns and
  -- they can pick up where they left off. Dropping them here would be permanent,
  -- because there is no way to join a game already in progress.
  delete from players
   where game_id = v_game
     and player_has_abandoned(is_connected, last_seen_at);

  -- Safety net: never start a round that the deletion just emptied out.
  select count(*) into v_seated from players where game_id = v_game;
  if v_seated < 2 then
    raise exception 'Need at least 2 players still in the room';
  end if;

  -- Tidy the seats into 1,2,3… and put every token back to the start.
  with ordered as (
    select id, row_number() over (order by seat) as rn
    from players where game_id = v_game
  )
  update players p set seat = o.rn, position = 0
  from ordered o where p.id = o.id;

  update games
    set status = 'playing',
        current_seat = 1,
        turn_deadline = now() + (turn_seconds || ' seconds')::interval,
        started_at = now()
  where id = v_game;
end;
$$;

grant execute on function player_is_present(boolean, timestamptz) to anon, authenticated;
grant execute on function player_has_abandoned(boolean, timestamptz) to anon, authenticated;
grant execute on function start_game() to anon, authenticated;
