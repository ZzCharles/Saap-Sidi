-- Saap-Sidi — Mark silent players as "away" automatically
--
-- THE PROBLEM
-- Until now the only thing that marked a player as gone was leave_lobby(), which
-- the phone sends as it closes the tab. Phones very often never manage to send it
-- — the battery dies, the signal drops, the app gets swiped away. That player then
-- stays listed as PRESENT forever.
--
-- That is not cosmetic. start_game() insists that every present player is ready,
-- so a single ghost who can never press "ready" blocks the Start button for
-- everybody, with no way to clear them from inside the app.
--
-- THE FIX
-- Every phone already pings the server every 5 seconds (heartbeat), and that ping
-- is recorded in players.last_seen_at. We were writing it but never reading it.
-- From now on, "present" means: says it is connected AND has pinged recently.
--
-- WHY 30 SECONDS
-- That is six missed pings. Long enough to ride out a brief blip in signal (we do
-- not want to eject someone whose train went through a tunnel), short enough that
-- a genuinely dead phone clears itself before anyone gets impatient.

-- ---------------------------------------------------------------------------
-- One definition of "present", used everywhere, so the rule cannot drift apart
-- in different places.
--
-- NOTE: game.js has to know this rule too, so the lobby you see matches what the
-- server believes. The same 30 seconds is written there as AWAY_AFTER_MS. If you
-- ever change one, change the other.
-- ---------------------------------------------------------------------------
create or replace function player_is_present(p_is_connected boolean, p_last_seen timestamptz)
returns boolean
language sql
stable                              -- depends on now(), so not immutable
set search_path = public
as $$
  select coalesce(p_is_connected, false)
     and p_last_seen > now() - interval '30 seconds';
$$;

-- ---------------------------------------------------------------------------
-- START: same rules as before, but "present" now means "actually still here",
-- not merely "never said goodbye".
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
begin
  -- Find the caller's waiting lobby.
  select g.id, g.owner_user_id into v_game, v_owner
  from games g join players p on p.game_id = g.id
  where p.user_id = v_uid and g.status = 'waiting'
  limit 1;

  if v_game is null then
    raise exception 'No lobby to start';
  end if;

  -- Work out the leader: the master if present, otherwise the earliest-seated
  -- player who is still here. A ghost can no longer hold the Start button
  -- hostage, because a ghost is no longer "present".
  select user_id into v_leader
  from players
  where game_id = v_game
    and player_is_present(is_connected, last_seen_at)
  order by (user_id = v_owner) desc, seat asc
  limit 1;

  if v_leader is distinct from v_uid then
    raise exception 'Only the leader can start the game';
  end if;

  -- Need at least 2 people here, and everyone here must be ready.
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

  -- Anyone not actually here right now doesn't make it into the game. This is
  -- what finally clears out ghosts: they are dropped when the round begins.
  delete from players
   where game_id = v_game
     and not player_is_present(is_connected, last_seen_at);

  -- Tidy the seats into 1,2,3… and put every token back to the start.
  with ordered as (
    select id, row_number() over (order by seat) as rn
    from players where game_id = v_game
  )
  update players p set seat = o.rn, position = 0
  from ordered o where p.id = o.id;

  -- Kick off: it's seat 1's turn, and their 20-second clock starts now.
  -- started_at also acts as the line between rounds: the phones ignore any move
  -- recorded before it, so a new round never shows the last round's news.
  update games
    set status = 'playing',
        current_seat = 1,
        turn_deadline = now() + (turn_seconds || ' seconds')::interval,
        started_at = now()
  where id = v_game;
end;
$$;

-- ---------------------------------------------------------------------------
-- HEARTBEAT: unchanged in spirit, but now only touches games that are still
-- going. Previously it stamped EVERY row belonging to this player, including
-- ones in old finished rooms, which would have quietly kept ghosts of you
-- looking "present" in games that ended days ago.
-- ---------------------------------------------------------------------------
create or replace function heartbeat()
returns void
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  update players p
     set is_connected = true, last_seen_at = now()
    from games g
   where p.game_id = g.id
     and p.user_id = v_uid
     and g.status <> 'finished';
end;
$$;

grant execute on function player_is_present(boolean, timestamptz) to anon, authenticated;
grant execute on function start_game() to anon, authenticated;
grant execute on function heartbeat() to anon, authenticated;
