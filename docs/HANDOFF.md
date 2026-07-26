# Saap-Sidi — context handoff

Paste this whole file into a new chat to pick the project up cold.
Current as of **26 July 2026 (end of session 3)**.

---

## 0. How to work with me

I am **not technically knowledgeable**. I don't code. Explain in plain language,
avoid unexplained jargon, work in small steps, and check in rather than doing a lot
silently. Assume I'm smart but don't have the vocabulary. Treat my mistakes as normal.

**Division of roles:** I own the ideas and the taste. **You own all technical
decisions** — don't ask me to choose between frameworks or file layouts, just decide,
tell me briefly what and why, and move on. Do ask me about anything that changes how
the game looks, feels, or plays.

**Two standing rules I asked for:**
1. **`PROJECT_LOG.md`** (project root) is a plain-language dated diary, newest first.
   Add an entry at the end of each session or whenever something meaningful lands.
2. **Any SQL must be saved as a numbered file in `supabase/migrations/` BEFORE I run
   it.** Never hand me SQL that only exists in the chat.

I also have a separate Claude chat acting as co-designer; I relay between them.

**A practical tip that saves time:** to give me SQL, run
`cat "supabase/migrations/NNNN_name.sql" | clip` yourself and then tell me to paste
into Supabase. Don't put a shell command and "paste into Supabase" in the same list —
I once pasted the shell command into the SQL editor by mistake.

---

## 1. What Saap-Sidi is

Online, turn-based **Snakes and Ladders** for **2–8 friends** on separate phones in
real time. Shared lobby → everyone presses ready → one person starts → roll, climb
ladders, slide down snakes → **first to land on exactly 100 wins**. 20 seconds per
turn; if you don't act, the server rolls for you so the game never stalls.

## 2. Architecture (non-negotiable)

**The phone only displays; the server decides everything that matters** — dice, whose
turn, whether a move is legal. This is the anti-cheat guarantee, verified by
attempting to cheat.

- **Backend: Supabase.** Postgres + realtime + anonymous login. Live project exists.
- **All server logic lives INSIDE the database** as Postgres functions — so
  everything installs by pasting SQL into the Supabase SQL Editor. No CLI tools.
- **Frontend: a plain website** — `index.html`, `style.css`, `game.js`, `config.js`.
  No React, no build step. Destined for GitHub Pages.

```
Saap-Sidi/
├── PROJECT_LOG.md          the plain-language diary — READ THIS FIRST
├── frontend/
│   ├── index.html  style.css  game.js  config.js
│   └── icons/              app icon, 7 sizes (staged, NOT wired up yet)
├── supabase/migrations/    every SQL file ever run, in order (0001–0009)
├── docs/
│   ├── decisions.md        detailed technical log
│   ├── database-plan.md    the "three notebooks" explanation
│   ├── icons-how-to-use.md instructions that came with the icon
│   └── HANDOFF.md          this file
├── serve.py                dev server (threaded, no-cache, honours $PORT)
└── .claude/launch.json     starts serve.py, autoPort enabled
```

**The database:** `games` (one row per room), `players` (one row per seat), `moves`
(permanent history), `board_jumps` (9 ladders + 10 snakes).

**The single most important trick:** `moves` has a uniqueness rule on
`(game_id, turn_number)` — only one row can ever exist per turn. If a real tap and an
AutoPlay both try to play turn 7, the first wins and the second quietly does nothing.
This is what makes AutoPlay and reconnect safe. **Never reset `turn_number`.**

**Security:** phones may only READ. No write policies exist at all. Every change goes
through server functions.

---

## 3. What's built and verified

Everything in Layer 1's core loop, all tested live:

- Anonymous sign-in; lobby with live player list, names, ready toggles.
- Automatic leadership: master leads if present, else earliest-joined still present.
- Server-side dice, movement, snakes, ladders, exact-100 win. Proven over several
  complete games.
