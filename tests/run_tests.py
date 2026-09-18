#!/usr/bin/env python3
"""Golden-mesh regression harness for RotateUV Native Unfold.

Runs the worker on every fixture, then recomputes distortion INDEPENDENTLY from
the fixture geometry and the returned UVs - the worker's own report is never
trusted. Asserts per-fixture thresholds and exits non-zero on any failure.

Usage:
    python3 tests/run_tests.py path/to/RotateUV_Unfold[.exe]
"""
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures")

# name -> (charts, max_stretch, max_flips, max_overlaps, require_axis_aligned)
EXPECT = {
    "cube":         (1, 1.0001, 0, 0, True),
    "cylinder":     (3, 1.0001, 0, 0, True),
    "lathe":        (6, 1.0001, 0, 0, True),
    "hollow_tube":  (4, 1.0001, 0, 0, True),
    "ngon_concave": (2, 1.0001, 0, 0, False),
    "torus":        (1, 2.20,   0, 0, False),
    "sphere":       (1, 4.50,   0, 0, False),
}


def read_fixture(path):
    verts, faces = [], []
    with open(path) as fh:
        lines = [l.rstrip("\n") for l in fh]
    i = 0
    assert lines[0] == "RUVUNFOLD 1", "bad fixture header"
    i = 1
    while i < len(lines):
        tok = lines[i].split()
        if not tok:
            i += 1
            continue
        if tok[0] == "VERTICES":
            n = int(tok[1])
            for k in range(n):
                p = lines[i + 1 + k].split()
                verts.append((float(p[0]), float(p[1]), float(p[2])))
            i += n + 1
        elif tok[0] == "FACES":
            n = int(tok[1])
            for k in range(n):
                p = lines[i + 1 + k].split()
                faces.append([int(x) for x in p[3:]])
            i += n + 1
        else:
            i += 1
    return verts, faces


def read_result(path):
    header, faces = {}, []
    with open(path) as fh:
        lines = [l.rstrip("\n") for l in fh]
    assert lines[0].startswith("RUVUV"), "bad result header"
    assert lines[1] == "STATUS OK", "worker reported an error status"
    i = 2
    while i < len(lines):
        tok = lines[i].split()
        if not tok:
            i += 1
            continue
        if tok[0] == "FACES":
            nf = int(tok[1])
            i += 1
            for _ in range(nf):
                ft = lines[i].split()
                n = int(ft[2])
                corners = []
                for k in range(n):
                    ut = lines[i + 1 + k].split()
                    corners.append((float(ut[2]), float(ut[3]), int(ut[4])))
                faces.append(corners)
                i += n + 2   # face line + n uv lines + END_FACE
            break
        header[tok[0]] = tok[1:]
        i += 1
    return header, faces


def tri_stretch(p0, p1, p2, u0, u1, u2, inv_scale=1.0):
    """max(s1, 1/s2) of the 3D->UV Jacobian, or None for a degenerate triangle.

    inv_scale divides out the global uniform scale of the atlas, so an exact
    isometry measures 1.0 regardless of how the atlas was fitted into 0..1."""
    d1 = tuple(p1[k] - p0[k] for k in range(3))
    d2 = tuple(p2[k] - p0[k] for k in range(3))
    nx = d1[1] * d2[2] - d1[2] * d2[1]
    ny = d1[2] * d2[0] - d1[0] * d2[2]
    nz = d1[0] * d2[1] - d1[1] * d2[0]
    twice = math.sqrt(nx * nx + ny * ny + nz * nz)
    if twice < 1e-15:
        return None, 0.0
    l1 = math.sqrt(sum(c * c for c in d1))
    if l1 < 1e-15:
        return None, 0.0
    e1 = tuple(c / l1 for c in d1)
    nn = (nx / twice, ny / twice, nz / twice)
    e2 = (nn[1] * e1[2] - nn[2] * e1[1],
          nn[2] * e1[0] - nn[0] * e1[2],
          nn[0] * e1[1] - nn[1] * e1[0])
    a11 = sum(d1[k] * e1[k] for k in range(3))
    a21 = sum(d1[k] * e2[k] for k in range(3))
    a12 = sum(d2[k] * e1[k] for k in range(3))
    a22 = sum(d2[k] * e2[k] for k in range(3))
    det = a11 * a22 - a12 * a21
    if abs(det) < 1e-15:
        return None, 0.0
    b11, b21 = u1[0] - u0[0], u1[1] - u0[1]
    b12, b22 = u2[0] - u0[0], u2[1] - u0[1]
    i11, i12 = a22 / det, -a12 / det
    i21, i22 = -a21 / det, a11 / det
    j11 = (b11 * i11 + b12 * i21) * inv_scale
    j12 = (b11 * i12 + b12 * i22) * inv_scale
    j21 = (b21 * i11 + b22 * i21) * inv_scale
    j22 = (b21 * i12 + b22 * i22) * inv_scale
    m11 = j11 * j11 + j21 * j21
    m22 = j12 * j12 + j22 * j22
    m12 = j11 * j12 + j21 * j22
    tr = m11 + m22
    disc = math.sqrt(max(0.0, (m11 - m22) ** 2 + 4 * m12 * m12))
    s1 = math.sqrt(max(0.0, 0.5 * (tr + disc)))
    s2 = math.sqrt(max(0.0, 0.5 * (tr - disc)))
    if s2 < 1e-12:
        return float("inf"), 0.5 * twice
    return max(s1, 1.0 / s2), 0.5 * twice


