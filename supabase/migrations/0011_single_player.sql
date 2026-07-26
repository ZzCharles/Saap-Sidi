-- Saap-Sidi — Single player (Layer 2)
--
-- The goal: you should never need a second person to play. Open the app, tap
-- "Single player", and you are immediately in a game against one computer
-- opponent. No lobby, no ready button, no waiting.
--
-- THE TRICK: we do not write a second kind of game. A computer opponent is
-- just an ordinary player row that happens to have no phone attached, and its
-- turns are taken by the AutoPlay machinery we already built and tested — the
-- same code that covers a friend whose timer runs out. So single player rides
-- on proven rules, and the referee still decides every dice roll. You cannot
-- cheat the computer any more than you can cheat your friends.
--
-- ONE RULE THAT KEEPS THIS SIMPLE: a person is only ever in ONE game at a
-- time. Starting a solo game takes you out of the shared lobby; joining the
-- shared lobby ends your solo game. Without this, every "find my game" lookup
-- in the app would suddenly have two answers and pick one at random.

-- ---------------------------------------------------------------------------
-- 1) Two new facts to record.
-- ---------------------------------------------------------------------------

-- Is this the friends' room, or somebody's private game against the computer?
alter table games add column if not exists mode text not null default 'shared';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'games_mode_check'
  ) then
    alter table games add constraint games_mode_check
      check (mode in ('shared', 'solo'));
  end if;
end $$;

-- Is this seat a computer opponent rather than a person?
alter table players add column if not exists is_bot boolean not null default false;

-- ---------------------------------------------------------------------------
-- 2) START A SOLO GAME.
--
-- Returns the new game's id. Safe to call twice — the second call simply
-- retires the first game and deals a fresh one.
-- ---------------------------------------------------------------------------
create or replace function start_solo_game(
  p_display_name text,
  p_bot_name     text default 'Chotu'
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_game     uuid;
  v_name     text := coalesce(nullif(trim(p_display_name), ''), 'Player');
  v_bot_name text := coalesce(nullif(trim(p_bot_name), ''), 'Chotu');
begin
  if v_uid is null then raise exception 'Not signed in'; end if;

  -- Leave the friends' room, if we were sitting in one. Standing up from a
  -- lobby is free; a game already in progress we simply stop occupying.
  delete from players p
   using games g
   where p.game_id = g.id
     and p.user_id = v_uid
     and g.mode = 'shared'
     and g.status = 'waiting';

  -- Close any earlier solo game of ours, so only one is ever live.
  update games set status = 'finished', finished_at = now()
   where mode = 'solo'
     and status <> 'finished'
     and owner_user_id = v_uid;

  -- Deal a fresh one. It starts PLAYING straight away — there is nobody to
  -- wait for, so a lobby and a ready button would just be a door to walk
  -- through on the way to the same place.
  insert into games (status, mode, owner_user_id, current_seat,
                     started_at, lobby_opened_at)
  values ('playing', 'solo', v_uid, 1, now(), now())
  returning id into v_game;

  -- Seat 1: you. You always go first — losing the race before you have rolled
  -- once would be a miserable way to open a game.
  insert into players (game_id, user_id, display_name, seat, is_connected, is_master)
  values (v_game, v_uid, v_name, 1, true, true);

  -- Seat 2: the computer. It gets its own made-up identity so that every rule
  -- written for a person applies to it unchanged.
  insert into players (game_id, user_id, display_name, seat, is_connected, is_bot)
  values (v_game, gen_random_uuid(), v_bot_name, 2, true, true);

  -- Start your clock.
  update games
     set turn_deadline = now() + (turn_seconds || ' seconds')::interval
   where id = v_game;

  return v_game;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3) THE COMPUTER'S TURN.
--
-- Your phone calls this after a short pause, so the opponent appears to think
-- for a moment rather than answering instantly.
--
-- It can only ever act when it is genuinely a computer's turn, so there is no
-- way to use it to steal a roll — not your own, and not a friend's. If it is
-- not the computer's turn, it quietly does nothing.
-- ---------------------------------------------------------------------------
create or replace function play_bot_turn(p_game uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_game games;
begin
  if v_uid is null then return; end if;

  -- Only someone actually in this game may nudge it along.
  if not exists (
    select 1 from players where game_id = p_game and user_id = v_uid
  ) then
    return;
  end if;

  select * into v_game from games where id = p_game;
  if v_game.id is null or v_game.status <> 'playing' then return; end if;

  -- THE GUARD: the seat whose turn it is must belong to a computer.
  if not exists (
    select 1 from players
     where game_id = p_game
       and seat = v_game.current_seat
       and is_bot
  ) then
    return;
  end if;

  -- Recorded as an automatic move, because that is exactly what it is.
  perform take_turn(p_game, true, v_game.turn_number + 1);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4) ROLLING, BUT SAYING WHICH GAME.
