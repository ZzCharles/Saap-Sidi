# Saap-Sidi — Project Log

A plain-language diary of this project, so nothing is ever lost between sessions.

**Newest entries are at the top.** Scroll down to read the story from the beginning.

## The rules we keep

1. **Every session that finishes something meaningful gets a dated entry here** —
   what changed, and *why* it changed. Written so it makes sense months later.
2. **Every piece of SQL is saved as a numbered file first**, in
   `supabase/migrations/`, before it is pasted into Supabase. The numbers are the
   order they were run in. Nothing is ever run from a chat window alone.
3. **`docs/decisions.md`** stays as the detailed technical log. This file is the
   readable summary. If the two ever disagree, `docs/decisions.md` is more precise
   but this one is more honest about what actually happened.

---

## 26 July 2026 (later) — the game goes live

**What we set out to do:** get Saap-Sidi off the laptop and onto the internet, so
it can be played on real phones without the laptop being switched on.

**It is published.** The game now lives at:

> **https://zzcharles.github.io/Saap-Sidi/**

**What we did:**

- **Wired up the cobra icons.** Added a manifest file (which is how Android and
  desktop decide to offer "install this app") plus the separate Apple tags that
  iPhone needs, because iPhone ignores the manifest entirely. Both sets have to
  be present at once. The game now installs to a home screen with the cobra icon
  and opens fullscreen, with no browser address bar.
- **Added a service worker.** This is the piece that actually makes a website
  installable. Ours is deliberately **"network first"** — it always tries to
  fetch the real, current files and only falls back to a stored copy if the
  signal drops. The tempting alternative, "cache first", would keep showing
  people an old version of the game after we publish a change, which looks
  exactly like a bug but isn't. Worth remembering if the game ever seems stuck
  on an old version.
- **Removed the dev cache-buster** and replaced it with a proper version stamp,
  `APP_VERSION`. It appears in two files — `index.html` and `sw.js` — and both
  must be bumped together when we publish a change.
- **Put the project on GitHub** as a public repository, `ZzCharles/Saap-Sidi`.

**A decision worth remembering:** GitHub Pages will normally only publish from
the very top of a project, or from a folder called `docs` — and our `docs` folder
holds these notes, not the game. Rather than shuffle files around and make the
project messier, we added a small instruction file
(`.github/workflows/publish.yml`) that tells GitHub to publish the `frontend`
folder specifically. **The upshot: pushing a change to GitHub republishes the
game automatically.** The SQL and these notes stay in the repository but are
never sent to players.

**One snag along the way:** the first publish attempt failed. Publishing is an
on-switch that only the repository owner can flip, so the instruction file ran,
asked permission, and stopped. Flipping *Settings → Pages → Source → GitHub
Actions* and re-running it fixed it. Nothing was broken — it had just reached a
locked door.

**Also worth knowing:** the sign-in to GitHub had to be done by hand, in a normal
PowerShell window. Claude's shell is deliberately blocked from triggering
password prompts, so account sign-ins will always be a manual step. Windows has
remembered the sign-in now, so it should not need doing repeatedly.

**Checked on the live site, not just locally:** every file loads, the manifest is
valid, the service worker is active, all seven icon sizes are served, there are
no errors, and the game reports **Connected ✓** to Supabase.

**Nothing about the game itself changed.** Same classic board, same rules, same
8-player limit, same database. This session was purely about delivery.

**Still to do:** the master is still whoever joins first, not your phone. That is
the next job, and it is easier now that the game is actually on your phone.

---

## 26 July 2026 — "Play again", and the app icon arrives

**What we set out to do:** fix the most obvious hole in the game — when someone
won, the room was dead. There was no way to start another round, and reloading
dumped you into a brand-new empty room, so a group of friends would scatter.

**What we built:**

- **A "Play again" button.** When someone wins, it takes over from the Roll
  button. Pressing it puts the *same room* back to the lobby — tokens to the
  start, everyone un-readied, but seats, names and the master all kept.