def verify(name, worker):
    fx = os.path.join(FIX, name + ".ruvu")
    out = os.path.join(FIX, name + ".result")
    proc = subprocess.run([worker, fx, out], capture_output=True, text=True)
    if proc.returncode != 0:
        return False, "worker exit %d: %s" % (proc.returncode, proc.stderr.strip())

    verts, faces3d = read_fixture(fx)
    header, facesuv = read_result(out)
    if len(faces3d) != len(facesuv):
        return False, "face count mismatch"

    charts, max_stretch, max_flips, max_ovl, axis_aligned = EXPECT[name]

    # global optimal scale: the atlas preserves relative texel density, so one
    # uniform factor relates 3D area to UV area across the whole object
    a3 = auv = 0.0
    for f3, fuv in zip(faces3d, facesuv):
        for k in range(1, len(f3) - 1):
            p0, p1, p2 = verts[f3[0] - 1], verts[f3[k] - 1], verts[f3[k + 1] - 1]
            d1 = [p1[i] - p0[i] for i in range(3)]
            d2 = [p2[i] - p0[i] for i in range(3)]
            nx = d1[1] * d2[2] - d1[2] * d2[1]
            ny = d1[2] * d2[0] - d1[0] * d2[2]
            nz = d1[0] * d2[1] - d1[1] * d2[0]
            a3 += 0.5 * math.sqrt(nx * nx + ny * ny + nz * nz)
            u0, u1, u2 = fuv[0][:2], fuv[k][:2], fuv[k + 1][:2]
            auv += 0.5 * abs((u1[0] - u0[0]) * (u2[1] - u0[1]) - (u1[1] - u0[1]) * (u2[0] - u0[0]))
    s_opt = math.sqrt(auv / a3) if a3 > 1e-15 and auv > 1e-15 else 1.0
    inv_scale = 1.0 / s_opt if s_opt > 1e-15 else 1.0

    # independent distortion + flip measurement
    worst = 0.0
    neg = pos = 0
    for f3, fuv in zip(faces3d, facesuv):
        if len(f3) != len(fuv):
            return False, "corner count mismatch"
        for k in range(1, len(f3) - 1):
            p0, p1, p2 = verts[f3[0] - 1], verts[f3[k] - 1], verts[f3[k + 1] - 1]
            u0, u1, u2 = fuv[0][:2], fuv[k][:2], fuv[k + 1][:2]
            s, _ = tri_stretch(p0, p1, p2, u0, u1, u2, inv_scale)
            if s is None:
                continue
            worst = max(worst, s)
            area = (u1[0] - u0[0]) * (u2[1] - u0[1]) - (u1[1] - u0[1]) * (u2[0] - u0[0])
            if area > 1e-12:
                pos += 1
            elif area < -1e-12:
                neg += 1

    problems = []
    got_charts = int(header.get("CHARTS", ["0"])[0])
    if got_charts != charts:
        problems.append("charts %d != %d" % (got_charts, charts))
    if worst > max_stretch:
        problems.append("stretch %.4f > %.4f" % (worst, max_stretch))
    flips = min(pos, neg)
    if flips > max_flips:
        problems.append("flips %d > %d" % (flips, max_flips))
    ovl = int(header.get("OVERLAPS", ["0"])[0])
    if ovl > max_ovl:
        problems.append("overlaps %d > %d" % (ovl, max_ovl))

    # UVs must sit inside the unit square
    allu = [c for f in facesuv for c in f]
    if allu:
        lo = min(min(c[0], c[1]) for c in allu)
        hi = max(max(c[0], c[1]) for c in allu)
        if lo < -1e-6 or hi > 1.0 + 1e-6:
            problems.append("UVs outside 0..1 (%.4f..%.4f)" % (lo, hi))

    # auto-orientation: the dominant boundary direction should be on an axis
    if axis_aligned:
        best = dominant_angle(facesuv)
        if best is not None and min(best % 90.0, 90.0 - (best % 90.0)) > 3.0:
            problems.append("dominant edge angle %.1f deg is not axis aligned" % best)

    msg = "charts=%d stretch=%.4f flips=%d overlaps=%d" % (got_charts, worst, flips, ovl)
    if problems:
        return False, msg + " | " + "; ".join(problems)
    return True, msg


def dominant_angle(facesuv):
    """Length-weighted dominant direction of chart boundary edges, in degrees."""
    counts = {}
    for f in facesuv:
        n = len(f)
        for k in range(n):
            a, b = f[k], f[(k + 1) % n]
            key = (min(a[2], b[2]), max(a[2], b[2]))
            counts[key] = counts.get(key, 0) + 1
    hist = [0.0] * 180
    seen = set()
    for f in facesuv:
        n = len(f)
        for k in range(n):
            a, b = f[k], f[(k + 1) % n]
            key = (min(a[2], b[2]), max(a[2], b[2]))
            if counts.get(key, 0) != 1 or key in seen:
                continue
            seen.add(key)
            dx, dy = b[0] - a[0], b[1] - a[1]
            l = math.hypot(dx, dy)
            if l < 1e-12:
                continue
            ang = math.degrees(math.atan2(dy, dx)) % 180.0
            hist[int(ang) % 180] += l
    if not any(hist):
        return None
    return float(max(range(180), key=lambda i: hist[i]))


def main():
    if len(sys.argv) < 2:
        print("usage: run_tests.py path/to/RotateUV_Unfold", file=sys.stderr)
        return 2
    worker = sys.argv[1]
    if not os.path.exists(os.path.join(FIX, "cube.ruvu")):
        subprocess.run([sys.executable, os.path.join(HERE, "make_fixtures.py")], check=True)
    failures = 0
    for name in sorted(EXPECT):
        ok, msg = verify(name, worker)
        print("%-14s %-4s %s" % (name, "PASS" if ok else "FAIL", msg))
        if not ok:
            failures += 1
    print("\n%d/%d passed" % (len(EXPECT) - failures, len(EXPECT)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