--
-- The old roll_dice found "the running game this person is in" and assumed
-- there was only one. That assumption is the thing single player breaks, so
-- this version is told the game outright. The old one still works and is left
-- alone; the app now uses this.
-- ---------------------------------------------------------------------------
create or replace function roll_in_game(p_game uuid, p_expected_turn integer default null)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_game games;
  v_seat integer;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;

  select * into v_game from games where id = p_game and status = 'playing';
  if v_game.id is null then raise exception 'That game is not running'; end if;

  select seat into v_seat from players
   where game_id = p_game and user_id = v_uid;

  if v_seat is null then raise exception 'You are not in that game'; end if;

  -- A duplicate or late tap: the game has already moved on. Stay quiet rather
  -- than showing a scary error for something harmless.
  if p_expected_turn is not null and p_expected_turn <> v_game.turn_number + 1 then
    return;
  end if;

  if v_seat is distinct from v_game.current_seat then
    raise exception 'It is not your turn';
  end if;

  perform take_turn(p_game, false, coalesce(p_expected_turn, v_game.turn_number + 1));
end;
$$;

-- ---------------------------------------------------------------------------
-- 5) JOINING THE FRIENDS' ROOM — now says which room it means.
--
-- Same as before in every way, except it ignores solo games completely. This
-- matters: without it, your private game would look like "a room you are
-- already in" and quietly swallow you every time you tried to join friends.
-- ---------------------------------------------------------------------------
create or replace function join_lobby(p_display_name text)
returns uuid
language plpgsql security definer set search_path = public
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

  -- Coming to play with friends means the solo game is over.
  update games set status = 'finished', finished_at = now()
   where mode = 'solo'
     and status <> 'finished'
     and owner_user_id = v_uid;

  -- 1) Already in a SHARED room that is still alive? Go back to it (reconnect).
  select g.id into v_game
  from games g
  join players p on p.game_id = g.id
  where p.user_id = v_uid
    and g.mode = 'shared'
    and (g.status <> 'finished' or g.finished_at > now() - v_recent)
  order by (g.status = 'finished'), g.lobby_opened_at desc
  limit 1;

  if v_game is not null then
    update players
      set is_connected = true, last_seen_at = now(), display_name = v_name
      where game_id = v_game and user_id = v_uid;
    return v_game;
  end if;

  -- 2) Otherwise find the room everyone else is in.
  select id, owner_user_id into v_game, v_owner
  from games
  where mode = 'shared'
    and (status = 'waiting'
         or (status = 'finished' and finished_at > now() - v_recent))
  order by (status = 'finished'), lobby_opened_at desc
  limit 1;

  -- 3) None exists? Create one; the first person becomes the master.
  if v_game is null then
    insert into games (status, mode, owner_user_id)
    values ('waiting', 'shared', v_uid)
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
-- 6) PLAY AGAIN — now knows the difference between the two kinds of game.
--
-- With friends: back to the lobby, so everyone can re-ready and the group
-- decides together when to go.
--
-- Alone: straight into a new round. Sending one person to a lobby to press
-- "ready" at nobody is a door to nowhere.
-- ---------------------------------------------------------------------------
create or replace function play_again()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_game games;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;

  select g.* into v_game
  from games g
  join players p on p.game_id = g.id
  where p.user_id = v_uid and g.status = 'finished'
  order by g.finished_at desc nulls last
  limit 1;

  if v_game.id is null then
    return;                    -- nothing to reset (or someone already did it)
  end if;

  -- Hold the room steady, then look again: if another phone reset it while we
  -- were waiting, stop rather than wiping a round that has already restarted.
  perform 1 from games where id = v_game.id for update;

  if not exists (select 1 from games where id = v_game.id and status = 'finished') then
    return;
  end if;

  if v_game.mode = 'solo' then
    update games
       set status           = 'playing',
           current_seat     = 1,
           winner_player_id = null,
           started_at       = now(),
           finished_at      = null,
           lobby_opened_at  = now(),
           turn_deadline    = now() + (turn_seconds || ' seconds')::interval
     where id = v_game.id;

    update players set position = 0, is_ready = true where game_id = v_game.id;
  else
    update games
       set status           = 'waiting',
           current_seat     = null,
           turn_deadline    = null,
           winner_player_id = null,
           started_at       = null,
           finished_at      = null,
           lobby_opened_at  = now()
     where id = v_game.id;

    update players set position = 0, is_ready = false where game_id = v_game.id;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7) Permissions. Same as everything else: phones may ASK, the referee decides.
-- ---------------------------------------------------------------------------
grant execute on function start_solo_game(text, text) to anon, authenticated;
grant execute on function play_bot_turn(uuid)         to anon, authenticated;
grant execute on function roll_in_game(uuid, integer) to anon, authenticated;
grant execute on function join_lobby(text)            to anon, authenticated;
grant execute on function play_again()                to anon, authenticated;
