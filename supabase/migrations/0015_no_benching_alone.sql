-- Saap-Sidi — don't bench someone who is playing alone (Layer 2)
--
-- THE BUG I WROTE IN 0014
-- Benching exists for one reason: to stop everyone else waiting on somebody
-- who has wandered off. In a solo game there IS nobody else. The computer is
-- not kept waiting, it does not get bored, and it has nowhere to be.
--
-- But 0014 applied the rule everywhere. So: put your phone down mid-game, let
-- three of your turns roll themselves, and you get benched. That leaves the
-- bot as the only player still in the turn order, which trips the "last one
-- standing takes it" rule — and you come back to "Chotu wins".
--
-- Losing a game you were not playing against anyone, because you looked at a
-- text message, is a rotten thing to happen.
--
-- THE FIX
-- Only count missed turns in shared games. In a solo game the clock can roll
-- for you all day; the game will simply be waiting where you left it.

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
  -- ONLY IN A SHARED GAME. Nobody is kept waiting in a solo game, so there is
  -- nothing to protect anyone from, and benching there would only punish the
  -- one person playing.
  if v_game.mode = 'shared' then
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
  -- If everyone but one has drifted off, the last one standing takes it. Only
  -- ever reachable in a shared game now, which is the only place it made sense.
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

-- Anyone benched in a solo game right now was benched by the old rule.
update players p
   set is_benched = false, auto_misses = 0
  from games g
 where p.game_id = g.id
   and g.mode = 'solo';
