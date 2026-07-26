// Saap-Sidi — the phone side.
//
// This half only DISPLAYS the game and SENDS button taps. The server decides
// every dice roll, whose turn it is, and whether a move is legal. That is the
// anti-cheat guarantee, and nothing in this file is allowed to weaken it.
//
// The one rule that shapes everything below: the server is the truth, and the
// screen is a slightly-behind picture of it. We never move a token because we
// think it should move — we move it because a move row appeared.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const APP_V = new URL(import.meta.url).searchParams.get("v") || "";
const { SUPABASE_URL, SUPABASE_ANON_KEY } = await import("./config.js?v=" + APP_V);

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// --- little helpers ---------------------------------------------------------
const el = (id) => document.getElementById(id);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const pick = (a) => a[Math.floor(Math.random() * a.length)];

function screen(id) {
  document.querySelectorAll(".screen").forEach((s) => s.classList.remove("on"));
  el(id).classList.add("on");
}
function status(msg, kind) {
  const s = el("status");
  if (s) { s.textContent = msg; s.className = "status-line " + (kind || ""); }
}

const NAME_KEY = "saap_name";
const SOUND_KEY = "saap_sound";

// One colour per seat, up to 8 players. Pulled from the board's own pigments so
// the tokens belong to the painting rather than sitting on top of it.
const SEAT_COLORS = [
  "#E3B341", "#2F5570", "#C0442E", "#6E8B4A",
  "#B06FA8", "#D97E2B", "#4C9AA8", "#9A6BC4",
];

let myId = null;      // this phone's hidden ID
let gameId = null;    // the game we're in
let channel = null;
let heartbeatTimer = null;
let iAmReady = false;
let pendingDoor = null;   // which door they tapped before we knew their name

let JUMPS = {};       // square -> { to, kind, name }
let boardDrawn = false;

let lastGame = null;
let lastPlayers = [];

// How far along the story the SCREEN is. The server may already be ahead.
let shownTurn = -1;
let animating = false;
let botNudgedForTurn = -1;

// Phones' clocks are often wrong. We measure the difference against the
// server's so the countdown everyone sees matches the real deadline.
let clockOffset = 0;
const serverNow = () => Date.now() + clockOffset;
let lastNudge = 0;

// Who counts as actually here. Must stay in step with player_is_present() in
// the database (0008). 45 seconds, because browsers freeze background tabs and
// a friend glancing at their messages is still sitting right there.
const AWAY_AFTER_MS = 45000;
const isPresent = (p) =>
  p.is_bot || (p.is_connected &&
    serverNow() - new Date(p.last_seen_at).getTime() < AWAY_AFTER_MS);

/* ===========================================================================
   THE BOARD — geometry
   =========================================================================== */

// Numbering snakes back and forth from the bottom left, like a real board.
function cellOf(n) {
  const row = Math.floor((n - 1) / 10), idx = (n - 1) % 10;
  return { row, col: row % 2 === 0 ? idx : 9 - idx };
}
const cx = (n) => (cellOf(n).col + 0.5) * 100;
const cy = (n) => (9 - cellOf(n).row + 0.5) * 100;

const NS = "http://www.w3.org/2000/svg";
function svg(tag, attrs) {
  const e = document.createElementNS(NS, tag);
  for (const k in attrs) e.setAttribute(k, attrs[k]);
  return e;
}

// A seeded random, so the painted detail is identical every time. It should
// look hand-made, not be different on every phone.
let seed = 20260727;
const rnd = () => (seed = (seed * 1664525 + 1013904223) % 4294967296) / 4294967296;

/* ===========================================================================
   THE BOARD — the painted surface
   Five bands: water, jungle, ruins, temple, and light at the shrine.
   =========================================================================== */
