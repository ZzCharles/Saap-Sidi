-- Saap-Sidi — benched, not removed (Layer 2)
--
-- THE PROBLEM
-- Someone goes quiet mid-game. Until now the game kept politely rolling for
-- them for five whole minutes, which is a lot of dead air for everyone else.
--
-- THE OBVIOUS FIX IS A TRAP
-- "Remove them after two minutes" sounds right, but there is no way to join a
-- game already in progress, so removal is permanent for that round. And phones
-- stop pinging within about a minute of the app going into the background — so
-- a friend answering a text looks exactly like a friend who has left. Two
-- minutes would routinely delete people who are sitting right there.
--
-- WHAT THIS DOES INSTEAD
-- After THREE of your own turns have been rolled for you, you drop out of the
-- turn order. The game stops waiting and runs at full speed. Your seat and your
-- token stay exactly where they are, and the moment your phone speaks again you
-- walk straight back in.
--
-- WHY COUNT TURNS AND NOT MINUTES
-- Turns are 15 seconds, so two minutes is four of your own turns in a duel but
-- only one in a room of eight. A clock punishes small games and barely touches
-- big ones. Counting your own missed turns is fair at every size.
--
-- THE ONE THAT WOULD HAVE BROKEN EVERYTHING
-- The computer opponent has no phone, so it never pings and every one of its
-- turns is an automatic one. A naive version of this rule benches Chotu after
-- three turns and ends every single player game. Bots are exempt throughout.

-- ---------------------------------------------------------------------------
-- 1) Two new facts per seat.
-- ---------------------------------------------------------------------------

-- Out of the turn order, but still in the game.
alter table players add column if not exists is_benched boolean not null default false;

-- How many of this player's own turns have been rolled for them in a row.
-- Any real tap puts it back to zero.
alter table players add column if not exists auto_misses integer not null default 0;

-- ---------------------------------------------------------------------------
-- 2) How many missed turns before benching. One definition, so the rule can
--    never drift apart between the places that use it.
-- ---------------------------------------------------------------------------
create or replace function bench_after()
returns integer language sql immutable as $$ select 3; $$;

-- ---------------------------------------------------------------------------
-- 3) THE REFEREE, updated.
--
-- Two changes: it now keeps score of who is drifting off, and it skips benched
-- seats when handing on the turn.
-- ---------------------------------------------------------------------------
create or replace function take_turn(p_game uuid, p_is_autoplay boolean, p_expected_turn integer)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_game       games;
  v_player     players;
  v_dice       integer;
  v_from       integer;
  v_landed     integer;
  v_to         integer;
  v_kind       text;
  v_move_id    uuid;
  v_next_seat  integer;
  v_active     integer;
  v_last       uuid;
begin
  select * into v_game from games where id = p_game for update;

  if v_game.id is null or v_game.status <> 'playing' then
    return;
  end if;

  if p_expected_turn is not null and p_expected_turn <> v_game.turn_number + 1 then
    return;
  end if;

  select * into v_player from players
    where game_id = p_game and seat = v_game.current_seat;
  if v_player.id is null then
    return;
  end if;

  -- Roll the dice ON THE SERVER. The phone never decides this.
  v_dice := 1 + floor(random() * 6)::int;

  v_from   := v_player.position;
  v_landed := v_from + v_dice;
  v_kind   := 'none';

  if v_landed > 100 then
    v_to := v_from;                          -- overshoot: you don't move
  else
    v_to := v_landed;
    select b.to_square, b.kind into v_to, v_kind
      from board_jumps b where b.from_square = v_landed;
    if v_to is null then
      v_to := v_landed;
      v_kind := 'none';
    end if;
  end if;

  -- *** THE CLAIM *** Only one row can ever exist per turn.
  insert into moves (game_id, player_id, turn_number, dice,
                     from_position, to_position, jump_type, was_autoplay)
  values (p_game, v_player.id, v_game.turn_number + 1, v_dice,
          v_from, v_to, v_kind, p_is_autoplay)
  on conflict (game_id, turn_number) do nothing
  returning id into v_move_id;

  if v_move_id is null then
    return;                                  -- lost the race; that's fine
  end if;

  update players set position = v_to where id = v_player.id;

  -- --- keeping score of who is drifting off -------------------------------
  -- A real tap always clears the count and brings you back off the bench.
  -- An automatic roll counts against you, unless you are the computer, which
  -- is *supposed* to be played for.
  if p_is_autoplay and not v_player.is_bot then
    update players
       set auto_misses = auto_misses + 1,
           is_benched  = (auto_misses + 1) >= bench_after()
     where id = v_player.id;
  elsif not p_is_autoplay then
    update players
       set auto_misses = 0, is_benched = false
     where id = v_player.id;
  end if;

  -- Did they land exactly on 100? Then they win and the game ends.
  if v_to = 100 then
    update games
      set status = 'finished', winner_player_id = v_player.id,
          turn_number = v_game.turn_number + 1,
          current_seat = null, turn_deadline = null, finished_at = now()
      where id = p_game;
    return;
  end if;

  -- --- is there still a game left to play? --------------------------------
  -- If everyone but one has drifted off, the last one standing takes it. This
  -- is better than letting a lone player roll on to 100 by themselves, and it
  -- stops a room quietly rolling forever with nobody watching.
  select count(*) into v_active
    from players where game_id = p_game and not is_benched;

  if v_active <= 1 then
    select id into v_last
      from players where game_id = p_game and not is_benched
      limit 1;

    update games
      set status = 'finished', winner_player_id = v_last,
          turn_number = v_game.turn_number + 1,
          current_seat = null, turn_deadline = null, finished_at = now()
      where id = p_game;
    return;
  end if;

  -- --- hand on the turn, stepping over benched seats ----------------------
  -- Walk forward from the current seat, wrapping round, until we find someone
  -- still in the turn order. We know at least two exist, so this always lands.
  select p.seat into v_next_seat
    from players p
   where p.game_id = p_game
     and not p.is_benched
     and p.seat > v_game.current_seat
   order by p.seat
   limit 1;

  if v_next_seat is null then                -- wrapped past the last seat
    select p.seat into v_next_seat
      from players p
     where p.game_id = p_game
       and not p.is_benched
     order by p.seat
     limit 1;
  end if;

  update games
    set turn_number   = v_game.turn_number + 1,
        current_seat  = v_next_seat,
        turn_deadline = now() + (v_game.turn_seconds || ' seconds')::interval
    where id = p_game;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4) HEARTBEAT — now also the way back in.
