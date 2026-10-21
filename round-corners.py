"""Round the convex corners of every outline in built TTFs, for Spot Mono's soft stroke ends.

Iosevka only draws square stroke ends, so this runs on the finished fonts. Each sharp
outer corner P is replaced by a quadratic curve: on-curve A, off-curve P, on-curve B,
with A and B pulled back from P along each side. The pull-back is capped at half of
each side, so a stem end (one side as long as the stem is wide) becomes a full round.

    round-corners.py [--ratio 0.5] font.ttf...   (modifies the files in place)
"""

import argparse
import math
import sys

from fontTools.ttLib import TTFont
from fontTools.ttLib.tables._g_l_y_f import GlyphCoordinates
from fontTools.ttLib.tables.ttProgram import Program

ON_CURVE = 0x01
# Smoother than this (degrees of turn) is a curve, not a corner.
MIN_TURN = 25
# Glyphs that must keep square corners so they tile across cells.
SHARP_RANGES = [
    (0x2500, 0x259F),    # box drawing, blocks, shades
    (0x25E2, 0x25FF),    # corner triangles
    (0x2800, 0x28FF),    # braille
    (0xE0A0, 0xE0FF),    # powerline
    (0x1FB00, 0x1FBFF),  # legacy computing mosaics
]


def stem_width(font):
    """Width of n's stems: the shortest flat segment on n's baseline."""
    glyf = font["glyf"]
    g = glyf[font.getBestCmap()[ord("n")]]
    coords, ends, flags = g.getCoordinates(glyf)
    best = math.inf
    start = 0
    for end in ends:
        pts = list(range(start, end + 1))
        for i, j in zip(pts, pts[1:] + pts[:1]):
            (x1, y1), (x2, y2) = coords[i], coords[j]
            if y1 == y2 == 0 and flags[i] & ON_CURVE and flags[j] & ON_CURVE:
                best = min(best, abs(x2 - x1))
        start = end + 1
    return best


def round_contour(pts, radius):
    """pts: list of (x, y, on). Returns the new list with convex corners rounded."""
    n = len(pts)
    if n < 3:
        return pts
    area = sum(pts[i][0] * pts[(i + 1) % n][1] - pts[(i + 1) % n][0] * pts[i][1] for i in range(n))

    def walk(i, step, r):
        """From corner i, go r units along the outline (step -1 = backwards).
        Returns (point, tangent, off-curve indices passed). A straight side gives up at
        most half its length; a curved side stops at its next on-curve point."""
        px, py, _ = pts[i]
        q = pts[(i + step) % n]
        if q[2]:
            d = math.hypot(q[0] - px, q[1] - py)
            t = min(r, d / 2)
            ux, uy = (q[0] - px) / d, (q[1] - py) / d
            return (px + ux * t, py + uy * t), (ux, uy), []
        passed, dist, prev, k = [], 0.0, (px, py), i
        for _ in range(n - 1):
            k = (k + step) % n
            qx, qy, q_on = pts[k]
            seg = math.hypot(qx - prev[0], qy - prev[1])
            if seg > 0:
                ux, uy = (qx - prev[0]) / seg, (qy - prev[1]) / seg
                if dist + seg >= r:
                    t = r - dist
                    return (prev[0] + ux * t, prev[1] + uy * t), (ux, uy), passed
                if q_on:
                    return (qx, qy), (ux, uy), passed + [k]
            passed.append(k)
            dist += seg
            prev = (qx, qy)
        return None

    plans, used = {}, set()
    for i, (x, y, on) in enumerate(pts):
        if not on:
            continue
        px, py, p_on = pts[i - 1]
        nx, ny, n_on = pts[(i + 1) % n]
        ax, ay, bx, by = px - x, py - y, nx - x, ny - y
        la, lb = math.hypot(ax, ay), math.hypot(bx, by)
        if la == 0 or lb == 0:
            continue
        # turn between incoming direction (-a) and outgoing direction (b)
        cos_turn = (-ax * bx - ay * by) / (la * lb)
        turn = math.degrees(math.acos(max(-1.0, min(1.0, cos_turn))))
        cross = (-ax) * by - (-ay) * bx
        if turn < MIN_TURN or cross * area <= 0:
            continue
        r = min(radius, la / 2 if p_on else radius, lb / 2 if n_on else radius)
        if r < 2:
            continue
        before, after = walk(i, -1, r), walk(i, 1, r)
        if not before or not after:
            continue
        (a, ta, pa), (b, tb, pb) = before, after
        claimed = set(pa) | set(pb) | {i}
        if claimed & used:
            continue
        used |= claimed
        plans[i] = (a, control_point(a, ta, b, tb, (x, y), r), b, claimed)

    skip = set().union(*(p[3] for p in plans.values())) if plans else set()
    out = []
    for i, pt in enumerate(pts):
        if i in plans:
            a, c, b, _ = plans[i]
            out += [(a[0], a[1], True), (c[0], c[1], False), (b[0], b[1], True)]
        elif i not in skip:
            out.append(pt)
    return out


def control_point(a, ta, b, tb, corner, r):
    """Where the outline's tangents at a and b cross, so the round joins both smoothly.
    Falls back to the original corner when they're near-parallel or cross far away."""
    det = ta[0] * tb[1] - ta[1] * tb[0]
    if abs(det) > 1e-6:
        s = ((b[0] - a[0]) * tb[1] - (b[1] - a[1]) * tb[0]) / det
        c = (a[0] + ta[0] * s, a[1] + ta[1] * s)
        if math.hypot(c[0] - corner[0], c[1] - corner[1]) <= r:
            return c
    return corner


def process(path, ratio):
    font = TTFont(path)
    glyf, hmtx = font["glyf"], font["hmtx"]
    radius = stem_width(font) * ratio
    sharp = {name for cp, name in font.getBestCmap().items()
             if any(lo <= cp <= hi for lo, hi in SHARP_RANGES)}
    changed = 0
    for name in font.getGlyphOrder():
        g = glyf[name]
        if name in sharp or g.isComposite() or g.numberOfContours <= 0:
            continue
        coords, ends, flags = g.getCoordinates(glyf)
        new_coords, new_flags, new_ends = [], [], []
        start = 0
        for end in ends:
            pts = [(coords[k][0], coords[k][1], bool(flags[k] & ON_CURVE)) for k in range(start, end + 1)]
            for x, y, on in round_contour(pts, radius):
                new_coords.append((round(x), round(y)))
                new_flags.append(ON_CURVE if on else 0)
            new_ends.append(len(new_coords) - 1)
            start = end + 1
        if len(new_coords) != len(coords):
            changed += 1
        g.coordinates = GlyphCoordinates(new_coords)
        g.flags = bytearray(new_flags)
        g.endPtsOfContours = new_ends
        g.program = Program()
        g.program.fromBytecode(b"")
        g.recalcBounds(glyf)
        adv, _ = hmtx[name]
        hmtx[name] = (adv, g.xMin)
    font.save(path)
    print(f"{path}: radius {radius:.0f}, rounded {changed} glyphs")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ratio", type=float, default=0.5, help="corner radius as a fraction of the stem width (0.5 = fully round ends)")
    ap.add_argument("fonts", nargs="+")
    args = ap.parse_args()
    for path in args.fonts:
        process(path, args.ratio)


if __name__ == "__main__":
    sys.exit(main())
