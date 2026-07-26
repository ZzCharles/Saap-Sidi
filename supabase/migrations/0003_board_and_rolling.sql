-- Saap-Sidi — The board map + the dice-rolling referee (Layer 1)

-- ---------------------------------------------------------------------------
-- THE BOARD MAP: where every snake and ladder sits.
-- Kept in the database so the server and every phone read the SAME map.
-- ---------------------------------------------------------------------------
create table if not exists board_jumps (
  from_square integer primary key check (from_square between 2 and 99),
  to_square   integer not null      check (to_square between 1 and 100),
  kind        text not null check (kind in ('snake', 'ladder'))
);

-- The classic layout. Ladders carry you up, snakes drag you down.
insert into board_jumps (from_square, to_square, kind) values
  -- Ladders (up)
  (2, 38, 'ladder'), (4, 14, 'ladder'), (9, 31, 'ladder'), (21, 42, 'ladder'),
  (28, 84, 'ladder'), (36, 44, 'ladder'), (51, 67, 'ladder'), (71, 91, 'ladder'),
  (80, 100, 'ladder'),
  -- Snakes (down)
  (16, 6, 'snake'), (47, 26, 'snake'), (49, 11, 'snake'), (56, 53, 'snake'),
  (62, 19, 'snake'), (64, 60, 'snake'), (87, 24, 'snake'), (93, 73, 'snake'),
  (95, 75, 'snake'), (98, 78, 'snake')
on conflict (from_square) do nothing;

alter table board_jumps enable row level security;
drop policy if exists "read board" on board_jumps;
create policy "read board" on board_jumps for select to anon, authenticated using (true);

-- ---------------------------------------------------------------------------
-- THE CORE OF THE REFEREE: take one turn.
-- Shared by a real tap AND by AutoPlay, so both behave identically.
--
-- p_expected_turn is the turn the caller THINKS is next. If the game has already
-- moved on, we quietly do nothing — that is what makes repeat/simultaneous
-- requests harmless.
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
  v_max_seat   integer;
begin
  -- Hold the game steady while we decide, so two requests can't interleave.
  select * into v_game from games where id = p_game for update;

  if v_game.id is null or v_game.status <> 'playing' then
    return;                                  -- nothing to do
  end if;

  -- Already past this turn? Someone beat us to it. Quietly stop.
  if p_expected_turn is not null and p_expected_turn <> v_game.turn_number + 1 then
    return;
  end if;

  -- Whose turn is it?
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
    -- Snake or ladder on the square you landed on?
    select b.to_square, b.kind into v_to, v_kind
      from board_jumps b where b.from_square = v_landed;
    if v_to is null then
      v_to := v_landed;
      v_kind := 'none';
    end if;
  end if;

  -- *** THE CLAIM ***  Only one row can exist per turn. First writer wins;
  -- a duplicate request lands here, gets rejected, and changes nothing.
  insert into moves (game_id, player_id, turn_number, dice,
                     from_position, to_position, jump_type, was_autoplay)
  values (p_game, v_player.id, v_game.turn_number + 1, v_dice,
          v_from, v_to, v_kind, p_is_autoplay)
  on conflict (game_id, turn_number) do nothing
  returning id into v_move_id;

  if v_move_id is null then
    return;                                  -- lost the race; that's fine
  end if;

  -- Move the token.
  update players set position = v_to where id = v_player.id;

  -- Did they land exactly on 100? Then they win and the game ends.
  if v_to = 100 then
    update games
      set status = 'finished', winner_player_id = v_player.id,
          turn_number = v_game.turn_number + 1,
          current_seat = null, turn_deadline = null, finished_at = now()
      where id = p_game;
    return;
  end if;

  -- Otherwise hand the turn to the next seat and restart the clock.
  select max(seat) into v_max_seat from players where game_id = p_game;
  v_next_seat := case when v_game.current_seat >= v_max_seat
                      then 1 else v_game.current_seat + 1 end;

  update games
    set turn_number   = v_game.turn_number + 1,
        current_seat  = v_next_seat,
        turn_deadline = now() + (v_game.turn_seconds || ' seconds')::interval
    where id = p_game;
end;
$$;

-- ---------------------------------------------------------------------------
-- WHAT THE PHONE CALLS when you tap "Roll".
-- It only checks that it really is your turn, then hands over to the referee.
-- ---------------------------------------------------------------------------
create or replace function roll_dice(p_expected_turn integer default null)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_game games;
  v_seat integer;
begin
  if v_uid is null then raise exception 'Not signed in'; end if;

  select g.* into v_game
  from games g join players p on p.game_id = g.id
  where p.user_id = v_uid and g.status = 'playing'
  limit 1;

  if v_game.id is null then raise exception 'You are not in a running game'; end if;

  -- A duplicate or late tap (the game already moved past that turn)? Quietly
  -- do nothing, so a double-tap never shows the player a scary error.
  if p_expected_turn is not null and p_expected_turn <> v_game.turn_number + 1 then
    return;
  end if;

  select seat into v_seat from players
    where game_id = v_game.id and user_id = v_uid;

  if v_seat is distinct from v_game.current_seat then
    raise exception 'It is not your turn';
  end if;

  perform take_turn(v_game.id, false, coalesce(p_expected_turn, v_game.turn_number + 1));
end;
$$;

grant execute on function roll_dice(integer) to anon, authenticated;
-- take_turn is internal: phones must go through roll_dice (or autoplay later).
revoke all on function take_turn(uuid, boolean, integer) from anon, authenticated;
