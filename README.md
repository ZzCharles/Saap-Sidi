# Saap-Sidi

An online, turn-based multiplayer Snakes and Ladders game (2–6 players), played
across separate phones in real time.

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
Layer 1 (core game) — in progress. See `docs/decisions.md`.
