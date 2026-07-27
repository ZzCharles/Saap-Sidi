# Art

Two folders, and the difference between them matters.

## `source/` — the master illustrations

Full paintings, roughly 1400×768, on a magenta `#FF00FF` background. These are
what the art chat produces. **Nothing in here is ever served to players** — the
whole folder is about 20 MB, and a phone would be downloading a snake fifty
times larger than it will ever be drawn.

They are kept because they are the masters. Every cut sprite can be re-made from
them; none of them can be re-made from a cut sprite.

```
source/snakes/<name>/board.png      the snake laid out in an S-curve, for cutting
source/snakes/<name>/portrait.png   head-and-shoulders, for the bestiary
source/snakes/kaal/awake.png        Kaal is the hidden snake, so he has two states
source/snakes/kaal/asleep.png       — carved stonework until he is triggered
source/board/tiles.png              painted stone number tiles
source/reference/art-style.png      the style these were all drawn to
```

## `cut/` — the game-ready sprites

The output of the cutting procedure in `docs/snake-render-spec.md` §3. Small,
transparent, and designed so one illustration serves a snake of any length: the
body tiles along a spline, the head and tail sit on its ends.

```
cut/<name>/body.png       uniform mid-section, seamless left-to-right
cut/<name>/head.png       head + neck, flat cut edge matching body thickness
cut/<name>/tail.png       the taper, flat cut edge at its thick end
cut/<name>/blotch.png     one marking, stamped along the body at intervals
cut/<name>/manifest.json  measurements and anchor points the renderer needs
```

Only **Slick** has been cut so far, and he is the proving ground: the spec says
not to cut the others until his acceptance tests pass.

## What is missing

- **The King** — no artwork yet, neither board nor portrait.
- **Slick has no `board.png`** in `source/`, because his was cut before this
  folder existed. Worth putting the original back here if it still exists.
- **`slick/portrait.jpg` is the only JPG.** JPG cannot store transparency, so if
  that portrait ever needs a cut-out background it will have to be re-exported
  as PNG.

## A naming note

The database and `board-config.json` both call her **Vyra**. The delivered files
said *Vayra*. They are the same snake; the folder here uses `vyra` so that code
reading a snake's id from the database finds the right directory without a
translation table. If the art side prefers *Vayra*, the database is the thing to
change — one spelling, one place.