- Real-time sync; reconnect mid-game returns to identical state.
- 20-second turn timer with AutoPlay; phones correct for their own clock drift.
- **Anti-cheat verified** by trying to cheat: out-of-turn roll refused; writing
  `position` directly refused.
- **Idempotency verified:** 5 simultaneous rolls → exactly one move.
- **Play again** (0005): a win revives the SAME room rather than making a new one, so
  every phone returns to the lobby by itself. Anyone may press it. Tested across two
  full games in two browsers.
- **Away detection** (0007→0008): two thresholds — 45s "responding" and 5min
  "abandoned". Both verified directly against the live database. See PROJECT_LOG for
  why the first attempt was wrong.

## 4. Known gaps — nothing broken, just absent

- **Icons staged but not wired up.** `frontend/icons/` has 7 sizes. No manifest, no
  service worker, no Apple tags — so not installable. `docs/icons-how-to-use.md` has
  a ready-made brief for exactly this job.
- **Not published.** Runs only on the laptop dev server (`python serve.py`, port
  5500). GitHub Pages not set up.
- **Master is still whoever joined first.** I develop on laptop but will PLAY on my
  phone, and my phone must be master. Sorting this is tied to publishing.
- **Latecomers during a live game split off** into a room of their own — mid-game
  joining isn't supported.
- **AutoPlay needs at least one phone open.** Intentional, harmless.
- **The dev cache-buster in `index.html`** (`?v=<timestamp>`) must be REMOVED before
  publishing.
- `players.is_master` is set but unused — leadership comes from `games.owner_user_id`.

## 5. Decisions you wouldn't guess from the code

- **20-second turns**, not 30 — a longer wait is annoying mid-game.
- **Max 8 players**, raised from 6; beyond that the dots get hard to tell apart.
- **One single shared lobby.** Join codes and multiple rooms deliberately deferred.
- **Turn counter never resets between rounds** — resetting would clash with the
  one-row-per-turn rule and force deleting history. `games.started_at` is the line
  between rounds; phones ignore moves older than it.
- **The 80→100 ladder stays**, even though landing on 80 wins instantly.
- **Exact-100 rule kept for now.** One test had a player stuck on 99 for 11 turns,
  but a later game ended tensely and well. Decided to feel it in a real game before
  changing. **Don't change this unless I ask.** Alternatives offered were "bounce
  back" and "reaching or passing 100 wins".
- **Removing a player from a round must be near-certain**, because there is no way to
  join a game in progress. Hence the deliberately generous 5-minute abandon rule.
- **`serve.py` must stay threaded** — single-threaded hung the browser.
- Players type their own names; friend photos planned later and need no accounts.

**Explicitly NOT to be built until I ask** (Layer 1 = plain and functional): jungle
art, animated swallowing/climbing, wildlife, weather, music, profile photos, emoji
reactions, victory spectacle. Later pipeline: photos on tokens, exaggerated funny
animations, multiple lobbies with join codes.

---

## 6. Where we left off / next steps

In priority order:

1. **Wire up the icons, make it installable, and publish to GitHub Pages.** There's a
   ready-made brief in `docs/icons-how-to-use.md`. This also unblocks the master
   question — once it's on my phone, my phone should claim master. Remember to strip
   the dev cache-buster from `index.html` before publishing.
2. **Then play it for real with friends** and decide two things by feel: whether 20
   seconds is right, and whether exact-100 is fun or frustrating.

Layer 1's core loop is complete, tested and closed out. Session 3 ended with
everything verified — nothing is left half-built.

To run locally: `python serve.py` (port 5500), open `http://localhost:5500`.
Supabase URL and public key are already in `frontend/config.js`. All SQL in
`supabase/migrations/` has been run against the live project.

**Testing tip:** two windows in the *same* browser share an identity and count as one
player. Use one normal window plus one private window, or two different browsers.
Also note that a hidden browser tab stops pinging within about a minute — this is
normal and is exactly why the two-threshold presence rule exists.
