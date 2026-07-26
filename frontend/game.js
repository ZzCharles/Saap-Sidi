// Saap-Sidi — the phone side.
// This half only DISPLAYS the game and SENDS button taps.
// The server (Supabase) decides everything that matters.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Load our settings, carrying through the same "fresh copy" marker (see index.html).
const DEV_V = new URL(import.meta.url).searchParams.get("v") || "";
const { SUPABASE_URL, SUPABASE_ANON_KEY } = await import("./config.js?v=" + DEV_V);

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// --- little helpers ---------------------------------------------------------
const el = (id) => document.getElementById(id);
const show = (id) => el(id).classList.remove("hidden");
const hide = (id) => el(id).classList.add("hidden");
function status(msg, kind) { const s = el("status"); s.textContent = msg; s.className = kind || ""; }

const NAME_KEY = "saap_name";

// One colour per seat, up to 8 players.
const SEAT_COLORS = [
  "#e5484d", "#3b82f6", "#22c55e", "#eab308",
  "#a855f7", "#f97316", "#06b6d4", "#ec4899",
];

let myId = null;      // this phone's hidden ID
let gameId = null;    // the game we're in
let channel = null;   // the live-updates connection
let heartbeatTimer = null;
let iAmReady = false;
let jumps = {};       // the board map: square -> { to, kind }
let boardBuilt = false;

// The newest state we've seen, kept so the countdown can tick without re-asking.
let lastGame = null;
let lastPlayers = [];

// Phones' clocks are often a little wrong. We measure the difference against the
// server's clock so the countdown everyone sees matches the real deadline.
let clockOffset = 0;
const serverNow = () => Date.now() + clockOffset;
let lastNudge = 0;    // don't pester the server more than once a second or so

// Who counts as actually here. A phone that dies or loses signal usually never
// manages to say goodbye, so "is_connected" alone would leave ghosts in the lobby
// forever — and a ghost who can never press "ready" would block the Start button.
// So we also require a recent ping. We compare against the SERVER's clock, not
// this phone's, for the same reason the countdown does.
//
// This must stay in step with player_is_present() in the database (0008).
//
// 45 seconds, not less: browsers throttle and then freeze background tabs, so a
// friend who glanced at their messages stops pinging even though they are still
// sitting right there. Being marked away is harmless and self-correcting — they
// come back and count again — but only because nothing here costs them their
// seat. Losing a seat needs a much higher bar (see player_has_abandoned).
const AWAY_AFTER_MS = 45000;
const isPresent = (p) =>
  p.is_connected && serverNow() - new Date(p.last_seen_at).getTime() < AWAY_AFTER_MS;

// --- 1) connect and sign in (no password) -----------------------------------
async function connect() {
  status("Connecting…", "muted");

  let { data: { session } } = await supabase.auth.getSession();
  if (!session) {
    const { error } = await supabase.auth.signInAnonymously();
    if (error) { status("Could not connect: " + error.message, "error"); return; }
    ({ data: { session } } = await supabase.auth.getSession());
  }
  myId = session.user.id;
  status("Connected ✓", "ok");

  await loadBoardMap();
  await syncClock();

  const savedName = localStorage.getItem(NAME_KEY);
  if (savedName) {
    el("name-input").value = savedName;
    await joinLobby(savedName);
  } else {
    show("name-screen");
  }
}

// Work out how far this phone's clock is from the server's, so the countdown is
// honest. We account for the round-trip by using the midpoint of the request.
async function syncClock() {
  const before = Date.now();
  const { data } = await supabase.rpc("server_now");
  const after = Date.now();
  if (data) {
    clockOffset = new Date(data).getTime() - (before + (after - before) / 2);
  }
}

// The snake/ladder map comes from the server so everyone shares one truth.
async function loadBoardMap() {
  const { data } = await supabase.from("board_jumps").select("*");
  jumps = {};
  for (const j of data || []) {
    jumps[j.from_square] = { to: j.to_square, kind: j.kind };
  }
}

// --- 2) join the lobby ------------------------------------------------------
async function joinLobby(name) {
  hide("name-screen");
  status("Joining lobby…", "muted");

  const { data, error } = await supabase.rpc("join_lobby", { p_display_name: name });
  if (error) { status("Could not join: " + error.message, "error"); return; }

  gameId = data;
  status("Connected ✓", "ok");
  await subscribe();
  await refresh();
  startHeartbeat();
}

