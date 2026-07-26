# Saap-Sidi — The "Memory" Plan (plain language)

This is the list of facts the server needs to remember. No code — just what we
store and why. Think of it as **three notebooks** the referee keeps.

---

## Notebook 1: Games (one page per game room)

Each game room gets a page holding:
- **A unique game ID** — so we can tell rooms apart.
- **Status** — is this room *waiting for players*, *playing*, or *finished*?
- **Public or private** — is it listed for anyone to join, or invite-only?
- **Join code** — a short code for private rooms (like "GOAT7"), so friends can enter.
- **Turn timer length** — how many seconds each player gets on their turn (e.g. 30).
- **Whose turn it is** — points to one player.
- **Turn deadline** — the exact clock time the current turn runs out. This is how
  the server knows when to AutoPlay.
- **Winner** — empty until someone reaches exactly 100.

## Notebook 2: Players (one page per seat in a game)

Each person sitting in a game gets a page holding:
- **Which game** they're in.
- **Who they are** — their login ID (from Supabase) and a display name.
- **Seat order** — 1st, 2nd, 3rd… this fixes the turn order.
- **Token position** — which square they're on, 0 to 100.
- **Ready?** — have they pressed the "ready" button in the lobby?
- **Connected?** — are they currently online? (Used to show "reconnecting…" to others.
  It does NOT pause the game — AutoPlay covers absent players.)

## Notebook 3: Moves (a permanent history — one line per turn taken)

Every single roll is written down and never changed:
- **Which game** and **which player**.
- **Turn number** — 1, 2, 3, 4… counting up for the whole game.
- **Dice value** — what the server rolled (1–6).
- **From square → to square** — where the token started and ended.
- **Snake or ladder?** — did this move slide down a snake or climb a ladder?
- **Was it AutoPlay?** — did the server roll automatically because the timer ran out?
- **When** it happened.

---

## Why the "turn number" is the secret ingredient

The Moves notebook has a strict rule: **only one line can ever exist for a given
turn number in a given game.**

Here's why that matters. Imagine it's turn 7, and two things happen at almost the
same moment:
1. The player finally taps "roll", AND
2. The timer runs out and AutoPlay also tries to roll.

Both requests reach the server. But because only *one* line for "turn 7" is allowed,
the **first one wins** and writes turn 7. The second one arrives, sees "turn 7 is
already taken", and quietly does nothing. No double roll. No confusion.

This is the same safe trick your roulette app used for simultaneous "spin" requests.
It's what lets AutoPlay work no matter who is or isn't connected when the timer ends.

## Why this also makes reconnect easy

Because the three notebooks hold the *complete* state at all times, a player who
drops off and comes back just re-reads the notebooks and sees the exact same board,
positions, and whose turn it is. Nothing is stored only on their phone, so nothing
is lost.