- The key idea: **revive the room rather than build a new one.** Every phone is
  already watching that room, so they all flip back to the lobby by themselves.
  Nobody reloads and nobody gets separated.
- **Anyone in the game can press it**, not just the leader — making everyone wait
  on one person is annoying. The leader still controls the actual Start, so the
  group can't be rushed into a round. Two people pressing at once is harmless.

**Two problems we found along the way and fixed:**

- The app used to decide which room to join by **"newest room wins."** That breaks
  the moment you revive an *older* room — a leftover test room would look newer
  and start quietly stealing your friends into an empty lobby. Rooms are now found
  by **"most recently opened lobby"** instead.
- **Reloading on the winner screen** used to eject you into a fresh empty room. Now
  a room that finished in the last two hours still counts as your room, so a reload
  puts you back with your friends. The two-hour limit is the safety valve, so an
  abandoned room can never trap you in it forever.

**A decision worth remembering:** the turn counter does **not** reset between
rounds — it just keeps counting up. Resetting it would clash with the
one-row-per-turn rule, which is the thing that makes AutoPlay safe, and it would
have forced us to delete the game history. Instead each round records when it
started, and the phones ignore anything older than that.

**SQL run:** `supabase/migrations/0005_play_again.sql`

**The app icon arrived** — a cobra, in seven sizes, made in a separate chat. The
files moved to `frontend/icons/` because the web server only serves the `frontend`
folder; anything outside it is invisible to the browser. The instructions that came
with them are now at `docs/icons-how-to-use.md`. **The icons are not wired up yet** —
that happens when we make the game installable.

**Housekeeping:** the dev server now accepts a different port number when 5500 is
busy, so two chats can each run a preview without fighting.

**We also tidied the database.** Three old test games were still marked "in
progress" because we'd walked away from them mid-play. That mattered: opening the
app checks "am I already in an unfinished game?", so you could be dumped back into
a stale 25-turn game instead of a fresh lobby — which looks like a bug but isn't.
They're now marked finished. Nothing was deleted; the full history is intact.

**SQL run:** `supabase/migrations/0006_tidy_abandoned_rooms.sql`

### Tested for real — both fixes proven

Two full games played end to end, Rabin in one browser and Claude in another.

- **Round one (46 turns).** Rabin won on exactly 100. Rabin pressed Play again in
  *one* window — and the other window returned to the lobby **on its own**, with
  both players listed, tokens back at the start and ready flags cleared. Nobody
  reloaded. That is the whole feature working.
- **Round two (78 turns).** Rabin won again, then reloaded on the winner screen.
  It came straight back to the **same winner screen**, and the room count did not
  change — so no stray empty room was created. The reload fix works.
- **Bonus:** round two opened showing "Roll to begin", not round one's winning
  move, so the stale-news fix works too.
- **Confirmed in the database:** turn counter kept climbing (46 → 124) instead of
  resetting, and every move from both games is still on record.

**Worth noting for the open question about the exact-100 rule:** round one ended
with both players sitting on 91, and Claude got dragged from 97 back down to 75 by
the snake on 95 right before Rabin won. That read as a *good* tense ending rather
than a frustrating one. One data point, but it argues for keeping authentic rules.

### A problem we found — and then fixed (the hard way)

**Nobody is ever marked "away" automatically.** The app only knows you've left if
you close the tab cleanly. A phone that dies, loses signal, or gets swiped away
usually doesn't manage to say goodbye — so that player stays listed as present
forever.

That matters because Start only lights up when *everyone present* is ready. One
ghost player who can never press ready would **block the game from ever starting**,
with no way to clear them from inside the app.

The app already pings the server every 5 seconds, so the information needed was
being recorded — it just was never read.

**First attempt (0007) was wrong, and testing caught it within minutes.** The rule
was "away after 30 seconds of silence", and starting a round *deleted* anyone who
was away. Then we measured the two of us actually sitting there with our windows
open: one had last pinged **47 seconds** ago, the other **466 seconds** ago.