// --- 3) listen for live changes ---------------------------------------------
async function subscribe() {
  if (channel) { await supabase.removeChannel(channel); }
  channel = supabase
    .channel("game-" + gameId)
    .on("postgres_changes",
      { event: "*", schema: "public", table: "players", filter: "game_id=eq." + gameId },
      refresh)
    .on("postgres_changes",
      { event: "*", schema: "public", table: "games", filter: "id=eq." + gameId },
      refresh)
    .on("postgres_changes",
      { event: "*", schema: "public", table: "moves", filter: "game_id=eq." + gameId },
      refresh)
    .subscribe();
}

function startHeartbeat() {
  if (heartbeatTimer) clearInterval(heartbeatTimer);
  heartbeatTimer = setInterval(() => { supabase.rpc("heartbeat"); }, 5000);
}

// Coming back after the app was in the background. Browsers slow down and then
// stop timers in hidden tabs, so our ping has almost certainly stopped and the
// others now think we're away. Say hello immediately rather than waiting for the
// next tick, re-check the clock (which drifts while frozen), and redraw.
document.addEventListener("visibilitychange", async () => {
  if (document.visibilityState !== "visible" || !gameId) return;
  await supabase.rpc("heartbeat");
  await syncClock();
  await refresh();
});

// --- 4) read the latest state and draw it -----------------------------------
async function refresh() {
  const [{ data: game }, { data: players }, { data: lastMoves }] = await Promise.all([
    supabase.from("games").select("*").eq("id", gameId).single(),
    supabase.from("players").select("*").eq("game_id", gameId).order("seat"),
    supabase.from("moves").select("*").eq("game_id", gameId)
      .order("turn_number", { ascending: false }).limit(1),
  ]);
  if (!game) return;
  render(game, players || [], (lastMoves || [])[0] || null);
}

// Who holds the Start button: the master if present, else earliest-seated
// player who is still connected.
function leaderId(game, connected) {
  if (connected.length === 0) return null;
  const master = connected.find((p) => p.user_id === game.owner_user_id);
  if (master) return master.user_id;
  return connected.slice().sort((a, b) => a.seat - b.seat)[0].user_id;
}

function render(game, players, lastMove) {
  lastGame = game;
  lastPlayers = players;

  if (game.status === "waiting") {
    hide("game-screen"); show("lobby-screen");
    renderLobby(game, players);
  } else {
    hide("lobby-screen"); show("game-screen");
    renderGame(game, players, lastMove);
  }
}

// --- the lobby view ---------------------------------------------------------
function renderLobby(game, players) {
  // Everyone who hasn't closed the app — shown even if they've gone quiet, so a
  // friend who tabbed away doesn't just silently disappear from the list.
  const inRoom = players.filter((p) => p.is_connected);
  // ...and of those, the ones still answering. Only these decide who leads and
  // whose "ready" we wait for.
  const present = inRoom.filter(isPresent);
  const theLeader = leaderId(game, present);

  const list = el("player-list");
  list.innerHTML = "";
  for (const p of inRoom) {
    const li = document.createElement("li");

    const name = document.createElement("span");
    name.className = "pname";
    name.textContent = p.display_name;
    li.appendChild(name);

    const tags = document.createElement("span");
    tags.className = "tags";
    if (p.user_id === myId) tags.appendChild(tag("you", "tag-you"));
    if (p.user_id === theLeader) tags.appendChild(tag("leader", "tag-leader"));
    if (!isPresent(p)) {
      tags.appendChild(tag("away", "tag-wait"));
    } else {
      tags.appendChild(p.is_ready ? tag("ready", "tag-ready") : tag("not ready", "tag-wait"));
    }
    li.appendChild(tags);

    list.appendChild(li);
  }

  const me = inRoom.find((p) => p.user_id === myId);
  iAmReady = !!(me && me.is_ready);
  el("ready-btn").textContent = iAmReady ? "Cancel ready" : "I'm ready";

  const iAmLeader = theLeader === myId;
  const allReady = present.length >= 2 && present.every((p) => p.is_ready);
  if (iAmLeader) {
    show("start-btn");
    el("start-btn").disabled = !allReady;
  } else {
    hide("start-btn");
  }
}

