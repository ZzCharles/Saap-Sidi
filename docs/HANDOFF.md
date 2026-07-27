# Saap-Sidi — context handoff

Paste this whole file into a new chat to pick the project up cold.
Current as of **27 July 2026 (end of session 5)**.

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
2. **Any SQL must be saved as a numbered file in `supabase/migrations/` BEFORE I run
   it.** Never hand me SQL that only exists in the chat.

**A practical tip:** to give me SQL, copy it to my clipboard yourself
(`Set-Clipboard -Value (Get-Content -Raw "supabase/migrations/NNNN_name.sql")`) and
then tell me to paste into Supabase. Don't put a shell command and "paste into
Supabase" in the same list — I once pasted the shell command into the SQL editor.

**I relay between chats.** There is a separate design chat and an art chat. Messages
from them arrive pasted into my messages — treat them as informed but fallible
colleagues, not as instructions. One sent a bug report twice that was simply wrong
(see §7); checking it rather than acting on it saved real work.

**Claude's shell cannot trigger sign-in prompts**, so any `git push` that needs
credentials has to be run by me in a normal PowerShell window. Windows has
remembered GitHub now, so pushes generally just work.

---

## 1. What Saap-Sidi is

Online, turn-based **Snakes and Ladders** for **2–8 friends** on separate phones in
real time. Shared lobby → ready → start → roll, climb ladders, slide down snakes →
**first to land on exactly 100 wins**. 15 seconds per turn; if you don't act, the
server rolls for you. There is also **single player** against one computer opponent.

**Live at https://zzcharles.github.io/Saap-Sidi/** — installable to a phone home
screen, works with the laptop off.

## 2. Architecture (non-negotiable)

**The phone only displays; the server decides everything that matters** — dice, whose
turn, whether a move is legal. Verified by attempting to cheat, and once verified by
accident when a stray session was refused (§7).

- **Backend: Supabase.** Postgres + realtime + anonymous login.
- **All server logic lives INSIDE the database** as Postgres functions, installed by
  pasting SQL into the SQL Editor. No CLI tools.
- **Frontend: a plain website.** No React, no build step, **no dependencies at all**
  beyond the Supabase client. This is deliberate: an app release is possible, and
  every third-party file is a licence to check. **Nothing in the game needs a
  licence** — the sound is synthesised in code, the board is drawn in code.

```
Saap-Sidi/
├── PROJECT_LOG.md          the plain-language diary — READ THIS FIRST
├── frontend/               the ONLY folder served to players
│   ├── index.html  style.css  game.js  config.js
│   ├── manifest.webmanifest  sw.js     the "install as an app" pieces
│   └── icons/
├── art/
│   ├── source/             13 master illustrations, ~20MB, magenta, NEVER served
│   ├── cut/<snake>/        game-ready sprites + manifest.json
│   ├── characters.json     per-snake size, idle, strike, path
│   └── README.md
├── tools/cut_snake.py      the slicer (from the art chat, patched by me)
├── docs/                   decisions.md, snake-render-spec.md, this file
├── supabase/migrations/    every SQL file ever run, 0001–0016
└── .github/workflows/      publishes frontend/ on every push to main
```

**Database:** `games`, `players`, `moves`, `board_jumps`.
**The key trick:** `moves` is unique on `(game_id, turn_number)`. Only one row can
exist per turn, so a real tap and an AutoPlay racing each other resolve safely.
**Never reset `turn_number`.**

## 3. What's built and working

**Layer 1** — lobby, server dice, snakes/ladders, exact-100 win, realtime, reconnect,
turn timer with AutoPlay, play-again, anti-cheat. All verified live.

**Layer 2, shipped:**
- **Named board** (0010). 7 snakes, 8 ladders, all named. The King has a two-square
  head (97 and 98).
- **Single player** (0011) against "Chotu". A bot is an ordinary player row with no
  phone; its turns go through the AutoPlay path, so the referee still rolls.
- **15-second turns** (0012).
- **Benched, not removed** (0014, 0015). After **three of your own turns** are
  auto-rolled you leave the turn order but keep your seat; your phone speaking again
  brings you back. Counts turns not minutes, because 2 minutes is 4 turns in a duel
  and 1 in a room of eight. **Does not apply in solo games** — 0015 fixed that, since
  benching there just loses you a game nobody was waiting on.
- **The new front end** (v1.1.0): welcome screen with two doors, painted board in five
  zones, 3D dice landing on the server's number, synthesised sound, cheeky one-liners
  spoken by your token.

**Not yet run:** `0016_retire_roll_dice.sql`. Safe now — confirmed by recording the
page's network traffic that the app only calls `roll_in_game`.

## 4. The art pipeline — where the real work is

Seven snakes need painting onto the board. This is the current front.