function paintZones() {
  const art = el("zoneart");
  art.innerHTML = "";
  seed = 20260727;

  const BANDS = [
    { from: 0, to: 1, fill: "#16232B" },   // riverbank
    { from: 2, to: 4, fill: "#17231A" },   // jungle
    { from: 5, to: 6, fill: "#221C17" },   // ruins
    { from: 7, to: 8, fill: "#241C12" },   // temple
    { from: 9, to: 9, fill: "#2A1710" },   // shrine
  ];

  const defs = svg("defs", {});
  art.appendChild(defs);

  BANDS.forEach((b) => {
    art.appendChild(svg("rect", {
      x: 0, y: (9 - b.to) * 100, width: 1000, height: (b.to - b.from + 1) * 100,
      fill: b.fill,
    }));
  });

  // Bleed each seam into the next — hard lines make the board read as stacked
  // stripes, when the climb should feel like one place becoming another.
  for (let i = 0; i < BANDS.length - 1; i++) {
    const lower = BANDS[i], upper = BANDS[i + 1];
    const gid = "seam" + i;
    const g = svg("linearGradient", { id: gid, x1: "0", y1: "0", x2: "0", y2: "1" });
    g.appendChild(svg("stop", { offset: "0", "stop-color": upper.fill, "stop-opacity": "1" }));
    g.appendChild(svg("stop", { offset: "0.5", "stop-color": upper.fill, "stop-opacity": ".5" }));
    g.appendChild(svg("stop", { offset: "1", "stop-color": lower.fill, "stop-opacity": "0" }));
    defs.appendChild(g);
    art.appendChild(svg("rect", {
      x: 0, y: (9 - lower.to) * 100 - 46, width: 1000, height: 92, fill: `url(#${gid})`,
    }));
  }

  // Riverbank: slow water.
  for (let i = 0; i < 9; i++) {
    const y = 810 + rnd() * 180;
    let d = `M0 ${y}`;
    for (let x = 60; x <= 1000; x += 60) d += ` Q${x - 30} ${y + (rnd() - .5) * 22}, ${x} ${y}`;
    art.appendChild(svg("path", {
      d, fill: "none", stroke: "#4C7E9C", "stroke-width": 1.6,
      opacity: (.10 + rnd() * .16).toFixed(2),
    }));
  }

  // Jungle: leaves, and vines trailing out of the canopy.
  for (let i = 0; i < 54; i++) {
    const x = rnd() * 1000, y = 500 + rnd() * 300, r = 14 + rnd() * 26, a = rnd() * 360;
    art.appendChild(svg("path", {
      d: `M${x} ${y} q${r * .55} ${-r * .5}, ${r * 1.5} 0 q${-r * .55} ${r * .5}, ${-r * 1.5} 0 Z`,
      fill: "#4E6B39", opacity: (.10 + rnd() * .20).toFixed(2),
      transform: `rotate(${a} ${x} ${y})`,
    }));
  }
  for (let i = 0; i < 7; i++) {
    const x = rnd() * 1000, y0 = 500 + rnd() * 60, len = 90 + rnd() * 130;
    art.appendChild(svg("path", {
      d: `M${x} ${y0} q${(rnd() - .5) * 60} ${len * .5}, ${(rnd() - .5) * 40} ${len}`,
      fill: "none", stroke: "#5C7A44", "stroke-width": 2, opacity: ".2",
    }));
  }

  // Ruins: fallen blocks.
  for (let i = 0; i < 26; i++) {
    const x = rnd() * 960, y = 305 + rnd() * 175, w = 30 + rnd() * 58, h = 16 + rnd() * 22;
    art.appendChild(svg("rect", {
      x, y, width: w, height: h, rx: 2, fill: "none", stroke: "#8A7960",
      "stroke-width": 1.3, opacity: (.10 + rnd() * .16).toFixed(2),
      transform: `rotate(${(rnd() - .5) * 12} ${x + w / 2} ${y + h / 2})`,
    }));
  }

  // Temple: carved lattice.
  for (let gx = 0; gx <= 1000; gx += 50) {
    for (let gy = 100; gy <= 300; gy += 50) {
      art.appendChild(svg("path", {
        d: `M${gx} ${gy - 17} L${gx + 17} ${gy} L${gx} ${gy + 17} L${gx - 17} ${gy} Z`,
        fill: "none", stroke: "#C9A251", "stroke-width": 1, opacity: ".14",
      }));
    }
  }

  // Shrine: light spilling down from the top.
  const glow = svg("radialGradient", { id: "shrineGlow", cx: "50%", cy: "100%", r: "80%" });
  glow.appendChild(svg("stop", { offset: "0", "stop-color": "#E3B341", "stop-opacity": ".26" }));
  glow.appendChild(svg("stop", { offset: "1", "stop-color": "#E3B341", "stop-opacity": "0" }));
  defs.appendChild(glow);
  art.appendChild(svg("rect", { x: 0, y: 0, width: 1000, height: 130, fill: "url(#shrineGlow)" }));
  for (let i = 0; i < 13; i++) {
    art.appendChild(svg("path", {
      d: `M500 0 L${40 + i * 78} 122`, stroke: "#E3B341", "stroke-width": 1,
      opacity: (.05 + rnd() * .07).toFixed(2),
    }));
  }

  // Worn cloth grain, generated rather than downloaded.
  for (let i = 0; i < 240; i++) {
    art.appendChild(svg("rect", {
      x: rnd() * 1000, y: rnd() * 1000, width: 1 + rnd() * 3, height: 1 + rnd() * 2,
      fill: rnd() > .5 ? "#FFFFFF" : "#000000", opacity: (.02 + rnd() * .05).toFixed(3),
    }));
  }
}

/* ===========================================================================
   THE BOARD — the snakes and the ladders, drawn from the server's own data.
   Move one in the database and the picture follows.
   =========================================================================== */
