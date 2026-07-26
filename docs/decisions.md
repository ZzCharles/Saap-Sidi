# Saap-Sidi — Decisions & Plain-Language Notes

A running log of what we've decided and why, in plain language.

## Core architecture
- **The phone only displays; the server decides.** Dice rolls, whose turn it is, and whether a move is legal are all decided by the server. This stops cheating and keeps everyone in sync.
- **Backend:** Supabase (database + realtime updates + login). Same as the prior roulette app.
- **Phone side:** a plain website — three files (`index.html`, `style.css`, `game.js`), no React, no build tools. Hosted free on GitHub Pages.

## Layer 1 scope (build this first, nothing more)
- 2–8 players; one shared lobby (see "Lobby model" below) with a "ready" button
- Turn-based play with an automatic turn timer (20 seconds per turn)
- Server-side dice roll; move one token; snakes down, ladders up
- First to **exactly 100** wins (overshooting doesn't move you)
- Real-time sync of the board and whose turn it is
- Reconnect: rejoin and the game is exactly where you left it
- AutoPlay: if the timer runs out, the server rolls for you (built the same
  safe, idempotent way as the roulette "spin" so it works no matter who is connected)

## Lobby model (Layer 1)
- **One shared lobby.** Everyone who has the app (PWA) and opens it joins the same
  room. No join codes or multiple rooms yet — kept as a future possibility.
- **The "leader" (who holds the Start button) is decided automatically:**
  - If the master (the owner's phone) is in the lobby, the master always leads.
  - Otherwise, the earliest-joined player still connected leads.
  - If the leader disconnects before the game starts, leadership passes to the next
    earliest-joined connected player (or snaps back to the master if present).
  - After the game starts, leadership is irrelevant; play follows turn order.
- **Identity:** each phone gets a hidden anonymous ID automatically (no passwords,
  no sign-up). The owner's phone is marked as master.

## Explicitly NOT yet
Jungle art, animations, wildlife, weather, music, profile photos, emoji reactions,
victory spectacle. Layer 1 is plain shapes and colors.

### Later pipeline (planned, not now)
- Player **pictures** on their tokens.
- **Exaggerated, funny animations** (swallowing, climbing, etc.).
- Create/join **multiple lobbies via unique codes**.

## Log
- Project skeleton created (folders + starter files).
- Turn timer set to 20s. Max players raised to 8. Single shared lobby with
  auto-assigned leadership (master overrides). App will be an installable PWA.
- Auth: start with seamless automatic anonymous ID; keep master-only login as an
  easy fallback (friends never need to log in either way).
- Database blueprint written (three notebooks + read-only phones + one-row-per-turn
  rule). INSTALLED onto the Saap-Sidi Supabase project successfully.
- Referee logic will live INSIDE the database as server functions (installed by the
  same copy-paste flow) — no CLI / build tools needed. Chosen for simplicity.
- Frontend connected to Supabase (public URL + anon key in frontend/config.js).
  Anonymous sign-in working — "Connected ✓" plumbing test passed in local preview
  (Python http.server on port 5500, launched via .claude/launch.json).
- Lobby built: frontend (name screen, live player list, ready/start buttons) +
  server actions (join_lobby, set_ready, heartbeat, leave_lobby, start_game).
- Lobby TESTED live end-to-end: join, real-time appearance of a 2nd player,
  ready toggles, leader-only Start (gated on >=2 all-ready), Start -> 'playing'.
  All passed, no errors.
- Board + dice referee built and installed: board_jumps map (9 ladders, 10 snakes),
  take_turn (internal core), roll_dice (what the phone calls).
- Dev server replaced with serve.py (threaded + no-cache) and index.html now loads
  game.js/style.css with a timestamp, because the browser was stubbornly serving
  stale code and it looked like a bug.
- FULL GAME TESTED to a win (59 turns). Verified: 5 ladders, 5 snakes, 11
  overshoot-no-move events, win on exactly 100, correct turn alternation,
  status -> finished with winner recorded.
- ANTI-CHEAT VERIFIED: rolling out of turn refused ("It is not your turn");
  a phone writing position=99 directly was refused (no rows changed).
- IDEMPOTENCY VERIFIED: 5 simultaneous rolls for turn 1 produced exactly 1 move
  and advanced the turn once. A stale request changed nothing.
- Timer + AutoPlay built and installed: server_now() (so phones can correct their
  own clock drift), autoplay_if_due(game). Every phone ticks 4x/sec, draws a
  shrinking bar, and nudges the server once the deadline passes; the one-row-per-turn
  rule means only one roll ever lands. TESTED: nobody rolled, server rolled a 5
  after 20s, turn passed, next clock started. Shown as "⏱ Time up — rolled X for Y".
- RECONNECT VERIFIED: reloaded mid-game and returned to the exact same state
  (positions, whose turn, remaining seconds).
- Fixed: join_lobby now enforces the 8-player maximum (it previously had no cap,
  which contradicted the 2–8 spec).
- PLAY AGAIN built (0005). When someone wins, the room is REVIVED rather than
  thrown away: play_again() puts the same room back to 'waiting', tokens to the
  start, ready flags cleared, seats/names/master untouched. Every phone is already
  watching that room, so they all return to the lobby by themselves — no reload,
  nobody scattered into a separate room. Anyone in the game may press it (not
  leader-only, so the group never waits on one person); the leader still controls
  Start. Two presses at once are harmless — the second finds it already reset.
- Decided: turn_number is NOT reset between rounds; it keeps counting up. Resetting
  it would collide with the one-row-per-turn rule (the thing that makes AutoPlay
  safe) and would force us to delete the game history. Instead games.started_at is
  the line between rounds — phones ignore any move recorded before it, so a fresh
  round never shows the previous round's news.
- Fixed alongside it: rooms were found by "newest room wins", which breaks the
  moment an older room is revived (a leftover test room would look newer and steal
  new arrivals into an empty lobby). Added games.lobby_opened_at — rooms are now
  found by "most recently opened lobby".
- Fixed alongside it: reloading on the winner screen used to eject you into a brand
  new empty room. A room that finished within the last 2 hours now still counts as
  your room, so a reload puts you back with your friends. The 2-hour window is the
  safety valve so an abandoned room can never trap you. A latecomer arriving just
  after a win also lands in that room rather than opening one of their own.
- serve.py now honours a PORT environment variable (still 5500 by default) so two
  chats can each run a preview server without fighting over the port.
- Tidied the database (0006): three abandoned 'playing' test rooms marked finished,
  with finished_at BACKDATED to when they were last active. The backdating matters —
  stamping them with the current time would have made them claim players again under
  the new "finished within 2 hours is still your room" rule. Nothing deleted.
- PLAY AGAIN TESTED live, two browsers, two full games. Round 1 (46 turns): one
  player pressed Play again, the OTHER window returned to the lobby unaided, tokens
  reset, ready flags cleared. Round 2 (78 turns): reloaded on the winner screen and
  landed back on the same winner screen; total room count unchanged, so no stray
  room was created. Stale-move filter confirmed (round 2 opened with "Roll to
  begin", not round 1's winning move). Turn counter climbed 46 -> 124 without
  resetting and all moves from both games remain on record.

- AWAY DETECTION built (0007, then corrected by 0008). last_seen_at is now read, not
  just written. 0007 used a single 30s rule and DELETED away players at start_game;
  live measurement immediately disproved it — two players sitting with windows open
  measured 47s and 466s since last ping, because browsers throttle and then freeze
  background tabs. That rule would have ejected real players from a round with no
  way back in.
- 0008 splits it into TWO thresholds, deliberately: player_is_present() = 45s, used
  only for leadership and the ready-gate (being wrong is cheap and self-correcting);
  player_has_abandoned() = 5 minutes, the ONLY thing that removes a seat (being wrong
  is permanent, since there is no mid-game join). 5 minutes is past the point where
  browsers freeze a hidden tab entirely. Plus a guard so a round can't start with
  fewer than 2 seated players after the clear-out.
- Frontend to match: AWAY_AFTER_MS = 45000 (must stay in step with 0008); the lobby
  now SHOWS away players tagged "away" instead of hiding them; and a
  visibilitychange handler pings + resyncs the clock + refreshes the moment the app
  is brought back to the front, so returning clears "away" in about a second.
- heartbeat() no longer stamps rows in finished games.
- VERIFIED against the live database: present at 40s = true, at 60s = false;
  abandoned at 60s = false, at 10min = true. Lobby correctly showed a genuinely
  backgrounded player as "away" rather than removing them.
- GHOST SCENARIO TESTED end to end with two API-created players. Fresh ghost ->
  start_game refused with "Everyone must be ready first" (original bug reproduced).
  Stale ghost -> start_game succeeded, seats renumbered 1..3, ghost deleted (it was
  ~7min silent, past the abandon line) while a player 22s silent kept their seat.
  visibilitychange handler also proven: a 16-minute-frozen window returned to 22s
  with one click.
- Test room retired afterwards (0009) so reconnect wouldn't pull anyone back into a
  game containing a made-up player. NOTE: 0009 targets every 'playing' room and is
  only safe because the database was checked first and had exactly one; 0006 is the
  general-purpose tidy-up because it carries a 6-hour time guard.

## Known gaps / next steps (as of end of session 3)
- **Latecomers during a live game still split off.** If a friend opens the app while
  a game is already running, they can't join it (mid-game joins aren't supported),
  so they open a room of their own and are separated until they reload afterwards.
  Worth fixing later by parking them in the running room as a spectator who is
  seated automatically for the next round.
- **Not a PWA yet**: no manifest and no service worker, so it cannot be installed
  to a phone home screen yet.
- **Not published**: runs only on the laptop's local dev server. GitHub Pages
  hosting is not set up, so friends cannot reach it and the laptop must be on.
- **AutoPlay needs at least one phone open**: if literally everyone closes the app
  mid-turn, the game pauses until someone returns. Intentional and harmless.
- **players.is_master is redundant**: leadership is actually decided from
  games.owner_user_id. Harmless, but worth removing one day.
- Open product question: the exact-100 rule made one test player wait 11 turns on
  square 99. Decision was to KEEP it for now and feel it in a real game.

## Open item — master must be the OWNER'S PHONE at go-live
Current rule: master = first to join a fresh lobby. The user develops on laptop but
PLAYS on phone, which must be master. At go-live: give a "reset room" action so the
phone claims a clean lobby first, OR add the master-only login fallback for a
rock-solid guarantee. Not a blocker for testing.