The cause: **browsers deliberately slow down and then freeze tabs that aren't in
front.** The ping stops whenever you look at something else. So the rule would have
marked real friends as away — and then thrown them out of the round when the leader
pressed Start, with no way back in, because you can't join a game already running.
That would have been a worse bug than the one being fixed.

**The corrected version (0008) splits it into two questions**, because getting each
one wrong costs something completely different:

| Question | Limit | What it controls |
|---|---|---|
| Are they responding *right now*? | 45 seconds | Who holds Start, and whose "ready" we wait for |
| Have they *abandoned* the room? | **5 minutes** | The only thing that costs someone their seat |

Being wrong about the first is cheap and fixes itself — they come back and count
again. Being wrong about the second is permanent. So removing somebody needs a much
higher bar, and five minutes is past the point where browsers freeze a hidden tab
completely.

**The result:** a dead phone still can't block the Start button — the original bug —
but a friend who glanced at their messages keeps their seat, and AutoPlay covers
their turns until they look back.

Three smaller touches went in with it:

- **Away players stay visible in the lobby**, tagged "away", instead of silently
  vanishing. If Bo's phone locks, you can see Bo is there but not answering.
- **Coming back is instant.** The app pings the moment you switch back to it,
  rather than waiting for a frozen timer, so you stop showing as away in about a
  second.
- The heartbeat no longer stamps rooms you finished days ago.

**SQL run:** `0007_away_timeout.sql`, then `0008_presence_tuning.sql`

**Verified:** all four threshold cases tested directly against the live database
(responding at 40s ✓, not responding at 60s ✓, not abandoned at 60s ✓, abandoned at
10 minutes ✓). The lobby correctly showed a real backgrounded player as "away"
rather than dropping them.

**The ghost scenario then tested end to end, and passed.** Two extra players were
created through the API: "TestPhone", which behaved normally, and "GhostPhone",
which joined, never pressed ready, and never checked in again.

- **While the ghost was fresh**, pressing Start was refused with *"Everyone must be
  ready first"* — the original bug, reproduced on demand.
- **Once the ghost went quiet**, Start succeeded. The round began with Claude, rk
  and TestPhone seated, and the ghost removed.
- **Rabin kept their seat** at 22 seconds since last ping, while the ghost lost its
  seat at nearly 7 minutes. Both thresholds doing exactly their own job.
- The "coming back is instant" fix was proven by accident along the way: Rabin's
  window had been frozen in the background for **16 minutes**, and one click brought
  it back to 22 seconds.

**Tidy-up:** the test necessarily started a real round containing a made-up player,
so that room was retired afterwards — otherwise opening the app would reconnect you
into the test game.

**SQL run:** `0009_close_test_room.sql`

**A near miss worth recording:** the first version of that cleanup file had a
condition that would have quietly matched nothing, leaving the test room live. It
was caught by checking the actual database state before handing it over rather than
trusting that the logic read correctly.

**The lesson worth keeping:** the first version looked obviously right and was
dangerous. It only came apart because we measured real numbers from real windows
instead of trusting the design.

---

## 25 July 2026 — The game actually became a game

**Built and proven:** the board, the dice, the rules, the clock.

- **The board** — a proper 10×10 grid numbered the traditional back-and-forth way,
  with 9 ladders and 10 snakes, 100 in gold, and players as coloured dots.
- **The dice and the rules live on the server.** The phone never decides a roll.
  Snakes, ladders, and the exact-100 win are all the server's judgement.
- **A 20-second turn timer with AutoPlay.** If someone doesn't act in time, the
  server rolls for them so the game never stalls. Every phone watches the clock
  and nudges the server; because only one roll can ever be recorded per turn, it
  doesn't matter how many phones nudge at once.

**What we proved by actually testing it:**

- A **complete 59-turn game to a win** — 5 ladders, 5 snakes, 11 overshoots, and a
  winner who rolled exactly the 1 they needed from square 99.
- **Cheating fails.** Rolling out of turn was refused. Writing a position straight
  into the database was refused and the token did not move.