function paintPaths() {
  const paths = el("paths");
  paths.innerHTML = "";

  const all = Object.entries(JUMPS).map(([from, j]) => ({ from: +from, ...j }));
  const ladders = all.filter((j) => j.kind === "ladder");
  // The King sits on two squares feeding one snake; draw the body once.
  const seenSnake = new Set();
  const snakes = all.filter((j) => {
    if (j.kind !== "snake") return false;
    const key = j.name + ">" + j.to;
    if (seenSnake.has(key)) return false;
    seenSnake.add(key);
    return true;
  });

  ladders.forEach((l) => {
    const x1 = cx(l.from), y1 = cy(l.from), x2 = cx(l.to), y2 = cy(l.to);
    const dx = x2 - x1, dy = y2 - y1, len = Math.hypot(dx, dy) || 1;
    const px = (-dy / len) * 16, py = (dx / len) * 16;
    const g = svg("g", {});
    [[px, py], [-px, -py]].forEach(([ox, oy]) => {
      g.appendChild(svg("line", { x1: x1 + ox, y1: y1 + oy, x2: x2 + ox, y2: y2 + oy,
        stroke: "#6B4E19", "stroke-width": 7.5, "stroke-linecap": "round" }));
      g.appendChild(svg("line", { x1: x1 + ox, y1: y1 + oy, x2: x2 + ox, y2: y2 + oy,
        stroke: "#D6A845", "stroke-width": 4.5, "stroke-linecap": "round" }));
    });
    const rungs = Math.max(3, Math.round(len / 68));
    for (let i = 1; i < rungs; i++) {
      const t = i / rungs, mx = x1 + dx * t, my = y1 + dy * t;
      g.appendChild(svg("line", { x1: mx + px, y1: my + py, x2: mx - px, y2: my - py,
        stroke: "#5A4115", "stroke-width": 6, "stroke-linecap": "round" }));
      g.appendChild(svg("line", { x1: mx + px, y1: my + py, x2: mx - px, y2: my - py,
        stroke: "#C0973C", "stroke-width": 3.4, "stroke-linecap": "round" }));
    }
    paths.appendChild(g);
  });

  snakes.forEach((s) => {
    const x1 = cx(s.from), y1 = cy(s.from), x2 = cx(s.to), y2 = cy(s.to);
    const mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
    const dx = x2 - x1, dy = y2 - y1, len = Math.hypot(dx, dy) || 1;
    // A gentle S. A big bend looks lively on one snake and turns into
    // spaghetti once seven of them share a board.
    const bend = Math.min(78, len * 0.19);
    const nx = (-dy / len) * bend, ny = (dx / len) * bend;
    const big = s.name === "The King";
    const d = `M${x1} ${y1} C${mx + nx} ${my + ny}, ${mx - nx} ${my - ny}, ${x2} ${y2}`;
    const g = svg("g", {});

    g.appendChild(svg("path", { d, fill: "none", stroke: "#5E1C10",
      "stroke-width": big ? 21 : 16, "stroke-linecap": "round" }));
    g.appendChild(svg("path", { d, fill: "none", stroke: "#B33F2A",
      "stroke-width": big ? 15 : 11, "stroke-linecap": "round" }));
    g.appendChild(svg("path", { d, fill: "none", stroke: "#E9B08C", "stroke-width": 4,
      "stroke-dasharray": "3 17", opacity: ".5", "stroke-linecap": "round" }));
    g.appendChild(svg("path", { d, fill: "none", stroke: "#F2D3A0", "stroke-width": 1.4,
      "stroke-dasharray": "1.5 20", opacity: ".45", "stroke-linecap": "round" }));

    // The head points the way the body leaves it. Drawn as a tapered wedge with
    // slit eyes — two dots on a circle reads as a smiley face, which is the one
    // thing a snake must never look like.
    const ang = Math.atan2((my + ny) - y1, (mx + nx) - x1) * 180 / Math.PI;
    const rot = `rotate(${ang} ${x1} ${y1})`;
    const hw = big ? 21 : 15, hh = big ? 14 : 10;

    if (big) {
      g.appendChild(svg("ellipse", { cx: x1 + 3, cy: y1, rx: 17, ry: 23, fill: "#7E2B1B",
        stroke: "#E3B341", "stroke-width": 1.4, transform: rot, opacity: ".95" }));
    }
    g.appendChild(svg("path", {
      d: `M${x1 - hw} ${y1} Q${x1 - hw * .2} ${y1 - hh}, ${x1 + hw * .95} ${y1 - hh * .38}
          Q${x1 + hw * 1.15} ${y1}, ${x1 + hw * .95} ${y1 + hh * .38}
          Q${x1 - hw * .2} ${y1 + hh}, ${x1 - hw} ${y1} Z`,
      fill: big ? "#A83A26" : "#96331F", stroke: "#E3B341",
      "stroke-width": big ? 1.4 : 1, transform: rot,
    }));
    g.appendChild(svg("path", {
      d: `M${x1 + hw * 1.1} ${y1} l7 0 m0 0 l4 -2.6 m-4 2.6 l4 2.6`,
      stroke: "#E3574A", "stroke-width": 1.6, fill: "none",
      "stroke-linecap": "round", transform: rot,
    }));
    [-1, 1].forEach((side) => {
      g.appendChild(svg("ellipse", { cx: x1 + hw * .25, cy: y1 + side * hh * .42,
        rx: 3, ry: 1.5, fill: "#150B07", transform: rot }));
    });
    paths.appendChild(g);
  });
}

function buildBoard() {
  const board = el("board");
  board.innerHTML = "";
  for (let row = 9; row >= 0; row--) {
    for (let i = 0; i < 10; i++) {
      const n = row * 10 + (row % 2 === 0 ? i + 1 : 10 - i);
      const cell = document.createElement("div");
      cell.className = "cell" + (n === 100 ? " goal" : "");
      const num = document.createElement("span");
      num.className = "num";
      num.textContent = n;
      cell.appendChild(num);
      board.appendChild(cell);
    }
  }
  paintZones();
  paintPaths();
  boardDrawn = true;
}

/* ===========================================================================
   THE DICE
   =========================================================================== */