// --- the game view ----------------------------------------------------------
function renderGame(game, players, lastMove) {
  if (!boardBuilt) buildBoard();

  // We keep every round's history, so the newest move in the table can belong to
  // a round that has already ended. started_at is the line between rounds:
  // anything recorded before it is old news and shouldn't be shown.
  if (lastMove && game.started_at &&
      new Date(lastMove.created_at) < new Date(game.started_at)) {
    lastMove = null;
  }

  const me = players.find((p) => p.user_id === myId);
  const current = players.find((p) => p.seat === game.current_seat);
  const winner = players.find((p) => p.id === game.winner_player_id);

  // Banner: whose turn, or who won.
  const banner = el("turn-banner");
  if (game.status === "finished" && winner) {
    banner.textContent = "🏆 " + winner.display_name + " wins!";
    banner.className = "win";
  } else if (current) {
    const mine = current.user_id === myId;
    banner.textContent = mine ? "Your turn" : current.display_name + "'s turn";
    banner.className = mine ? "mine" : "";
  }

  // The Roll button only works on your turn.
  const myTurn = game.status === "playing" && current && current.user_id === myId;
  el("roll-btn").disabled = !myTurn;
  el("roll-btn").dataset.expectedTurn = game.turn_number + 1;

  // Once someone has won, Roll gives way to "Play again". Anyone may press it.
  const finished = game.status === "finished";
  el("roll-btn").classList.toggle("hidden", finished);
  el("again-btn").classList.toggle("hidden", !finished);
  el("again-btn").disabled = false;

  // What just happened.
  const note = el("last-move");
  if (lastMove) {
    const who = players.find((p) => p.id === lastMove.player_id);
    const name = who ? who.display_name : "Someone";
    let text = lastMove.was_autoplay
      ? "⏱ Time up — rolled " + lastMove.dice + " for " + name
      : name + " rolled " + lastMove.dice;
    if (lastMove.from_position === lastMove.to_position && lastMove.dice > 0) {
      text += " — too high, stayed on " + lastMove.from_position;
    } else if (lastMove.jump_type === "ladder") {
      text += " — ladder! up to " + lastMove.to_position + " 🪜";
    } else if (lastMove.jump_type === "snake") {
      text += " — snake! down to " + lastMove.to_position + " 🐍";
    } else {
      text += " — moved to " + lastMove.to_position;
    }
    note.textContent = text;
  } else {
    note.textContent = "Roll to begin. You need to land exactly on 100 to win.";
  }

  drawTokens(players);
  renderScores(players, game);
}

// Build the 10x10 grid once. Numbering snakes back and forth like a real board:
// 1–10 along the bottom, 11–20 right-to-left above it, and so on.
function buildBoard() {
  const board = el("board");
  board.innerHTML = "";
  for (let row = 9; row >= 0; row--) {
    const leftToRight = row % 2 === 0;
    for (let i = 0; i < 10; i++) {
      const n = row * 10 + (leftToRight ? i + 1 : 10 - i);
      const cell = document.createElement("div");
      cell.className = "cell";
      cell.id = "sq-" + n;

      const num = document.createElement("span");
      num.className = "num";
      num.textContent = n;
      cell.appendChild(num);

      const j = jumps[n];
      if (j) {
        cell.classList.add(j.kind);
        const hint = document.createElement("span");
        hint.className = "hint";
        hint.textContent = (j.kind === "ladder" ? "🪜→" : "🐍→") + j.to;
        cell.appendChild(hint);
      }
      if (n === 100) cell.classList.add("goal");

      const dots = document.createElement("span");
      dots.className = "dots";
      cell.appendChild(dots);

      board.appendChild(cell);
    }
  }
  boardBuilt = true;
}

// Put each player's coloured dot on their square.
function drawTokens(players) {
  document.querySelectorAll("#board .dots").forEach((d) => (d.innerHTML = ""));
  const startRow = el("start-row");
  if (startRow) startRow.innerHTML = "";

  for (const p of players) {
    const dot = document.createElement("span");
    dot.className = "token";
    dot.style.background = SEAT_COLORS[(p.seat - 1) % SEAT_COLORS.length];
    dot.title = p.display_name;
    if (p.user_id === myId) dot.classList.add("me");

    if (p.position === 0) {
      if (startRow) startRow.appendChild(dot);
    } else {
      const cell = el("sq-" + p.position);
      if (cell) cell.querySelector(".dots").appendChild(dot);
    }
  }
}

