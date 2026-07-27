# SNAKE RENDER SPEC v1.0
*Asset cutting procedure + renderer contract. Companion to the Art Bible.*

**Purpose:** define exactly what files the art pipeline delivers and exactly how the client consumes them, so one illustration per snake serves any board path, any length, plus the swallow animation.

**Status:** unproven. Build this for **Slick only** and validate against §7 before generating any further snakes.

---

## 1. THE CORE IDEA

Do not tile segments manually. Use a **deforming rope mesh**: one body texture stretched and bent along a spline between two board squares.

```
        ┌─ head sprite (anchored t=0, rotated to tangent)
        │
   ●━━━━━━━━━━━━━━━━━━━━━━━━━━●
   │    └─ body: rope mesh along spline    └─ tail sprite (t=1)
   │
   └─ blotch stamps: placed at even arc-length intervals, rotated to tangent
```

Four independent pieces sharing one spline. Every snake in the game uses this system; only the textures and parameters change.

**Why this works:** the body texture is deliberately uniform and featureless (R05), so stretching it produces no visible artefact. All the rhythm lives in the separately-placed stamps, which never stretch.

---

## 2. ASSET MANIFEST

What art delivers per snake. All PNG, transparent, premultiplied alpha off.

```
assets/snakes/slick/
  head.png            1024×1024   head + neck, tapering to a flat cut edge
  body.png             512×256    uniform mid-section, seamless L↔R
  tail.png             512×512    taper, flat cut edge at the thick end
  blotch.png           128×128    ONE saddle blotch, centred, soft-edged
  belly_hint.png       512×256    optional: extra belly banding overlay
  head_jaw_upper.png   1024×1024  swallow anim
  head_jaw_lower.png   1024×1024  swallow anim
  mouth_interior.png    512×512   dark throat
  eye_L.png / eye_R.png            64×64    sclera + iris
  pupil_L.png / pupil_R.png        32×32    separate, for eye tracking
  eyelid_L.png / eyelid_R.png      64×64    for blink
  tongue.png           256×128    for flick
  shadow_body.png      512×256    soft, greyscale, rope-mapped
  shadow_head.png     1024×1024
```

Plus one JSON per snake (§5).

---

## 3. CUTTING PROCEDURE (manual, image editor)

From **R05** (clean, unmarked) and **R06** (marked reference).

### 3.1 Prep R05
1. Key out magenta `#FF00FF`. Use *select by colour* with ~20% tolerance, then contract the selection 1px and feather 0.5px to kill the fringe.
2. Paint out the four-point sparkle artifact.
3. Deepen shadows ~10% to match Vyra's tonal register.

### 3.2 Cut `body.png`
1. Find the **straightest, most uniform** run of body in R05 — the long lower-left stretch is best.
2. Select a rectangle across it, perpendicular to the body axis at both cut edges. Rotate the canvas first so the body runs perfectly horizontal — this matters, a skewed cut will never tile.
3. **Seamlessness test:** duplicate the cut, place copies edge to edge. Any visible seam in the silhouette, the belly stripe, or the form shading → recut. Iterate until invisible.
4. The body must span the **full height** of the texture with no vertical padding. The rope maps texture height to rope width; padding becomes phantom thickness.
5. Bake in: belly stripe, two-tone form shade, banding. **Do NOT bake in blotches.**

### 3.3 Cut `head.png`
- Include the head and enough neck to blend. Cut edge must be **perpendicular to the neck axis** and match `body.png`'s thickness and vertical alignment exactly.
- Feather the cut edge 2–3px so it dissolves into the rope rather than hard-butting it.

### 3.4 Cut `tail.png`
- Same rules at the thick end. Blunt the fine tip — at 25% scale a hair-fine point aliases into a broken speck.

### 3.5 Cut `blotch.png`
- Take **one** blotch from R06, centred in the canvas, alpha-cut with a soft edge.
- Neutral orientation: long axis horizontal.

### 3.6 Registration constants
Record these; the renderer needs them.

| Constant | Meaning |
|---|---|
| `bodyThicknessPx` | Height of the body silhouette in `body.png` |
| `headJoinY` | Y of the neck centreline in `head.png` |
| `tailJoinY` | Y of the join centreline in `tail.png` |
| `headJoinX` | X of the cut edge in `head.png` |

---

## 4. RENDERER

### 4.1 Library
PixiJS. The relevant primitive is a **rope mesh** — `MeshRope` in Pixi v8, `SimpleRope` in v7. It accepts a texture and an array of points and deforms the texture along that path.

*[Verify the exact class name against the installed Pixi version — this API was renamed between major versions.]*

**Limitation to know up front:** the stock rope has a *fixed* width. The swallow bulge needs per-vertex width, so §6 replaces it with a custom mesh. Build with the stock rope first to validate the path math, then swap.

### 4.2 Pipeline

**Step 1 — Path.** Read control points from the snake's JSON (board-space, normalised 0–1). Fit a **Catmull-Rom spline** through them. Catmull-Rom because it passes *through* its control points, so an artist placing points on the board gets exactly what they placed.

**Step 2 — Resample.** Convert to a uniform **arc-length** parameterisation. This is the step people skip and it causes everything downstream to be wrong — raw spline `t` is not proportional to distance, so markings bunch on curves and the body stretches unevenly. Resample to ~1 point per 8px of arc length.

**Step 3 — Trim.** The rope covers only the middle. Trim `headLengthPx` from the start and `tailLengthPx` from the end; those regions belong to the head and tail sprites.

**Step 4 — Body.** Feed the trimmed points to the rope with `body.png`. Set the texture to repeat horizontally and set `textureScale` so the texture tiles at natural size rather than stretching to fit — a 2000px snake should show ~4 repeats of a 512px texture, not one 4× stretched copy.