const PIPS = {
  1: [[2,2]], 2: [[1,1],[3,3]], 3: [[1,1],[2,2],[3,3]],
  4: [[1,1],[1,3],[3,1],[3,3]], 5: [[1,1],[1,3],[2,2],[3,1],[3,3]],
  6: [[1,1],[1,2],[1,3],[3,1],[3,2],[3,3]],
};
const FACE_TF = {
  1: "rotateY(0deg) translateZ(29px)",   6: "rotateY(180deg) translateZ(29px)",
  2: "rotateY(90deg) translateZ(29px)",  5: "rotateY(-90deg) translateZ(29px)",
  3: "rotateX(90deg) translateZ(29px)",  4: "rotateX(-90deg) translateZ(29px)",
};
// To bring a face to the front you apply the OPPOSITE of the turn that put it
// where it is. Then a small tilt off both axes, so two more faces stay in view
// and the thing reads as a solid cube rather than a flat card.
const TILT_X = -16, TILT_Y = -20;
const BASE = { 1:[0,0], 6:[0,180], 2:[0,-90], 5:[0,90], 3:[-90,0], 4:[90,0] };
const faceAngles = (n) => [BASE[n][0] + TILT_X, BASE[n][1] + TILT_Y];
let curX = 0, curY = 0;

function buildDice() {
  const cube = el("cube");
  cube.innerHTML = "";
  for (let f = 1; f <= 6; f++) {
    const face = document.createElement("div");
    face.className = "face";
    face.style.transform = FACE_TF[f];
    PIPS[f].forEach(([r, c]) => {
      const p = document.createElement("div");
      p.className = "pip" + (f === 1 ? " red" : "");   // the one is painted red
      p.style.gridArea = r + " / " + c;
      face.appendChild(p);
    });
    cube.appendChild(face);
  }
  showFace(4);
}
function showFace(n) {
  [curX, curY] = faceAngles(n);
  el("cube").style.transform = `rotateX(${curX}deg) rotateY(${curY}deg)`;
}
// Built in script rather than as fixed CSS so it always finishes on the number
// the SERVER rolled. Every keyframe is the same pair of turns, which is what
// stops the tumble taking odd paths.
function throwDice(n) {
  const [ax, ay] = faceAngles(n);
  const tx = ax + 720, ty = ay + 720;
  const anim = el("cube").animate([
    { transform: `translateY(0px) rotateX(${curX}deg) rotateY(${curY}deg) scale(1)`, offset: 0 },
    { transform: `translateY(-30px) rotateX(${curX + 300}deg) rotateY(${curY + 240}deg) scale(1.05)`, offset: .28 },
    { transform: `translateY(-6px) rotateX(${tx - 40}deg) rotateY(${ty - 30}deg) scale(1)`, offset: .68 },
    { transform: `translateY(3px) rotateX(${tx}deg) rotateY(${ty}deg) scale(.96)`, offset: .85 },
    { transform: `translateY(-4px) rotateX(${tx}deg) rotateY(${ty}deg) scale(1.02)`, offset: .93 },
    { transform: `translateY(0px) rotateX(${tx}deg) rotateY(${ty}deg) scale(1)`, offset: 1 },
  ], { duration: 950, easing: "cubic-bezier(.3,.7,.35,1)", fill: "forwards" });
  anim.finished.then(() => { anim.cancel(); showFace(n); }).catch(() => {});
}

/* ===========================================================================
   SOUND — synthesised here and now. No files, nothing to download, no licence.
   =========================================================================== */
let AC = null;
let soundOn = localStorage.getItem(SOUND_KEY) !== "off";
const ac = () => (AC ||= new (window.AudioContext || window.webkitAudioContext)());

function noise(dur, freq, q, gain, when = 0) {
  if (!soundOn) return;
  try {
    const c = ac(), t = c.currentTime + when;
    const n = c.createBufferSource();
    const buf = c.createBuffer(1, Math.max(1, Math.floor(c.sampleRate * dur)), c.sampleRate);
    const dat = buf.getChannelData(0);
    for (let i = 0; i < dat.length; i++) dat[i] = (Math.random() * 2 - 1) * (1 - i / dat.length);
    n.buffer = buf;
    const f = c.createBiquadFilter();
    f.type = "bandpass"; f.frequency.value = freq; f.Q.value = q;
    const g = c.createGain();
    g.gain.setValueAtTime(gain, t);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    n.connect(f); f.connect(g); g.connect(c.destination);
    n.start(t); n.stop(t + dur);
  } catch (e) { /* audio is a nicety; never let it break the game */ }
}
function tone(freq, dur, gain, when = 0, type = "triangle", slideTo = null) {
  if (!soundOn) return;
  try {
    const c = ac(), t = c.currentTime + when;
    const o = c.createOscillator(), g = c.createGain();
    o.type = type; o.frequency.setValueAtTime(freq, t);
    if (slideTo) o.frequency.exponentialRampToValueAtTime(slideTo, t + dur);
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(gain, t + 0.012);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    o.connect(g); g.connect(c.destination);
    o.start(t); o.stop(t + dur + 0.02);
  } catch (e) { /* as above */ }
}
const sfxRoll = () => [0,.09,.17,.27,.38,.5,.62].forEach((w, i) =>
  noise(.05, 850 + Math.random() * 1300, 4, .13 - i * .012, w));
const sfxLand = () => { noise(.13, 210, 2.5, .3); tone(88, .15, .17, 0, "sine", 54); };
const sfxStep = (i) => tone(420 + i * 32, .06, .055, i * .08, "square");
const sfxLadder = () => [0,1,2,3,4].forEach((i) =>
  tone(392 * Math.pow(2, i / 5), .28, .11, .04 + i * .065, "triangle"));