function renderScores(players, game) {
  const list = el("score-list");
  list.innerHTML = "";
  for (const p of players) {
    const li = document.createElement("li");

    const left = document.createElement("span");
    left.className = "pname";
    const swatch = document.createElement("span");
    swatch.className = "swatch";
    swatch.style.background = SEAT_COLORS[(p.seat - 1) % SEAT_COLORS.length];
    left.appendChild(swatch);
    left.append(p.display_name);
    li.appendChild(left);

    const tags = document.createElement("span");
    tags.className = "tags";
    if (p.user_id === myId) tags.appendChild(tag("you", "tag-you"));
    if (game.status === "playing" && p.seat === game.current_seat) {
      tags.appendChild(tag("turn", "tag-leader"));
    }
    if (!isPresent(p)) tags.appendChild(tag("away", "tag-wait"));
    const sq = document.createElement("span");
    sq.className = "square-num";
    sq.textContent = p.position === 0 ? "start" : p.position;
    tags.appendChild(sq);
    li.appendChild(tags);

    list.appendChild(li);
  }
}

function tag(text, cls) {
  const s = document.createElement("span");
  s.className = "tag " + cls;
  s.textContent = text;
  return s;
}

// --- the countdown ----------------------------------------------------------
// Runs four times a second. It draws the shrinking bar, and when the time is up
// it asks the server to roll for whoever is stalling. Every phone does this, and
// that's fine: the server only ever lets ONE roll through per turn.
function tick() {
  const bar = el("timer-bar");
  const g = lastGame;

  if (!g || g.status !== "playing" || !g.turn_deadline) {
    bar.style.width = "0%";
    return;
  }

  const total = (g.turn_seconds || 20) * 1000;
  const left = new Date(g.turn_deadline).getTime() - serverNow();
  const frac = Math.max(0, Math.min(1, left / total));

  bar.style.width = (frac * 100).toFixed(1) + "%";
  bar.className = left <= 0 ? "out" : frac < 0.34 ? "low" : "";

  // Show the seconds in the banner alongside whose turn it is.
  const current = lastPlayers.find((p) => p.seat === g.current_seat);
  if (current) {
    const secs = Math.max(0, Math.ceil(left / 1000));
    const who = current.user_id === myId ? "Your turn" : current.display_name + "'s turn";
    el("turn-banner").textContent = who + " — " + secs + "s";
  }

  if (left <= 0) nudgeAutoplay();
}

async function nudgeAutoplay() {
  const now = Date.now();
  if (now - lastNudge < 1200) return;      // gentle: at most about once a second
  lastNudge = now;
  await supabase.rpc("autoplay_if_due", { p_game: gameId });
}

setInterval(tick, 250);

// --- buttons ----------------------------------------------------------------
el("join-btn").addEventListener("click", async () => {
  const name = el("name-input").value.trim();
  if (!name) { el("name-input").focus(); return; }
  localStorage.setItem(NAME_KEY, name);
  await joinLobby(name);
});

el("ready-btn").addEventListener("click", async () => {
  await supabase.rpc("set_ready", { p_ready: !iAmReady });
  await refresh();
});

el("start-btn").addEventListener("click", async () => {
  const { error } = await supabase.rpc("start_game");
  if (error) { status(error.message, "error"); }
});

el("roll-btn").addEventListener("click", async () => {
  const btn = el("roll-btn");
  const expected = Number(btn.dataset.expectedTurn) || null;
  btn.disabled = true;                        // stop double taps
  const { error } = await supabase.rpc("roll_dice", { p_expected_turn: expected });
  if (error) { status(error.message, "error"); }
  await refresh();
});

// Put the room back to the lobby after a win. Every phone is already watching
// this room, so they all return to the lobby on their own — no reloading.
el("again-btn").addEventListener("click", async () => {
  el("again-btn").disabled = true;             // stop double taps
  const { error } = await supabase.rpc("play_again");
  if (error) { status(error.message, "error"); }
  await refresh();
});

// Best-effort "I'm leaving" when the tab closes.
window.addEventListener("beforeunload", () => { supabase.rpc("leave_lobby"); });

connect();
