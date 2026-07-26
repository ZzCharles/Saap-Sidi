# Saap-Sidi app icons

Six files, all generated from your cobra artwork. Drop the whole
`saap-icons` folder into the project (or copy the files to wherever
Claude Code says the public/static folder is).

## What each file is for

| File | Used by |
|---|---|
| `icon-512.png` | Android install icon (large), app store listings |
| `icon-192.png` | Android install icon (standard) |
| `icon-180.png` | iPhone / iPad "Add to Home Screen" |
| `icon-32.png` | Browser tab favicon |
| `icon-16.png` | Browser tab favicon (small) |
| `icon-maskable-512.png` / `icon-maskable-192.png` | Android when it crops icons into circles or squircles — art is inset so the gold frame never gets sliced off |

## Give this to Claude Code

Paste the following so it wires the icons up correctly:

> I've added an icons folder to the project with the app icon in several
> sizes: icon-512.png, icon-192.png, icon-180.png, icon-32.png, icon-16.png,
> plus icon-maskable-512.png and icon-maskable-192.png.
>
> Please wire these up properly so the game installs as a real app on both
> Android and iPhone (fullscreen, no browser address bar, correct icon on the
> home screen). That means:
>
> 1. A web app manifest listing the 192 and 512 icons as `purpose: "any"`,
>    and the two maskable files as `purpose: "maskable"`.
> 2. `display: "standalone"` and a dark background/theme colour that matches
>    the artwork (near-black, roughly #0d1410).
> 3. The Apple-specific tags in the HTML head so iPhone works too
>    (`apple-touch-icon` pointing at icon-180.png,
>    `apple-mobile-web-app-capable`, status bar style, and app title
>    "Saap-Sidi").
> 4. Favicon links for the 32 and 16 files.
>
> Android reads the manifest and ignores the Apple tags; iPhone does the
> opposite — so both sets need to be present at the same time.