--
-- Every phone says hello every few seconds. That signal is the most honest
-- evidence we have that a person is actually there, so it is what takes them
-- off the bench. No button to press: come back and you are simply back.
--
-- It also clears out the lobby. In a lobby nothing is at stake — anyone
-- dropped rejoins with a single tap — so two minutes of silence is plenty, and
-- it keeps the room honest about who is really waiting. This only ever touches
-- lobbies of shared games, never a game in progress and never a solo game.
-- ---------------------------------------------------------------------------
create or replace function heartbeat()
returns void
language plpgsql security definer set search_path = public
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then return; end if;

  update players p
     set is_connected = true,
         last_seen_at = now(),
         -- Back off the bench, and the count starts again from clean.
         is_benched   = false,
         auto_misses  = 0
    from games g
   where p.game_id = g.id
     and p.user_id = v_uid
     and g.status <> 'finished';

  -- Tidy the lobby: two minutes of silence and your chair goes back.
  delete from players p
   using games g
   where p.game_id = g.id
     and g.mode = 'shared'
     and g.status = 'waiting'
     and not p.is_bot
     and p.last_seen_at < now() - interval '2 minutes';
end;
$$;

-- ---------------------------------------------------------------------------
-- 5) A fresh round starts everyone off the bench.
--
-- play_again puts positions and readiness back; the bench has to go back too,
-- or someone who drifted off in the last round would start the next one
-- already excluded from it.
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

  if v_game.id is null then return; end if;

  perform 1 from games where id = v_game.id for update;

  if not exists (select 1 from games where id = v_game.id and status = 'finished') then
    return;
  end if;

  if v_game.mode = 'solo' then
    update games
       set status = 'playing', current_seat = 1, winner_player_id = null,
           started_at = now(), finished_at = null, lobby_opened_at = now(),
           turn_deadline = now() + (turn_seconds || ' seconds')::interval
     where id = v_game.id;

    update players
       set position = 0, is_ready = true, is_benched = false, auto_misses = 0
     where game_id = v_game.id;
  else
    update games
       set status = 'waiting', current_seat = null, turn_deadline = null,
           winner_player_id = null, started_at = null, finished_at = null,
           lobby_opened_at = now()
     where id = v_game.id;

    update players
       set position = 0, is_ready = false, is_benched = false, auto_misses = 0
     where game_id = v_game.id;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6) Starting a solo game must also start it un-benched, for the same reason.
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

  delete from players p
   using games g
   where p.game_id = g.id and p.user_id = v_uid
     and g.mode = 'shared' and g.status = 'waiting';

  update games set status = 'finished', finished_at = now()
   where mode = 'solo' and status <> 'finished' and owner_user_id = v_uid;

  insert into games (status, mode, owner_user_id, current_seat,
                     started_at, lobby_opened_at)
  values ('playing', 'solo', v_uid, 1, now(), now())
  returning id into v_game;

  insert into players (game_id, user_id, display_name, seat,
                       is_connected, is_master, is_ready)
  values (v_game, v_uid, v_name, 1, true, true, true);

  insert into players (game_id, user_id, display_name, seat,
                       is_connected, is_bot, is_ready)
  values (v_game, gen_random_uuid(), v_bot_name, 2, true, true, true);

  update games
     set turn_deadline = now() + (turn_seconds || ' seconds')::interval
   where id = v_game;

  return v_game;
end;
$$;

grant execute on function bench_after()               to anon, authenticated;
grant execute on function heartbeat()                 to anon, authenticated;
grant execute on function play_again()                to anon, authenticated;
grant execute on function start_solo_game(text, text) to anon, authenticated;

-- Anyone benched right now is there from before this rule existed. Start clean.
update players set is_benched = false, auto_misses = 0;
