// Saap-Sidi service worker.
//
// Its ONE required job is to make the game installable as a real app.
// Its optional job is to keep a spare copy of the files so a poor signal
// doesn't leave you staring at a blank page.
//
// IMPORTANT: this is deliberately "network first". We always try to fetch the
// real, current file, and only fall back to the stored copy if the network
// fails. A "cache first" worker would keep showing an old version of the game
// after we publish a change, which looks exactly like a bug but isn't.
//
// When we publish a change, bump APP_VERSION here AND in index.html.

const APP_VERSION = "1.0.0";
const CACHE = "saap-sidi-" + APP_VERSION;

// The handful of files the game needs to draw its first screen.
const SHELL = [
  "./",
  "./index.html",
  "./style.css",
  "./game.js",
  "./config.js",
  "./manifest.webmanifest",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
];

// On install: grab a spare copy of the shell, then take over immediately
// rather than waiting for every tab to close.
self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE)
      .then((cache) => cache.addAll(SHELL))
      .then(() => self.skipWaiting())
  );
});

// On activate: throw away every older version's cache, so a bumped
// APP_VERSION genuinely wipes the old files instead of layering on top.
self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((names) => Promise.all(
        names.filter((n) => n !== CACHE).map((n) => caches.delete(n))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;

  // Only ever handle our own files being read. Anything going to Supabase or
  // the Supabase code library is left completely alone — live game data must
  // never come from a cache.
  if (req.method !== "GET") return;
  if (new URL(req.url).origin !== self.location.origin) return;

  event.respondWith(
    fetch(req)
      .then((res) => {
        // Keep a fresh spare copy for next time.
        const copy = res.clone();
        caches.open(CACHE).then((cache) => cache.put(req, copy)).catch(() => {});
        return res;
      })
      .catch(async () => {
        // Offline. Serve the stored copy. ignoreSearch so that game.js and
        // "game.js?v=1.0.0" count as the same file.
        const hit = await caches.match(req, { ignoreSearch: true });
        if (hit) return hit;
        // A page navigation with nothing stored: fall back to the main page.
        if (req.mode === "navigate") {
          const home = await caches.match("./index.html");
          if (home) return home;
        }
        return Response.error();
      })
  );
});