- **Duplicate taps are harmless.** Five simultaneous rolls produced exactly one
  move and advanced the turn exactly once.
- **Reconnecting works.** Reloading mid-game came back to the identical state.
- AutoPlay fired correctly after 20 seconds of nobody acting.

**Fixed:** the 8-player maximum wasn't actually being enforced.

**A frustrating detour worth recording:** we lost real time to a bug that wasn't a
bug — the browser kept showing an old copy of the code. The dev server now tells
the browser never to cache, and the page loads its files with a timestamp. That
timestamp trick is *only* for development and must be removed before publishing.

**SQL run:** `0003_board_and_rolling.sql`, `0004_timer_and_autoplay.sql`

---

## 24 July 2026 — Foundations: the database and the lobby

**The decision everything else rests on:** the phone only *displays* the game;
**the server decides everything that matters.** Dice rolls, whose turn it is,
whether a move is legal. This is what stops cheating and keeps everyone in sync.
It's the same approach that worked well in the earlier roulette app.

**Two choices made to keep life simple:**

- **All the server logic lives inside the database**, not in separate programs.
  This means new logic is installed by *pasting SQL into Supabase and pressing
  Run* — no command-line tools ever need installing on the laptop.
- **The phone side is a plain website** — three files, no frameworks, no build
  step. Intended for free hosting on GitHub Pages.

**The database, in plain terms — three notebooks and a map:**

- **games** — one row per room: waiting / playing / finished, whose turn, the clock.
- **players** — one row per seat: name, seat order, square they're on, ready or not.
- **moves** — a permanent history, one row per turn taken.
- **board_jumps** — the map of snakes and ladders, kept in the database so the
  server and every phone read exactly the same truth.

**The single most important trick:** the moves notebook allows **only one row per
turn**. If a real tap and an AutoPlay both try to play turn 7 at the same instant,
the first wins and the second quietly does nothing. Almost everything else about
this project is safe because of that one rule.

**Security:** phones may only *read*. There are no write permissions at all —
every change goes through the server. This was later verified by trying to cheat.

**The lobby was built and tested:** type your name once, land in a shared lobby,
see everyone live, press ready. Start is only shown to the leader and only works
when there are at least 2 players and everyone is ready. A second player appeared
on screen instantly with no refresh.

**How leadership works:** the master (the owner's phone) always leads if present;
otherwise the earliest-joined player still connected leads. This is so friends can
play even when the owner isn't there.

**SQL run:** `0001_initial_schema.sql`, `0002_lobby_functions.sql`

---

## Before that — what Saap-Sidi is

An online, turn-based **Snakes and Ladders** for **2 to 8 friends**, played across
separate phones in real time. Open the app, land in a shared lobby, press ready,
one person starts. Roll, climb ladders, slide down snakes, and the first to land
on **exactly 100** wins. Twenty seconds per turn, and the server rolls for you if
you dawdle, so the game never stalls.

**Decisions made early that you wouldn't guess from the code:**

- **20 seconds per turn**, not 30 — a longer wait would be annoying mid-game.
- **Up to 8 players**, raised from 6. Beyond 8 the coloured dots get hard to tell
  apart and squares get crowded.
- **One single shared lobby.** Everyone who opens the app joins the same room.
  Join codes and multiple rooms were deliberately deferred.
- **Players type their own name** rather than being labelled "Player 1, 2, 3",
  because names make the lobby feel human.
- **The 80→100 ladder stays**, even though it means landing on 80 wins instantly.
  That's the classic board and we're keeping it.
- **The exact-100 rule is being kept for now**, even though one test player sat on
  square 99 for 11 turns waiting for a 1. The decision was to feel it in a real
  game with friends before changing anything.

**Deliberately NOT built yet** (this is "Layer 1 — plain and functional"): jungle
art, animated snakes swallowing you, wildlife, weather, music, profile photos,
emoji reactions, victory spectacle. Simple shapes and colours are fine for now.

**Planned for later:** friends' photos on their tokens, exaggerated funny
animations, and multiple lobbies with join codes.