const sfxSnake = () => { tone(520, .7, .16, 0, "sawtooth", 90); noise(.65, 2500, 1.2, .09); };
const sfxWin = () => [0,2,4,7,9].forEach((s, i) =>
  tone(440 * Math.pow(2, s / 12), .5, .13, i * .11, "triangle"));

function setSound(on) {
  soundOn = on;
  localStorage.setItem(SOUND_KEY, on ? "on" : "off");
  const b = el("snd-btn");
  b.setAttribute("aria-pressed", String(on));
  b.textContent = on ? "Sound on" : "Sound off";
  if (on) tone(660, .1, .1);
}

/* ===========================================================================
   TOKENS
   =========================================================================== */
const shownPos = {};      // player id -> the square the SCREEN currently shows

const PAWN = 8.4;                      // token size, as a % of the board
// Never let a token hang off the edge — a square in column 1 plus a fan offset
// used to push it clean out of the frame.
const onBoard = (v) => Math.max(0.4, Math.min(100 - PAWN - 0.4, v));

function pawnXY(player, index) {
  const pos = shownPos[player.id] ?? 0;
  if (pos === 0) return { l: onBoard(1.2 + index * 9), t: 95.5 - PAWN / 2 };
  // Several tokens can share a square, so fan them out around its centre.
  const fan = ((index % 4) - 1.5) * 2.3;
  return {
    l: onBoard(cx(pos) / 10 + fan - PAWN / 2),
    t: onBoard(cy(pos) / 10 - PAWN / 2),
  };
}

function drawTokens(players) {
  const host = el("pawns");
  players.forEach((p, i) => {
    let d = document.getElementById("pawn-" + p.id);
    if (!d) {
      d = document.createElement("div");
      d.id = "pawn-" + p.id;
      d.className = "pawn";
      host.appendChild(d);
    }
    d.style.background = SEAT_COLORS[(p.seat - 1) % SEAT_COLORS.length];
    d.title = p.display_name;
    d.classList.toggle("me", p.user_id === myId);
    d.classList.toggle("benched", !!p.is_benched);
    const q = pawnXY(p, i);
    d.style.left = q.l + "%";
    d.style.top = q.t + "%";
    d.style.opacity = (shownPos[p.id] ?? 0) === 0 ? ".55" : "";
  });
  // Anyone who left the room takes their token with them.
  const live = new Set(players.map((p) => "pawn-" + p.id));
  [...host.children].forEach((c) => { if (!live.has(c.id)) c.remove(); });
}

/* ===========================================================================
   WHAT JUST HAPPENED — told on the board, then gone
   =========================================================================== */
function callName(square, text, kind) {
  const host = el("board-inner");
  const e = document.createElement("div");
  e.className = "namecall " + kind;
  e.textContent = text;
  // Sit it clear of the square: the token is still standing there.
  e.style.left = Math.min(80, Math.max(20, cx(square) / 10)) + "%";
  e.style.top = Math.max(6, cy(square) / 10 - 7) + "%";
  host.appendChild(e);
  void e.offsetWidth; e.classList.add("go");
  setTimeout(() => e.remove(), 1600);
}

function speak(player, index, text) {
  const host = el("board-inner");
  const e = document.createElement("div");
  e.className = "bubble";
  e.textContent = text;
  const q = pawnXY(player, index);
  // Keep it on the board, and low enough that there is room above the token.
  e.style.left = Math.min(78, Math.max(22, q.l + 4.2)) + "%";
  e.style.top = Math.max(14, q.t) + "%";
  host.appendChild(e);
  void e.offsetWidth; e.classList.add("go");
  setTimeout(() => e.remove(), 3600);
}

// Written to be read fast, mid-game, by someone who is losing.
function lineFor(name, mine, move, jump) {
  const who = mine ? "You" : name;
  const dice = move.dice;
  const final = move.to_position;

  if (final === 100) return pick([
    `${mine ? "You land" : who + " lands"} on 100 exactly. Insufferable already.`,
    `That's it. Somebody check that dice.`,
  ]);
  if (move.was_autoplay && !jump) return pick([
    `Time up. Rolled a ${dice} for ${mine ? "you" : who}.`,
    `${who} ${mine ? "were" : "was"} asleep. ${dice}, and on to ${final}.`,
  ]);
  if (jump && jump.kind === "snake") {
    if (jump.name === "The King") return pick([
      `The King. From the top of the board to the bottom of it.`,
      `Ninety-eight to twenty-four. We'll give ${mine ? "you" : who} a moment.`,
      `There is no polite way to describe what just happened.`,
    ]);
    return pick([
      `Walked straight into ${jump.name}. Bold.`,
      `${jump.name} barely had to move.`,
      `Rolled a ${dice}, found ${jump.name}. Oops.`,
      `Back to ${final}. ${jump.name} says thanks.`,
    ]);
  }
  if (jump && jump.kind === "ladder") {
    if (jump.name === "The Golden Stair") return pick([
      `The Golden Stair. Everyone saw it. ${who} got there first.`,
      `Straight up the Golden Stair. Unbearable.`,
    ]);
    return pick([
      `${jump.name}, all the way to ${final}. Show-off.`,
      `Up on ${jump.name}. Undeserved, frankly.`,
      `${jump.name} to ${final}. Lucky.`,
    ]);
  }
  if (move.from_position === move.to_position)
    return `Overshot. ${mine ? "You need" : who + " needs"} exactly ${100 - final}.`;
  if (dice === 6) return pick([`A six, and nothing happened. Anticlimax.`, `Six. Straight to ${final}.`]);
  if (dice === 1) return pick([`A one. One.`, `One square. Progress of a sort.`]);
  return pick([`${dice}. Now on ${final}.`, `Moves to ${final}. Riveting.`, `${dice}, and that's that.`]);
}

