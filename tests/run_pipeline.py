#!/usr/bin/env python3
"""End-to-end test: Auto Seam -> Native Unfold on every fixture.

The seam planner's output is only meaningful if the solver can then produce a
flip-free, low-distortion atlas from it. This runs both workers in sequence and
verifies the final UVs independently.

Usage: python3 tests/run_pipeline.py path/to/RotateUV_AutoSeam path/to/RotateUV_Unfold
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import make_fixtures as mf
import run_tests as rt

# name -> (max seam edges, max stretch)  -- seam cap catches shredding
#
# Two classes of threshold, deliberately:
#   1.01  "the planner produced cuts the solver can unroll EXACTLY". The
#         developable unroll is pure arithmetic, so this is 1.0000 to within
#         floating-point noise on any compiler. Do not loosen it - if one of
#         these regresses, a chart stopped being developable and the planner
#         under-cut something.
#   >1.01 inherently curved surfaces that must go through SLIM. These carry
#         real margin because iterative solver output differs slightly between
#         MSVC and GCC; they are not tight baselines.
EXPECT = {
    "cube":        (12, 1.01),
    "cylinder":    (60, 1.01),
    "lathe":       (130, 1.01),
    "hollow_tube": (140, 1.01),
    "torus":       (40, 2.20),
    "sphere":      (20, 4.50),
}


def main():
    if len(sys.argv) < 3:
        print("usage: run_pipeline.py <autoseam> <unfold>", file=sys.stderr)
        return 2
    seamw, unfoldw = sys.argv[1], sys.argv[2]
    fixdir = mf.OUT
    os.makedirs(fixdir, exist_ok=True)
    failures = 0
    for name in sorted(EXPECT):
        max_seams, max_stretch = EXPECT[name]
        mesh = mf.FIXTURES[name]()
        obj = os.path.join(fixdir, name + ".obj")
        mf.write_obj(mesh, obj)
        seams_path = os.path.join(fixdir, name + ".seams")
        proc = subprocess.run([seamw, obj, seams_path, "7.0"], capture_output=True, text=True)
        if proc.returncode != 0:
            print("%-14s FAIL autoseam exit %d" % (name, proc.returncode))
            failures += 1
            continue
        pairs = []
        for line in open(seams_path):
            tok = line.split()
            if tok and tok[0] == "SEAM":
                pairs.append((int(tok[1]), int(tok[2])))

        # rebuild the fixture with the PLANNER's seams instead of the reference ones
        planned = mf.FIXTURES[name]()
        planned.seams = set((min(a, b), max(a, b)) for (a, b) in pairs)
        ruvu = os.path.join(fixdir, name + ".planned.ruvu")
        planned.write(ruvu)

        out = os.path.join(fixdir, name + ".planned.result")
        proc = subprocess.run([unfoldw, ruvu, out], capture_output=True, text=True)
        if proc.returncode != 0:
            print("%-14s FAIL unfold exit %d: %s" % (name, proc.returncode, proc.stderr.strip()))
            failures += 1
            continue

        verts, faces3d = rt.read_fixture(ruvu)
        header, facesuv = rt.read_result(out)
        a3 = auv = 0.0
        import math
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
        inv = 1.0 / s_opt if s_opt > 1e-15 else 1.0

        worst = 0.0
        pos = neg = 0
        for f3, fuv in zip(faces3d, facesuv):
            for k in range(1, len(f3) - 1):
                p0, p1, p2 = verts[f3[0] - 1], verts[f3[k] - 1], verts[f3[k + 1] - 1]
                u0, u1, u2 = fuv[0][:2], fuv[k][:2], fuv[k + 1][:2]
                s, _ = rt.tri_stretch(p0, p1, p2, u0, u1, u2, inv)
                if s is None:
                    continue
                worst = max(worst, s)
                area = (u1[0] - u0[0]) * (u2[1] - u0[1]) - (u1[1] - u0[1]) * (u2[0] - u0[0])
                if area > 1e-12:
                    pos += 1
                elif area < -1e-12:
                    neg += 1
        flips = min(pos, neg)
        charts = int(header.get("CHARTS", ["0"])[0])
        problems = []
        if len(pairs) > max_seams:
            problems.append("seams %d > %d" % (len(pairs), max_seams))
        if worst > max_stretch:
            problems.append("stretch %.4f > %.4f" % (worst, max_stretch))
        if flips:
            problems.append("flips %d" % flips)
        status = "PASS" if not problems else "FAIL"
        if problems:
            failures += 1
        print("%-14s %-4s seams=%-4d charts=%-2d stretch=%.4f flips=%d %s"
              % (name, status, len(pairs), charts, worst, flips,
                 ("| " + "; ".join(problems)) if problems else ""))
    print("\n%d/%d passed" % (len(EXPECT) - failures, len(EXPECT)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