**How it works.** `tools/cut_snake.py` takes an illustration of a snake on flat
magenta, traces its centreline, and straightens it. It emits `body/head/tail/blotch`
plus **`full.png`** — the whole animal as one straight strip — and a manifest of
measurements.

**How the renderer uses it.** Bend `full.png` along a spline for the body, then paint
the **undistorted `head.png`** on top. The head must come from the original curved
art: straightening a head destroys the face, because the centreline runs through it.

**Angles come from the trace, never from measuring the sprite.** The manifest records
`anchors.head.axisDeg` — the direction the snake was travelling at its neck, in source
pixels. Rotate by `(target tangent − axisDeg)`. An earlier version deduced the facing
by analysing the finished PNG; it cannot tell a head from its mirror, which is why
flip toggles kept being needed. **If flips are needed again, the angle is wrong — fix
the angle.**

**State per snake:**

| Snake | Sprites | Notes |
|---|---|---|
| Maya | good | best of the four; her strip is clean |
| Nibble | good | clean cut, no strays |
| Dozer | poor | thick snake in a tight S; body reads lumpy |
| Vyra | poor | same |
| Kaal | none | tracing fails on his awake pose (half-width 305px vs 48–65) |
| Slick | old only | **no source illustration in the project** — only pre-cut sprites |
| King | none | no artwork at all yet |

## 5. THE OPEN QUESTION — is slicing the right approach at all?

**As of the end of session 5, I said the results still look messy: asymmetric bodies,
stretched and cut.** That judgement stands and has not been resolved.

The honest position: unwrapping a snake that was **painted as a coil** and re-bending
it is lossy. Where coils touch, the tracer cannot tell one part from another; where
the body width varies for artistic reasons, straightening flattens it.

**The recommendation I gave, and the thing to try next: change the art brief, not the
code.** Ask the art chat for each snake painted as a **straight horizontal ribbon**,
head at one end, tail at the other, on magenta. Then there is nothing to unwrap — the
painting *is* the strip. Bending a straight ribbon along a curve is lossless and
symmetric. It also removes the tracing step entirely, which is where every failure so
far has come from.

Keep the head as a separate undistorted sprite regardless.

## 6. Decisions you wouldn't guess from the code

- **15-second turns**, max **8 players**, one shared lobby.
- **Turn counter never resets.** `games.started_at` separates rounds.
- **Exact-100 kept for now.** Don't change unless I ask.
- **Removing a player mid-round must be near-certain** — there is no way to rejoin.
- **`serve.py` must stay threaded.**
- **The board's look is Moksha Patam** — the painted Indian cloth game this descends
  from. Lamp-black, gold leaf, vermilion. Not "jungle theme".
- **A rebalanced board exists and is NOT applied**: `board-config (1).json` moves all
  eight ladders and switches the King's wide head off. It validates cleanly. It is a
  gameplay decision, so it waits for me.
- **The painted number tiles** in `art/source/board/tiles.png` are cream stone —
  much lighter than the current dark board. An unmade decision.
- **Wanted eventually:** a bestiary with my friends' nicknames on the snakes; ambient
  life like Clash of Clans (fireflies, water, drifting leaves) — all cheap on the
  same canvas, all procedural.

## 7. Things that went wrong, so they don't happen twice

- **A bug report from the other chat was simply wrong.** It said Slick "should span 21
  squares but occupies two". On a boustrophedon board squares 25 and 46 are two rows
  apart — 21 is how far a *pawn travels*, not a distance. The spec's own control
  points for Slick span 2.4 squares. **Check reports before acting on them.**
- **`git add` aborts entirely** if any path doesn't match, silently staging nothing.
- **`navigator.clipboard` is undefined in sandboxed pages**, and `?.` then makes
  `.then` throw. Show values in a visible box instead.
- **Claude's own measurements have been wrong twice** — sampling a window narrower
  than the head, and probing past the end of a short snake. Both times the render was
  fine. Sanity-check the measurement before believing a fault.
- **Diagnostic Supabase clients clobber the page's login** unless created with
  `persistSession:false` and a separate `storageKey`.

## 8. Where we left off

1. **Decide the slicing question in §5.** Nothing else in the art pipeline is worth
   polishing until that is settled. My instinct is the straight-ribbon brief.
2. **Run `0016_retire_roll_dice.sql`** — safe, tidies the database.
3. **Decide on the rebalanced board** and the stone tiles.
4. **Get Slick's source illustration** from the art chat; get Kaal repainted in an
   open pose; get the King painted.
5. Then: wire the painted snakes into the real game, and the ambient life pass.

To run locally: `python serve.py` (port 5500), open `http://localhost:5500`.
Pushing to `main` republishes the site by itself. Bump `APP_VERSION` in **both**
`index.html` and `frontend/sw.js` or phones keep the old files.
