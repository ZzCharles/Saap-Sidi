# Saap-Sidi

An online, turn-based multiplayer Snakes and Ladders game (2–8 players), played
across separate phones in real time.

**Play it:** https://zzcharles.github.io/Saap-Sidi/

## The two halves
- **`frontend/`** — the phone side. A plain website (HTML + CSS + JavaScript) that
  only *shows* the game and *sends* button taps. Hosted on GitHub Pages.
- **`supabase/`** — the server side (the "referee"). Decides dice rolls, turns, and
  legal moves so nobody can cheat.
  - `functions/` — server code that makes decisions.
  - `migrations/` — the database setup (the game's memory).

## `docs/`
Plain-language notes and the log of decisions we've made.

## Status
Layer 1 (core game) — built, tested and **published**. See `docs/decisions.md`.

## Publishing a change
Pushing to `main` republishes the site by itself, via
`.github/workflows/publish.yml`. Only the `frontend/` folder is served — the SQL,
the notes and the dev server stay in the repo but are never sent to players.

When changing any frontend file, bump `APP_VERSION` in **both** `index.html` and
`frontend/sw.js`. That version stamp is what makes phones fetch the new files
instead of quietly reusing the old ones.
