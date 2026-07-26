-- Saap-Sidi — "Play again" (Layer 1)
--
-- The idea: when someone wins, we do NOT throw the room away. We put the SAME
-- room back to 'waiting'. Because every phone is already watching that room,
-- all of them flip back to the lobby by themselves — nobody reloads, nobody
-- gets separated into a different room, and the master stays the master.
--
-- Note we deliberately do NOT reset turn_number. It just keeps counting up
-- across rounds. That keeps the one-row-per-turn rule (the thing that makes
-- AutoPlay safe) intact, and it means we never delete the game history.

-- ---------------------------------------------------------------------------
-- 1) A new marker: when did this room's lobby last open?
--
-- Until now, "which room should I join?" was answered with "the newest one".
-- That breaks the moment we revive an older room, because a leftover room
-- would look newer and quietly steal new arrivals into an empty lobby.
-- So each room now records when its lobby last opened, and we join by that.
-- ---------------------------------------------------------------------------
alter table games add column if not exists lobby_opened_at timestamptz;

-- Existing rows: treat the moment they were created as the moment they opened.
update games set lobby_opened_at = created_at where lobby_opened_at is null;

alter table games alter column lobby_opened_at set default now();
alter table games alter column lobby_opened_at set not null;

-- ---------------------------------------------------------------------------
-- 2) PLAY AGAIN: put a finished room back to the lobby.
--
-- Anyone who was in the game may press it — it is not leader-only, because
-- making everyone wait for one person is annoying. The leader still controls
-- the actual Start, so nobody can rush the group into a round.
--
-- Pressing it twice, or two people pressing at once, is harmless: the second
-- one finds the room already reset and quietly does nothing.
-- ---------------------------------------------------------------------------
create or replace function play_again()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_game uuid;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;

  -- The caller's finished room.
  select g.id into v_game
  from games g
  join players p on p.game_id = g.id
  where p.user_id = v_uid and g.status = 'finished'
  order by g.finished_at desc nulls last
  limit 1;

  if v_game is null then
    return;                    -- nothing to reset (or someone already did it)
  end if;

  -- Hold the room steady, then look again: if another phone reset it while we
  -- were waiting, we stop here rather than wiping a round that has restarted.
  perform 1 from games where id = v_game for update;

  if not exists (select 1 from games where id = v_game and status = 'finished') then
    return;
  end if;

  -- Back to the lobby. Seats, names and the master all stay as they were.
  update games
     set status           = 'waiting',
         current_seat     = null,
         turn_deadline    = null,
         winner_player_id = null,
         started_at       = null,
         finished_at      = null,
         lobby_opened_at  = now()
   where id = v_game;

  -- Everyone back to the start, and everyone has to press "ready" again.
  update players
     set position = 0, is_ready = false
   where game_id = v_game;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3) JOIN: same as before, with two fixes that go with the above.
--
--   a) Reloading on the winner screen used to eject you into a brand-new empty
--      room. Now a room that finished RECENTLY still counts as your room, so a
--      reload puts you back with your friends and the Play again button.
--
--   b) Rooms are now found by "most recently opened lobby", not "newest room",
--      so a revived room is correctly the current one.
--
-- The 2-hour window is the safety valve: an abandoned room eventually stops
-- claiming people, so you can never be trapped in a dead room forever.
-- ---------------------------------------------------------------------------
create or replace function join_lobby(p_display_name text)
returns uuid                       -- gives back the game's id
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_game   uuid;
  v_owner  uuid;
  v_seat   integer;
  v_name   text := coalesce(nullif(trim(p_display_name), ''), 'Player');
  v_recent interval := interval '2 hours';
begin
  if v_uid is null then
    raise exception 'Not signed in';
  end if;

  -- 1) Already in a room that is still alive? Go back to it (reconnect).
  --    "Alive" = waiting, playing, or finished within the last couple of hours.
  select g.id into v_game
  from games g
  join players p on p.game_id = g.id
  where p.user_id = v_uid
    and (g.status <> 'finished' or g.finished_at > now() - v_recent)
  order by (g.status = 'finished'), g.lobby_opened_at desc
  limit 1;

  if v_game is not null then
    update players
      set is_connected = true, last_seen_at = now(), display_name = v_name
      where game_id = v_game and user_id = v_uid;
    return v_game;
  end if;

  -- 2) Otherwise find the room everyone else is in. A just-finished room counts
  --    too, so someone arriving right after a win lands with the group and sees
  --    the same Play again button instead of opening a room of their own.
  select id, owner_user_id into v_game, v_owner
  from games
  where status = 'waiting'
     or (status = 'finished' and finished_at > now() - v_recent)
  order by (status = 'finished'), lobby_opened_at desc
  limit 1;

  -- 3) None exists? Create one; the first person becomes the master.
  if v_game is null then
    insert into games (status, owner_user_id)
    values ('waiting', v_uid)
    returning id, owner_user_id into v_game, v_owner;
  end if;

  if v_owner is null then
    update games set owner_user_id = v_uid where id = v_game;
    v_owner := v_uid;
  end if;

  -- Take the next free seat and sit down. The table seats 8.
  select coalesce(max(seat), 0) + 1 into v_seat
  from players where game_id = v_game;

  if v_seat > 8 then
    raise exception 'This game is full (8 players maximum)';
  end if;

  insert into players (game_id, user_id, display_name, seat, is_connected, is_master)
  values (v_game, v_uid, v_name, v_seat, true, v_uid = v_owner)
  on conflict (game_id, user_id) do update
    set is_connected = true, last_seen_at = now(), display_name = v_name;

  return v_game;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4) START: unchanged rules, but it now also stamps the lobby marker, so the
--    room's "last opened" time stays honest across rounds.
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
  -- player who is still connected.
  select user_id into v_leader
  from players
  where game_id = v_game and is_connected = true
  order by (user_id = v_owner) desc, seat asc
  limit 1;

  if v_leader is distinct from v_uid then
    raise exception 'Only the leader can start the game';
  end if;

  -- Need at least 2 people, and everyone present must be ready.
  select count(*) filter (where is_ready),
         count(*) filter (where not is_ready)
    into v_ready, v_not_ready
  from players where game_id = v_game and is_connected = true;

  if v_ready < 2 then
    raise exception 'Need at least 2 ready players';
  end if;
  if v_not_ready > 0 then
    raise exception 'Everyone must be ready first';
  end if;

  -- Anyone not connected right now doesn't make it into the game.
  delete from players where game_id = v_game and is_connected = false;

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

grant execute on function play_again() to anon, authenticated;
grant execute on function join_lobby(text) to anon, authenticated;
grant execute on function start_game() to anon, authenticated;