/* ===========================================================================
   PLAYING A MOVE OUT ON SCREEN

   Nothing here decides anything. It is handed a move row that the server has
   already committed, and its only job is to show it happening.
   =========================================================================== */
async function playMove(move, players) {
  animating = true;
  const idx = players.findIndex((p) => p.id === move.player_id);
  const who = players[idx];
  if (!who) { animating = false; return; }

  const mine = who.user_id === myId;

  document.body.classList.add("rolling");
  el("dice-shadow").classList.add("rolling");
  sfxRoll();
  throwDice(move.dice);
  await wait(800);
  sfxLand();
  await wait(260);
  el("dice-shadow").classList.remove("rolling");
  document.body.classList.remove("rolling");

  // Walk it, square by square, from where the screen had them.
  const from = move.from_position;
  const landed = move.from_position === move.to_position
    ? move.from_position                       // overshot: never left the square
    : (JUMPS[from + move.dice] ? from + move.dice : move.to_position);

  if (landed !== from) {
    for (let s = from + 1; s <= landed; s++) {
      shownPos[who.id] = s;
      drawTokens(players);
      sfxStep(s - from - 1);
      await wait(105);
    }
  }

  const jump = move.jump_type !== "none" ? JUMPS[landed] : null;
  if (jump) {
    await wait(240);
    callName(landed, jump.name, jump.kind);
    await wait(300);
    shownPos[who.id] = move.to_position;
    drawTokens(players);
    jump.kind === "snake" ? sfxSnake() : sfxLadder();
    await wait(430);
  } else {
    shownPos[who.id] = move.to_position;
    drawTokens(players);
  }

  speak(who, idx, lineFor(who.display_name, mine, move, jump));
  if (move.to_position === 100) sfxWin();

  shownTurn = move.turn_number;
  animating = false;
}

/* ===========================================================================
   TALKING TO THE SERVER
   =========================================================================== */
async function connect() {
  status("Connecting…");
  let { data: { session } } = await supabase.auth.getSession();
  if (!session) {
    const { error } = await supabase.auth.signInAnonymously();
    if (error) { status("Could not connect: " + error.message, "error"); return; }
    ({ data: { session } } = await supabase.auth.getSession());
  }
  myId = session.user.id;

  await loadBoard();
  await syncClock();
  status("Ready", "ok");
}

async function syncClock() {
  const before = Date.now();
  const { data } = await supabase.rpc("server_now");
  const after = Date.now();
  if (data) clockOffset = new Date(data).getTime() - (before + (after - before) / 2);
}

// The board comes from the server so every phone shares one truth — including
// the names, which is what lets the game tell you who caught you.
async function loadBoard() {
  const { data } = await supabase.from("board_jumps").select("*");
  JUMPS = {};
  for (const j of data || []) {
    JUMPS[j.from_square] = { to: j.to_square, kind: j.kind, name: j.name || "" };
  }
}

async function enterGame(id) {
  gameId = id;
  shownTurn = -1;
  botNudgedForTurn = -1;
  Object.keys(shownPos).forEach((k) => delete shownPos[k]);
  if (!boardDrawn) buildBoard();
  await subscribe();
  await refresh();
  startHeartbeat();
}

async function subscribe() {
  if (channel) await supabase.removeChannel(channel);
  channel = supabase.channel("game-" + gameId)
    .on("postgres_changes", { event: "*", schema: "public", table: "players",
        filter: "game_id=eq." + gameId }, refresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "games",
        filter: "id=eq." + gameId }, refresh)
    .on("postgres_changes", { event: "*", schema: "public", table: "moves",
        filter: "game_id=eq." + gameId }, refresh)
    .subscribe();
}

function startHeartbeat() {
  if (heartbeatTimer) clearInterval(heartbeatTimer);
  heartbeatTimer = setInterval(() => { supabase.rpc("heartbeat"); }, 5000);
}
function stopHeartbeat() {
  if (heartbeatTimer) clearInterval(heartbeatTimer);
  heartbeatTimer = null;
}

let refreshing = false;
async function refresh() {
  if (!gameId || refreshing) return;
  refreshing = true;
  try {
    const [{ data: game }, { data: players }, { data: moves }] = await Promise.all([
      supabase.from("games").select("*").eq("id", gameId).single(),
      supabase.from("players").select("*").eq("game_id", gameId).order("seat"),
      supabase.from("moves").select("*").eq("game_id", gameId)
        .order("turn_number", { ascending: false }).limit(1),
    ]);
    if (!game) return;
    await render(game, players || [], (moves || [])[0] || null);
  } finally {
    refreshing = false;
  }
}

/* ===========================================================================
   DRAWING THE CURRENT STATE
   =========================================================================== */
