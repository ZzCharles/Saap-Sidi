#!/usr/bin/env python3
"""
cut_snake.py — turn a snake board-run illustration into game-ready parts.

Takes a snake painted on a flat magenta background and outputs:
    <id>_body.png    seamless, tileable body texture (clean, no markings)
    <id>_head.png    head sprite, undistorted
    <id>_tail.png    tail sprite, undistorted
    <id>_blotch.png  one marking, for procedural stamping
    <id>_parts.json  measurements + anchor points

HOW IT WORKS
    Cutting a rectangle out of a curved snake never tiles cleanly. So this
    traces the snake's centreline, samples slices perpendicular to it, and
    straightens the whole snake into a flat strip. The body texture is then
    taken from the most uniform section of that strip and its seam is
    cross-faded, so it tiles invisibly at any length.

USAGE
    # two source images (recommended): clean version + marked version
    python3 cut_snake.py --clean R05.png --marked R06.png --id slick

    # one source image (works fine, body will contain its markings)
    python3 cut_snake.py --clean maya.png --id maya

    # optional
    --out DIR        output folder (default: current)
    --tail-frac 0.13 fraction of the body treated as tail   (raise if tail is long)
    --head-frac 0.86 where the head starts, 0-1 from tail   (lower if head is big)

REQUIREMENTS
    pip install pillow numpy scipy scikit-image
"""

import argparse, json, os
import numpy as np
from PIL import Image
from scipy import ndimage
from scipy.ndimage import map_coordinates, uniform_filter1d
from skimage.morphology import medial_axis
import heapq


def key_magenta(path):
    """Remove the flat magenta background, keep the largest remaining blob."""
    rgb = np.array(Image.open(path).convert('RGB')).astype(int)
    R, G, B = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mag = (R > 150) & (B > 150) & (G < 110) & (np.abs(R - B) < 70)
    m = ~mag
    m = ndimage.binary_opening(m, np.ones((3, 3)))
    m = ndimage.binary_closing(m, np.ones((5, 5)))
    lab, n = ndimage.label(m)
    if n == 0:
        raise SystemExit(f"No subject found in {path} — is the background flat magenta?")
    sizes = ndimage.sum(m, lab, range(1, n + 1))
    m = lab == (np.argmax(sizes) + 1)
    rgba = np.dstack([rgb.astype(np.uint8), (m * 255).astype(np.uint8)]).astype(float)
    return rgba, m


