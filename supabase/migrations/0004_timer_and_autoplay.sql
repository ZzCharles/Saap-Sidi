-- Saap-Sidi — Turn timer + AutoPlay (Layer 1)
--
-- The idea: every phone watching the game keeps an eye on the clock. When the
-- current player's 20 seconds run out, whichever phone notices first asks the
-- server to roll on their behalf. Thanks to the one-row-per-turn rule, it does
-- not matter if five phones ask at once — only one roll happens.

-- ---------------------------------------------------------------------------
-- The server's own clock. Phones' clocks can be wrong, so they ask for this
-- once and work out the difference. Otherwise a phone with a slow clock would
-- show the wrong countdown.
-- ---------------------------------------------------------------------------
create or replace function server_now()
returns timestamptz
language sql
stable
as $$ select now(); $$;

-- ---------------------------------------------------------------------------
-- AUTOPLAY: roll for the current player, but only if their time really is up.
-- Safe to call as often as you like, by anyone in the game.
-- ---------------------------------------------------------------------------
create or replace function autoplay_if_due(p_game uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_game games;
begin
  if v_uid is null then return; end if;

  -- Only people actually in this game may nudge it along.
  if not exists (
    select 1 from players where game_id = p_game and user_id = v_uid
  ) then
    return;
  end if;

  select * into v_game from games where id = p_game;

  if v_game.id is null or v_game.status <> 'playing' then return; end if;
  if v_game.turn_deadline is null then return; end if;

  -- Not actually out of time yet? Do nothing. The SERVER's clock decides this,
  -- never the phone's — so a phone with a fast clock cannot rush anyone.
  if now() < v_game.turn_deadline then return; end if;

  perform take_turn(p_game, true, v_game.turn_number + 1);
end;
$$;

-- ---------------------------------------------------------------------------
-- Small fix to roll_dice: a duplicate or late tap should quietly do nothing
-- rather than show the player a scary "not your turn" error.
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

  -- Already moved past this turn? Duplicate/late tap — stay quiet.
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

grant execute on function server_now() to anon, authenticated;
grant execute on function autoplay_if_due(uuid) to anon, authenticated;
grant execute on function roll_dice(integer) to anon, authenticated;