async function render(game, players, lastMove) {
  lastGame = game;
  lastPlayers = players;

  if (game.status === "waiting") {
    screen("lobby-screen");
    renderLobby(game, players);
    return;
  }

  screen("game-screen");

  // We keep every round's history, so the newest move can belong to a round
  // that has already ended. started_at is the line between rounds.
  if (lastMove && game.started_at &&
      new Date(lastMove.created_at) < new Date(game.started_at)) {
    lastMove = null;
  }

  // First sight of this game (or a reconnect): snap to the truth, no animation.
  if (shownTurn < 0) {
    players.forEach((p) => { shownPos[p.id] = p.position; });
    shownTurn = lastMove ? lastMove.turn_number : game.turn_number;
    drawTokens(players);
  } else if (lastMove && !animating && lastMove.turn_number > shownTurn) {
    if (lastMove.turn_number === shownTurn + 1) {
      await playMove(lastMove, players);       // the very next move: play it out
    } else {
      // We missed some (asleep, or a slow connection). Catch up silently rather
      // than replaying a story nobody watched.
      players.forEach((p) => { shownPos[p.id] = p.position; });
      shownTurn = lastMove.turn_number;
      drawTokens(players);
    }
  } else if (!animating) {
    players.forEach((p) => { shownPos[p.id] = p.position; });
    drawTokens(players);
  }

  renderGameChrome(game, players);
  maybeNudgeBot(game, players);
}

