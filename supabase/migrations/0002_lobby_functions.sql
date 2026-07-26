-- Saap-Sidi — Lobby referee actions (Layer 1)
-- These run ON THE SERVER. Phones can only CALL them; they cannot write directly.
-- Each one figures out "who is calling" from their hidden ID (auth.uid()).

-- ---------------------------------------------------------------------------
-- JOIN: enter the shared lobby (also handles reconnecting to a game in progress)
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
begin
  if v_uid is null then
    raise exception 'Not signed in';
  end if;

  -- 1) Already in a game that is not finished? Rejoin it (reconnect).
  select g.id into v_game
  from games g
  join players p on p.game_id = g.id
  where p.user_id = v_uid and g.status <> 'finished'
  order by g.created_at desc
  limit 1;

  if v_game is not null then
    update players
      set is_connected = true, last_seen_at = now(), display_name = v_name
      where game_id = v_game and user_id = v_uid;
    return v_game;
  end if;

  -- 2) Otherwise find an open waiting lobby.
  select id, owner_user_id into v_game, v_owner
  from games where status = 'waiting'
  order by created_at desc limit 1;

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
-- READY: press (or un-press) the ready button in the lobby
-- ---------------------------------------------------------------------------
create or replace function set_ready(p_ready boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  update players p
    set is_ready = p_ready, is_connected = true, last_seen_at = now()
    from games g
    where p.game_id = g.id and p.user_id = v_uid and g.status = 'waiting';
end;
$$;

-- ---------------------------------------------------------------------------
-- HEARTBEAT: a quiet "I'm still here" ping the phone sends every few seconds
-- ---------------------------------------------------------------------------
create or replace function heartbeat()
returns void
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  update players set is_connected = true, last_seen_at = now()
  where user_id = v_uid;
end;
$$;

-- ---------------------------------------------------------------------------
-- LEAVE: mark this phone as gone (sent best-effort when the app closes)
-- ---------------------------------------------------------------------------
create or replace function leave_lobby()
returns void
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  update players set is_connected = false, last_seen_at = now()
  where user_id = v_uid;
end;
$$;

-- ---------------------------------------------------------------------------
-- START: only the leader may start, and only when everyone present is ready
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
  update games
    set status = 'playing',
        current_seat = 1,
        turn_number = 0,
        turn_deadline = now() + (turn_seconds || ' seconds')::interval,
        started_at = now()
  where id = v_game;
end;
$$;

-- Let logged-in phones (including anonymous ones) call these actions.
grant execute on function join_lobby(text) to anon, authenticated;
grant execute on function set_ready(boolean) to anon, authenticated;
grant execute on function heartbeat() to anon, authenticated;
grant execute on function leave_lobby() to anon, authenticated;
grant execute on function start_game() to anon, authenticated;