**Step 5 — Head & tail.** Position at the spline endpoints, rotate to the local tangent, offset by the registration constants so the join lines up.

**Step 6 — Blotches.** For `d = spacingPx` to `totalLength - tailLengthPx`, step `spacingPx`:
- position = point at arc-length `d`
- rotation = tangent angle at `d`
- scale = `taper(d / totalLength)` — a curve from 1.0 near the head to ~0.5 at the tail
- optional: alternate a small ± rotation jitter (~4°) so it reads organic, not mechanical

Blotches render **above** the body rope, **below** head and tail.

**Step 7 — Shadow.** Same rope, `shadow_body.png`, offset ~6px down-right, rendered beneath everything, alpha ~0.35.

### 4.3 Z-order (bottom to top)
```
board tiles
snake shadow
snake body rope
snake blotches
snake tail
snake body overlaps  (if the path self-crosses — see §8)
snake head
setpiece_front       (leaves/stone that occlude the snake)
player pawns
```

---

## 5. DATA SCHEMA

One file per snake. Path control points are authored by hand against the board.

```jsonc
{
  "id": "slick",
  "name": "Slick",
  "headSquare": 46,
  "tailSquare": 25,
  "menaceTier": 3,
  "animTier": "standard",

  "path": {
    // normalised board space, 0,0 = bottom-left of board
    "controlPoints": [
      { "x": 0.52, "y": 0.46 },   // head end
      { "x": 0.44, "y": 0.40 },
      { "x": 0.38, "y": 0.33 },
      { "x": 0.45, "y": 0.28 },
      { "x": 0.42, "y": 0.24 }    // tail end
    ]
  },

  "render": {
    "bodyThicknessPx": 56,
    "headLengthPx": 220,
    "tailLengthPx": 180,
    "textureScale": 1.0
  },

  "markings": {
    "texture": "blotch.png",
    "spacingPx": 96,
    "taperStart": 1.0,
    "taperEnd": 0.5,
    "rotationJitterDeg": 4
  },

  "swallow": {
    "tier": "standard",
    "durationMs": 2000,
    "tellId": "grin_widen",
    "bulgeScale": 1.45,
    "sfx": "slick_chuckle"
  }
}
```

**Authoring note:** control points are hand-placed, not derived from square numbers. A snake auto-routed as a straight line between two squares will look like a rendering bug. The curve is art direction.

---

## 6. THE BULGE

Same spline. This is the payoff for building it properly.

The bulge is a **width modulation travelling along the rope** — which the stock fixed-width rope cannot do. Replace it with a custom mesh where you generate vertices yourself:

For each point `i` at arc-length `d_i`, half-width is:
```
w_i = bodyThickness/2 * (1 + (bulgeScale - 1) * gauss(d_i, bulgePos, bulgeWidth))
```
where `gauss` is a normalised Gaussian and `bulgePos` animates from `0` to `totalLength` over the swallow duration.

Offset each vertex along the path **normal** by `±w_i`. Everything else — UVs, triangle indices — is identical to a standard rope.

**Consequences worth knowing:**
- Blotch **scale** should modulate with the local bulge factor too, or markings will look painted on a balloon.
- Blotch **spacing** should not — the skin stretches, it doesn't grow new blotches.
- The bulge must reach the tail *before* the pawn pops out. Reserve the last ~150ms for the ejection beat.
- Keep the Gaussian width around 2–3× body thickness. Narrower reads as a lump; wider reads as the whole snake inflating.

---

## 7. ACCEPTANCE TESTS

The pipeline is proven when all seven pass. **Do not generate another snake until then.**

| # | Test | Pass condition |
|---|---|---|
| 1 | Render Slick at his real path (46→25) | No visible seam anywhere along the body |
| 2 | Render the same snake at 2× and 0.5× path length | Texture repeats change; no stretching, no seams |
| 3 | Blotch rhythm at three different lengths | Spacing stays constant in pixels; no bunching on curves |
| 4 | Head and tail joins | No gap, no overlap, no thickness step |
| 5 | Sharp curve (radius < 2× body thickness) | Body doesn't pinch, fold, or invert |
| 6 | Bulge travel head→tail | Smooth, continuous, no popping; blotches scale with it |
| 7 | Downscale board to 1024px | Head expression still readable; blotches still read as blotches |

**Test 5 is the one that will fail.** Rope meshes pinch on tight curves. If it does: cap the authored curvature in the path data (validate at load, warn on violation), or increase resampling density in high-curvature regions.

---

## 8. SELF-CROSSING PATHS

Some snakes' paths will cross themselves. The rope renders as a single mesh, so the crossing point will look flat and wrong.

**Simplest fix:** forbid it. Add a load-time validation that rejects self-intersecting control points, and author around it. Costs nothing.

**If a crossing is required** (Old Root or the King may want it for drama): split the path into two ropes at the crossing point and render them at different z-indices, with a small hand-authored shadow at the overlap.

Recommend forbidding it for v2 and revisiting only for the King.

---

## 9. BUILD ORDER

1. Static rope with `body.png` along a hardcoded path. Nothing else. *Does it bend without tearing?*
2. Arc-length resampling. *Do markings stay evenly spaced on curves?*
3. Head + tail joins.
4. Blotch placement with taper.
5. Shadow pass.
6. JSON-driven — load path from data, not hardcoded.
7. Swap to custom mesh, add the bulge.
8. Run §7 acceptance tests.
9. **Only now** generate the remaining six snakes.

Steps 1–2 are the whole risk. If they work, the rest is assembly.