function renderGameChrome(game, players) {
  const current = players.find((p) => p.seat === game.current_seat);
  const winner = players.find((p) => p.id === game.winner_player_id);
  const banner = el("turn-banner");
  const finished = game.status === "finished";

  if (finished && winner) {
    const mine = winner.user_id === myId;
    banner.innerHTML = `<span class="dot" style="background:${
      SEAT_COLORS[(winner.seat - 1) % SEAT_COLORS.length]}"></span>` +
      (mine ? "You win" : winner.display_name + " wins");
    banner.className = "whoseturn win";
  } else if (current) {
    const mine = current.user_id === myId;
    banner.innerHTML = `<span class="dot" style="background:${
      SEAT_COLORS[(current.seat - 1) % SEAT_COLORS.length]}"></span>` +
      (mine ? "Your turn" : current.display_name + (current.is_bot ? " is thinking" : "'s turn"));
    banner.className = "whoseturn";
  }

  const myTurn = game.status === "playing" && current && current.user_id === myId;
  el("roll-btn").disabled = !myTurn || animating;
  el("roll-btn").dataset.expectedTurn = game.turn_number + 1;
  el("roll-btn").classList.toggle("hidden", finished);
  el("again-btn").classList.toggle("hidden", !finished);
  el("again-btn").disabled = false;
  if (finished) el("fuse-bar").style.width = "0%";

  el("score-list").innerHTML = players.map((p) => {
    const c = SEAT_COLORS[(p.seat - 1) % SEAT_COLORS.length];
    const tags = [];
    if (p.user_id === myId) tags.push('<span class="tag tag-you">you</span>');
    if (p.is_bot) tags.push('<span class="tag tag-wait">computer</span>');
    if (p.is_benched) tags.push('<span class="tag tag-wait">out</span>');
    else if (!isPresent(p)) tags.push('<span class="tag tag-wait">away</span>');
    return `<li class="${p.seat === game.current_seat && !finished ? "up" : ""}${
      p.is_benched ? " out" : ""}">
        <i style="background:${c}"></i>
        <span class="who">${escapeHtml(p.display_name)}${tags.join("")}</span>
        <b>${p.position}</b>
      </li>`;
  }).join("");
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

// The computer has no phone, so somebody's phone has to ask on its behalf. The
// server refuses unless it really is a bot's turn, so this cannot steal a roll.
function maybeNudgeBot(game, players) {
  if (game.status !== "playing" || animating) return;
  const current = players.find((p) => p.seat === game.current_seat);
  if (!current || !current.is_bot) return;
  if (botNudgedForTurn === game.turn_number) return;
  botNudgedForTurn = game.turn_number;
  // A pause, so the opponent appears to think rather than answer instantly.
  setTimeout(() => { supabase.rpc("play_bot_turn", { p_game: gameId }); }, 1100);
}

function renderLobby(game, players) {
  const inRoom = players.filter((p) => p.is_connected);
  const present = inRoom.filter(isPresent);
  const leader = present.length
    ? (present.find((p) => p.user_id === game.owner_user_id) ||
       present.slice().sort((a, b) => a.seat - b.seat)[0]).user_id
    : null;

  el("player-list").innerHTML = inRoom.map((p) => {
    const c = SEAT_COLORS[(p.seat - 1) % SEAT_COLORS.length];
    const tags = [];
    if (p.user_id === myId) tags.push('<span class="tag tag-you">you</span>');
    if (p.user_id === leader) tags.push('<span class="tag tag-leader">leader</span>');
    if (!isPresent(p)) tags.push('<span class="tag tag-wait">away</span>');
    else tags.push(p.is_ready
      ? '<span class="tag tag-ready">ready</span>'
      : '<span class="tag tag-wait">not ready</span>');
    return `<li class="${p.user_id === myId ? "is-me" : ""}">
        <span class="pname"><span class="swatch" style="background:${c}"></span>${
          escapeHtml(p.display_name)}</span>
        <span class="tags">${tags.join("")}</span>
      </li>`;
  }).join("");

  const me = inRoom.find((p) => p.user_id === myId);
  iAmReady = !!(me && me.is_ready);
  el("ready-btn").textContent = iAmReady ? "Cancel ready" : "I'm ready";

  const allReady = present.length >= 2 && present.every((p) => p.is_ready);
  el("start-btn").classList.toggle("hidden", leader !== myId);
  el("start-btn").disabled = !allReady;
  el("lobby-hint").textContent = present.length < 2
    ? "Waiting for at least one more player. Share the link and they'll land here."
    : allReady
      ? (leader === myId ? "Everyone's ready. Start when you like."
                         : "Everyone's ready. Waiting for the leader to start.")
      : "Waiting for everyone to press ready.";
}

/* ===========================================================================
   THE COUNTDOWN
   Runs four times a second. Draws the burning fuse, and when time is up asks
   the server to roll for whoever is stalling. Every phone does this, and that
   is fine: the server only ever lets ONE roll through per turn.
   =========================================================================== */
function tick() {
  const g = lastGame, bar = el("fuse-bar");
  if (!bar) return;
  if (!g || g.status !== "playing" || !g.turn_deadline) { bar.style.width = "0%"; return; }

  const total = (g.turn_seconds || 15) * 1000;
  const left = new Date(g.turn_deadline).getTime() - serverNow();
  const frac = Math.max(0, Math.min(1, left / total));
  bar.style.width = (frac * 100).toFixed(1) + "%";
  bar.className = frac < 0.34 ? "low" : "";

  if (left <= 0) nudgeAutoplay();
}
async function nudgeAutoplay() {
  const now = Date.now();
  if (now - lastNudge < 1200) return;
  lastNudge = now;
  await supabase.rpc("autoplay_if_due", { p_game: gameId });
}
setInterval(tick, 250);

/* ===========================================================================
   BUTTONS
   =========================================================================== */
function savedName() { return (localStorage.getItem(NAME_KEY) || "").trim(); }

async function goThroughDoor(which) {
  const name = savedName();
  if (!name) { pendingDoor = which; screen("name-screen"); el("name-input").focus(); return; }

  el("solo-btn").disabled = true;
  el("lobby-btn").disabled = true;
  status(which === "solo" ? "Dealing a game…" : "Joining the room…");
  try {
    if (which === "solo") {
      const { data, error } = await supabase.rpc("start_solo_game", {
        p_display_name: name, p_bot_name: "Chotu",
      });
      if (error) throw error;
      await enterGame(data);
    } else {
      const { data, error } = await supabase.rpc("join_lobby", { p_display_name: name });
      if (error) throw error;
      await enterGame(data);
    }
  } catch (e) {
    status(e.message || String(e), "error");
    screen("welcome-screen");
  } finally {
    el("solo-btn").disabled = false;
    el("lobby-btn").disabled = false;
  }
}

el("solo-btn").addEventListener("click", () => goThroughDoor("solo"));
el("lobby-btn").addEventListener("click", () => goThroughDoor("lobby"));

el("name-go").addEventListener("click", async () => {
  const name = el("name-input").value.trim();
  if (!name) { el("name-input").focus(); return; }
  localStorage.setItem(NAME_KEY, name);
  // If we somehow got here without knowing which door was tapped, go BACK and
  // ask. The old default was "lobby", which meant an unexplained press of this
  // button could quietly walk you into the shared room with strangers — a
  // surprise, and exactly the kind of thing that is miserable to debug later.
  const door = pendingDoor;
  pendingDoor = null;
  if (!door) { screen("welcome-screen"); return; }
  await goThroughDoor(door);
});
el("name-input").addEventListener("keydown", (e) => {
  if (e.key === "Enter") el("name-go").click();
});

el("ready-btn").addEventListener("click", async () => {
  await supabase.rpc("set_ready", { p_ready: !iAmReady });
  await refresh();
});

el("start-btn").addEventListener("click", async () => {
  const { error } = await supabase.rpc("start_game");
  if (error) status(error.message, "error");
});

el("roll-btn").addEventListener("click", async () => {
  const btn = el("roll-btn");
  const expected = Number(btn.dataset.expectedTurn) || null;
  btn.disabled = true;                                  // stop double taps
  if (soundOn) ac().resume?.();                         // phones need a tap first
  const { error } = await supabase.rpc("roll_in_game", {
    p_game: gameId, p_expected_turn: expected,
  });
  if (error) status(error.message, "error");
  await refresh();
});

el("again-btn").addEventListener("click", async () => {
  el("again-btn").disabled = true;
  const { error } = await supabase.rpc("play_again");
  if (error) status(error.message, "error");
  shownTurn = -1;                                       // next round starts fresh
  await refresh();
});

el("snd-btn").addEventListener("click", () => setSound(!soundOn));

document.querySelectorAll("[data-back]").forEach((b) => {
  b.addEventListener("click", async () => {
    if (gameId) { await supabase.rpc("leave_lobby"); }
    if (channel) { await supabase.removeChannel(channel); channel = null; }
    stopHeartbeat();
    gameId = null; lastGame = null; lastPlayers = [];
    screen("welcome-screen");
    status("Ready", "ok");
  });
});

// Coming back after the app was in the background. Our ping has almost
// certainly stopped, so say hello at once — that is also what takes us off the
// bench — then re-check the clock, which drifts while frozen, and redraw.
document.addEventListener("visibilitychange", async () => {
  if (document.visibilityState !== "visible" || !gameId) return;
  await supabase.rpc("heartbeat");
  await syncClock();
  await refresh();
});

window.addEventListener("beforeunload", () => {
  if (gameId) supabase.rpc("leave_lobby");
});

/* =========================================================================== */
buildDice();
setSound(soundOn);
connect();