def centreline(mask):
    """Trace the snake from one tip to the other along its medial axis."""
    skel, dist = medial_axis(mask, return_distance=True)
    H, W = skel.shape

    k = np.ones((3, 3)); k[1, 1] = 0
    nb = ndimage.convolve(skel.astype(int), k, mode='constant')
    ends = [tuple(e) for e in np.argwhere(skel & (nb == 1))]
    if len(ends) < 2:
        raise SystemExit("Could not find two tips — the body may cross over itself.")

    def nbrs(y, x):
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dy or dx:
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < H and 0 <= nx < W and skel[ny, nx]:
                        yield (ny, nx), (1.414 if dy and dx else 1.0)

    def far(src):
        D = {src: 0.0}; pq = [(0.0, src)]
        while pq:
            d, u = heapq.heappop(pq)
            if d > D.get(u, 1e18): continue
            for v, w in nbrs(*u):
                nd = d + w
                if nd < D.get(v, 1e18):
                    D[v] = nd; heapq.heappush(pq, (nd, v))
        return D

    # the two tips furthest apart along the skeleton are head and tail
    D0 = far(ends[0])
    a = max((e for e in ends if e in D0), key=lambda e: D0[e])
    Da = far(a)
    b = max((e for e in ends if e in Da), key=lambda e: Da[e])

    prev = {}; D = {a: 0.0}; pq = [(0.0, a)]
    while pq:
        d, u = heapq.heappop(pq)
        if u == b: break
        if d > D.get(u, 1e18): continue
        for v, w in nbrs(*u):
            nd = d + w
            if nd < D.get(v, 1e18):
                D[v] = nd; prev[v] = u; heapq.heappush(pq, (nd, v))
    path = [b]
    while path[-1] != a:
        path.append(prev[path[-1]])
    path.reverse()

    P = np.array([(x, y) for y, x in path], float)
    P[:, 0] = uniform_filter1d(P[:, 0], 41, mode='nearest')
    P[:, 1] = uniform_filter1d(P[:, 1], 41, mode='nearest')
    d = np.r_[0, np.cumsum(np.hypot(*np.diff(P, axis=0).T))]
    N = max(int(d[-1]), 64)
    u = np.linspace(0, d[-1], N)
    C = np.stack([np.interp(u, d, P[:, 0]), np.interp(u, d, P[:, 1])], 1)
    r = np.array([dist[int(round(y)), int(round(x))] for x, y in C])
    r = uniform_filter1d(r, 61, mode='nearest')

    # orient tail -> head: the head end is thicker
    if r[:N // 4].mean() > r[-N // 4:].mean():
        C, r = C[::-1], r[::-1]
    return C, r


def unwrap(rgba, C, half):
    T = np.gradient(C, axis=0)
    T /= np.linalg.norm(T, axis=1, keepdims=True) + 1e-9
    Nr = np.stack([-T[:, 1], T[:, 0]], 1)
    off = np.arange(-half, half + 1)
    X = C[:, 0][:, None] + Nr[:, 0][:, None] * off[None, :]
    Y = C[:, 1][:, None] + Nr[:, 1][:, None] * off[None, :]
    s = np.zeros((len(off), len(C), 4))
    for c in range(4):
        s[..., c] = map_coordinates(rgba[..., c], [Y.T, X.T], order=1, mode='constant')
    return np.clip(s, 0, 255).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--clean', required=True, help='board run without markings (or the only image you have)')
    ap.add_argument('--marked', help='board run with markings, for the blotch stamp')
    ap.add_argument('--id', required=True, help='snake id, e.g. slick')
    ap.add_argument('--out', default='.')
    ap.add_argument('--tail-frac', type=float, default=0.13)
    ap.add_argument('--head-frac', type=float, default=0.86)
    ap.add_argument('--seg', type=int, default=300, help='body segment length in px')
    # Added: on a tightly-coiled snake the perpendicular slice reaches across to
    # the next coil and drags it into the body texture. Dozer and Vyra both came
    # out 241px thick against a real thickness near 114. Lower this until the
    # reported body height is about twice the half-width.
    ap.add_argument('--half-scale', type=float, default=1.9,
                    help='width of the sampling slice, in multiples of body radius')
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    p = lambda n: os.path.join(a.out, f'{a.id}_{n}')

    clean, mask = key_magenta(a.clean)
    marked = key_magenta(a.marked)[0] if a.marked else clean

    C, r = centreline(mask)
    N = len(C)
    # Sample width is based on the BODY (median) radius, not the head (max).
    # Too wide and the perpendicular slice reaches across to an adjacent coil
    # of the S-curve, contaminating the body texture and the spacing measurement.
    half = int(np.median(r) * a.half_scale) + 12
    print(f'  traced {N}px of snake, body half-width ~{np.median(r):.0f}px '
          f'(slice {half}px, expect body ~{int(np.median(r)*2)}px)')

    uc, um = unwrap(clean, C, half), unwrap(marked, C, half)

    # --- the WHOLE snake, straightened, as one continuous strip ---
    # This is the piece that was already being computed and then discarded.
    # Bending this along a spline gives a snake with no joins anywhere, because
    # the head, body and tail were never separated.
    #
    # It needs its OWN sampling width. The body texture wants a narrow slice, so
    # a tight coil does not bleed into it — but a narrow slice shears the head
    # off, because a head is wider than the body it sits on. So this samples out
    # to the widest part of the animal instead.
    half_full = int(r.max() * 1.15) + 10
    full = unwrap(clean, C, half_full)

    # A slice wide enough for the head is also wide enough to catch the next
    # coil of a tight S-curve. In every column, the animal is the unbroken run
    # of pixels through the centreline — anything detached from it belongs to a
    # different part of the snake and is cleared.
    mid = full.shape[0] // 2
    op = full[..., 3] > 24
    keep = np.zeros_like(op)
    for x in range(full.shape[1]):
        col = op[:, x]
        if not col[mid]:
            c = np.flatnonzero(col)                 # centreline just off the art
            if not len(c):
                continue
            start = c[np.argmin(np.abs(c - mid))]
        else:
            start = mid
        top = start
        while top > 0 and col[top - 1]:
            top -= 1
        bot = start
        while bot < len(col) - 1 and col[bot + 1]:
            bot += 1
        # Where two coils TOUCH in the source, that unbroken run carries straight
        # on into the neighbour and drags a slab of it along. The medial axis
        # already knows how wide the animal really is here, so trust it: never
        # keep more than the local radius, with a margin for the snout.
        lim = int(r[min(x, len(r) - 1)] * 1.12) + 4
        top = max(top, mid - lim)
        bot = min(bot, mid + lim)
        keep[top:bot + 1, x] = True
    full[..., 3] = np.where(keep, full[..., 3], 0)

    frows = np.nonzero(full[..., 3].max(axis=1) > 10)[0]
    centre_row = full.shape[0] // 2
    full = full[frows.min():frows.max() + 1]
    full_centre_y = int(centre_row - frows.min())
    Image.fromarray(full, 'RGBA').save(p('full.png'))
    print(f'  full   {full.shape[1]}x{full.shape[0]}  '
          f'(widest radius {r.max():.0f}px, slice {half_full}px)')

    # --- body: flattest window, seam cross-faded so it tiles ---
    w = min(a.seg, int(0.4 * N))
    lo, hi = int(0.25 * N), int(0.80 * N) - w
    best = lo + int(np.argmin([r[i:i + w].std() for i in range(lo, hi)])) if hi > lo else lo
    seg = uc[:, best:best + w].copy()
    rows = np.nonzero(seg[..., 3].max(axis=1) > 10)[0]
    seg = seg[rows.min():rows.max() + 1]
    f = min(40, w // 4)
    ramp = np.linspace(0, 1, f)[None, :, None]
    seg[:, :f] = (seg[:, :f] * ramp + seg[:, -f:] * (1 - ramp)).astype(np.uint8)
    seg = seg[:, :-f]
    Image.fromarray(seg, 'RGBA').save(p('body.png'))

    # --- blotch: darkest spot on the upper flank ---
    lo2, hi2 = max(0, best - 400), min(N, best + 400)
    band = um[:, lo2:hi2]
    lum = band[..., :3].mean(axis=2)
    h = band.shape[0]
    score = np.where((band[..., 3] > 200) & (np.arange(h)[:, None] < h * 0.55), 255 - lum, 0)
    cy, cx = np.unravel_index(np.argmax(ndimage.uniform_filter(score, 25)), score.shape)
    hb = max(30, int(seg.shape[0] * 0.56))
    bl = band[max(0, cy - hb):cy + hb, max(0, cx - hb):cx + hb].copy()
    yy, xx = np.mgrid[0:bl.shape[0], 0:bl.shape[1]]
    dd = np.hypot(yy - bl.shape[0] / 2, xx - bl.shape[1] / 2) / (hb * 0.92)
    bl[..., 3] = (bl[..., 3] * np.clip(1.6 - 1.6 * dd, 0, 1)).astype(np.uint8)
    Image.fromarray(bl, 'RGBA').save(p('blotch.png'))

    # --- blotch spacing, measured off the artwork ---
    lumS = np.array(um[..., :3].mean(axis=2))
    prof = uniform_filter1d(lumS[int(half * .25):int(half * .85)].mean(axis=0), 15)
    s = prof[int(.30 * N):int(.80 * N)]
    mins = [i for i in range(1, len(s) - 1) if s[i] < s[i - 1] and s[i] <= s[i + 1] and s[i] < s.mean() - 4]
    mrg = []
    for m in mins:
        if not mrg or m - mrg[-1] > 40: mrg.append(m)
    spacing = float(np.median(np.diff(mrg))) if len(mrg) > 1 else float(seg.shape[0])

    # --- head & tail from the ORIGINAL curve, undistorted ---
    alpha = clean[..., 3]

    def largest_island(img):
        """A cut sprite should be ONE piece. Anything detached is a fragment of
        another part of the snake that happened to fall inside the crop box."""
        m = img[..., 3] > 24
        lab, n = ndimage.label(m)
        if n <= 1:
            return img, 0
        sizes = ndimage.sum(m, lab, range(1, n + 1))
        keep = lab == (int(np.argmax(sizes)) + 1)
        dropped = int(m.sum() - keep.sum())
        img = img.copy()
        img[..., 3] = np.where(keep, img[..., 3], 0)
        return img, dropped

    def cut(i0, i1, pad=70):
        xs, ys = C[i0:i1, 0], C[i0:i1, 1]
        # The medial-axis radius is the biggest circle that FITS INSIDE the
        # shape, so a snout, jaw or brow reaches further than it. Padding by a
        # flat 30px cropped the face off nearly every sprite; scale with the
        # animal instead.
        rr = r[i0:i1].max() * 1.7 + pad
        x0, y0 = max(0, int(xs.min() - rr)), max(0, int(ys.min() - rr))
        x1, y1 = min(alpha.shape[1], int(xs.max() + rr)), min(alpha.shape[0], int(ys.max() + rr))
        sub = alpha[y0:y1, x0:x1] > 10
        ys2, xs2 = np.nonzero(sub)
        ox, oy = x0 + xs2.min(), y0 + ys2.min()
        img = clean[oy:oy + (ys2.max() - ys2.min() + 1), ox:ox + (xs2.max() - xs2.min() + 1)]
        return img.astype(np.uint8), ox, oy

    hi0, ti1 = int(a.head_frac * N), int(a.tail_frac * N)
    head, hx, hy = cut(hi0, N)
    tail, tx, ty = cut(0, ti1)
    head, hdrop = largest_island(head)
    tail, tdrop = largest_island(tail)
    if hdrop or tdrop:
        print(f'  cleaned stray fragments: head {hdrop}px, tail {tdrop}px')
    Image.fromarray(head, 'RGBA').save(p('head.png'))
    Image.fromarray(tail, 'RGBA').save(p('tail.png'))

    d = np.r_[0, np.cumsum(np.hypot(*np.diff(C, axis=0).T))]

    # The direction the snake is travelling at the neck and at the tail join,
    # in SOURCE image coordinates. The renderer needs this and nothing else to
    # rotate a sprite correctly: turn it by (target tangent - this angle).
    # Deducing it afterwards by measuring the finished PNG does not work — it
    # cannot tell a head from its own mirror image.
    def axis_deg(i):
        j0, j1 = max(0, i - 12), min(len(C) - 1, i + 12)
        dx, dy = C[j1, 0] - C[j0, 0], C[j1, 1] - C[j0, 1]
        return round(float(np.degrees(np.arctan2(dy, dx))), 2)

    man = {
        "id": a.id,
        "files": {k: f'{a.id}_{k}.png' for k in ('body', 'head', 'tail', 'blotch', 'full')},
        "full": {
            "note": "The entire snake straightened into one strip. Bend this along "
                    "a spline for a jointless snake. x is arc length in source px.",
            "file": f'{a.id}_full.png',
            "widthPx": int(full.shape[1]),
            "heightPx": int(full.shape[0]),
            "centreY": full_centre_y,
            "arcLengthPx": round(float(np.r_[0, np.cumsum(np.hypot(*np.diff(C, axis=0).T))][-1]), 1),
        },
        "render": {
            "bodyThicknessPx": int(seg.shape[0]),
            "bodyTextureWidthPx": int(seg.shape[1]),
            "headLengthPx": round(float(d[-1] - d[hi0]), 1),
            "tailLengthPx": round(float(d[ti1]), 1),
            "textureScale": 1.0,
        },
        "anchors": {
            "note": "Pixel within each sprite that sits exactly on the spline endpoint. Rotate about this point to the local tangent.",
            "head": {"x": round(float(C[hi0, 0] - hx), 1), "y": round(float(C[hi0, 1] - hy), 1),
                     "size": [int(head.shape[1]), int(head.shape[0])],
                     "axisDeg": axis_deg(hi0)},
            "tail": {"x": round(float(C[ti1, 0] - tx), 1), "y": round(float(C[ti1, 1] - ty), 1),
                     "size": [int(tail.shape[1]), int(tail.shape[0])],
                     "axisDeg": axis_deg(ti1)},
        },
        "markings": {
            "texture": f'{a.id}_blotch.png',
            "spacingPx": round(spacing, 1),
            "taperStart": 1.0, "taperEnd": 0.5, "rotationJitterDeg": 4,
            "renderOrder": "above body rope, below head and tail",
        },
        "notes": [
            "body.png is seamless — right edge cross-fades into left. Tile or stretch freely.",
            "body.png spans full texture height with no vertical padding; the rope maps texture height to rope width.",
            "head.png and tail.png are cut from the original curved art, so they are undistorted.",
        ],
    }
    json.dump(man, open(p('parts.json'), 'w'), indent=2, default=float)

    print(f'  body   {seg.shape[1]}x{seg.shape[0]}')
    print(f'  head   {head.shape[1]}x{head.shape[0]}')
    print(f'  tail   {tail.shape[1]}x{tail.shape[0]}')
    print(f'  blotch {bl.shape[1]}x{bl.shape[0]}  spacing {spacing:.0f}px')
    print(f'  -> {a.out}/{a.id}_*.png + {a.id}_parts.json')


if __name__ == '__main__':
    main()
