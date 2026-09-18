#!/usr/bin/env python3
"""Generate RUVUNFOLD fixtures with the target seam layouts.

Each fixture is a quad/ngon mesh plus the seam set from the reference images:
  cube          - box net (spanning tree of the face dual graph)
  cylinder      - cap separator loops + one vertical slit
  hollow_tube   - four junction loops + one slit per surface
  torus         - one minor loop + one major loop
  sphere        - one pole-to-pole meridian
  lathe         - stacked cylinder: ring loop per radius change + ONE continuous slit
  ngon_concave  - non-convex n-gon, exercises the ear-clipping triangulation
"""
import math
import os
from collections import deque

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")


class Mesh:
    def __init__(self):
        self.verts = []     # list of (x,y,z)
        self.faces = []     # list of [vertex indices, 1-based]
        self.seams = set()  # set of (lo,hi) 1-based

    def v(self, x, y, z):
        self.verts.append((x, y, z))
        return len(self.verts)

    def f(self, *idx):
        self.faces.append(list(idx))
        return len(self.faces)

    def seam(self, a, b):
        if a != b:
            self.seams.add((min(a, b), max(a, b)))

    def seam_loop(self, ring):
        n = len(ring)
        for i in range(n):
            self.seam(ring[i], ring[(i + 1) % n])

    def seam_path(self, path):
        for i in range(len(path) - 1):
            self.seam(path[i], path[i + 1])

    def write(self, path):
        with open(path, "w") as fh:
            fh.write("RUVUNFOLD 1\n")
            fh.write("VERTICES %d\n" % len(self.verts))
            for (x, y, z) in self.verts:
                fh.write("%.17g %.17g %.17g\n" % (x, y, z))
            fh.write("FACES %d\n" % len(self.faces))
            for i, fc in enumerate(self.faces):
                fh.write("FACE %d %d %s\n" % (i + 1, len(fc), " ".join(str(k) for k in fc)))
            fh.write("SEAMS %d\n" % len(self.seams))
            for (a, b) in sorted(self.seams):
                fh.write("SEAM %d %d\n" % (a, b))
            fh.write("END\n")


def dual_spanning_tree_seams(mesh):
    """Cut every manifold edge that is not a hinge of a spanning tree of the face
    dual graph. This is the generic 'connected net' layout - for a cube it is the
    classic cross net (7 of 12 edges cut)."""
    edge_faces = {}
    for fi, fc in enumerate(mesh.faces):
        n = len(fc)
        for k in range(n):
            e = (min(fc[k], fc[(k + 1) % n]), max(fc[k], fc[(k + 1) % n]))
            edge_faces.setdefault(e, []).append(fi)
    adj = {}
    for e, fs in edge_faces.items():
        if len(fs) == 2:
            adj.setdefault(fs[0], []).append((fs[1], e))
            adj.setdefault(fs[1], []).append((fs[0], e))
    keep = set()
    seen = {0}
    q = deque([0])
    while q:
        f = q.popleft()
        for (g, e) in adj.get(f, []):
            if g not in seen:
                seen.add(g)
                keep.add(e)
                q.append(g)
    for e, fs in edge_faces.items():
        if len(fs) == 2 and e not in keep:
            mesh.seam(*e)


def make_cube(size=10.0):
    m = Mesh()
    s = size * 0.5
    ids = {}
    for sz in (-s, s):
        for sy in (-s, s):
            for sx in (-s, s):
                ids[(sx, sy, sz)] = m.v(sx, sy, sz)
    c = lambda x, y, z: ids[(x * s, y * s, z * s)]
    m.f(c(-1, -1, -1), c(1, -1, -1), c(1, 1, -1), c(-1, 1, -1))   # bottom
    m.f(c(-1, -1, 1), c(-1, 1, 1), c(1, 1, 1), c(1, -1, 1))       # top
    m.f(c(-1, -1, -1), c(-1, -1, 1), c(1, -1, 1), c(1, -1, -1))   # -Y
    m.f(c(-1, 1, -1), c(1, 1, -1), c(1, 1, 1), c(-1, 1, 1))       # +Y
    m.f(c(-1, -1, -1), c(-1, 1, -1), c(-1, 1, 1), c(-1, -1, 1))   # -X
    m.f(c(1, -1, -1), c(1, -1, 1), c(1, 1, 1), c(1, 1, -1))       # +X
    dual_spanning_tree_seams(m)
    return m


def _ring(m, radius, z, segs):
    return [m.v(radius * math.cos(2 * math.pi * i / segs),
                radius * math.sin(2 * math.pi * i / segs), z) for i in range(segs)]


def make_cylinder(radius=5.0, height=14.0, segs=24):
    m = Mesh()
    bot = _ring(m, radius, -height * 0.5, segs)
    top = _ring(m, radius, height * 0.5, segs)
    for i in range(segs):
        j = (i + 1) % segs
        m.f(bot[i], bot[j], top[j], top[i])
    m.f(*list(reversed(bot)))
    m.f(*top)
    # cap separator loops + ONE vertical slit
    m.seam_loop(bot)
    m.seam_loop(top)
    m.seam_path([bot[0], top[0]])
    return m


def make_lathe(radii=(5.0, 3.0, 6.0, 3.0, 5.0), zs=(-10.0, -5.0, 0.0, 5.0, 10.0), segs=20):
    """Stacked cylinder / lathe: a ring loop at every radius change plus ONE
    continuous vertical slit spanning every station, at a single angular position."""
    m = Mesh()
    rings = [_ring(m, r, z, segs) for r, z in zip(radii, zs)]
    for k in range(len(rings) - 1):
        a, b = rings[k], rings[k + 1]
        for i in range(segs):
            j = (i + 1) % segs
            m.f(a[i], a[j], b[j], b[i])
    m.f(*list(reversed(rings[0])))
    m.f(*rings[-1])
    for r in rings:
        m.seam_loop(r)
    m.seam_path([r[0] for r in rings])          # one continuous slit
    return m


def make_hollow_tube(outer=6.0, inner=4.0, height=10.0, segs=24):
    m = Mesh()
    ob = _ring(m, outer, -height * 0.5, segs)
    ot = _ring(m, outer, height * 0.5, segs)
    ib = _ring(m, inner, -height * 0.5, segs)
    it = _ring(m, inner, height * 0.5, segs)
    for i in range(segs):
        j = (i + 1) % segs
        m.f(ob[i], ob[j], ot[j], ot[i])       # outer wall
        m.f(it[i], it[j], ib[j], ib[i])       # inner wall
        m.f(ot[i], ot[j], it[j], it[i])       # top annulus
        m.f(ib[i], ib[j], ob[j], ob[i])       # bottom annulus
    for r in (ob, ot, ib, it):
        m.seam_loop(r)
    m.seam_path([ob[0], ot[0]])
    m.seam_path([ib[0], it[0]])
    m.seam_path([ot[0], it[0]])
    m.seam_path([ob[0], ib[0]])
    return m


def make_torus(major=8.0, minor=2.5, mseg=24, nseg=12):
    m = Mesh()
    grid = []
    for i in range(mseg):
        a = 2 * math.pi * i / mseg
        row = []
        for j in range(nseg):
            b = 2 * math.pi * j / nseg
            r = major + minor * math.cos(b)
            row.append(m.v(r * math.cos(a), r * math.sin(a), minor * math.sin(b)))
        grid.append(row)
    for i in range(mseg):
        for j in range(nseg):
            i2, j2 = (i + 1) % mseg, (j + 1) % nseg
            m.f(grid[i][j], grid[i2][j], grid[i2][j2], grid[i][j2])
    m.seam_loop([grid[0][j] for j in range(nseg)])              # minor loop
    m.seam_loop([grid[i][nseg // 2] for i in range(mseg)])      # major loop, inner equator
    return m


def make_sphere(radius=6.0, segs=20, rings=12):
    m = Mesh()
    north = m.v(0.0, 0.0, radius)
    south = m.v(0.0, 0.0, -radius)
    lat = []
    for r in range(1, rings):
        phi = math.pi * r / rings
        z = radius * math.cos(phi)
        rr = radius * math.sin(phi)
        lat.append([m.v(rr * math.cos(2 * math.pi * i / segs),
                        rr * math.sin(2 * math.pi * i / segs), z) for i in range(segs)])
    for i in range(segs):
        j = (i + 1) % segs
        m.f(north, lat[0][i], lat[0][j])
        m.f(south, lat[-1][j], lat[-1][i])
    for r in range(len(lat) - 1):
        for i in range(segs):
            j = (i + 1) % segs
            m.f(lat[r][i], lat[r + 1][i], lat[r + 1][j], lat[r][j])
    meridian = [north] + [lat[r][0] for r in range(len(lat))] + [south]
    m.seam_path(meridian)
    return m


def make_ngon_concave():
    """One L-shaped (non-convex) 6-gon plus a neighbour, to exercise ear clipping."""
    m = Mesh()
    p = [m.v(0, 0, 0), m.v(10, 0, 0), m.v(10, 4, 0), m.v(4, 4, 0), m.v(4, 10, 0), m.v(0, 10, 0)]
    m.f(*p)
    q = [p[1], m.v(10, 0, -6), m.v(10, 4, -6), p[2]]
    m.f(*q)
    m.seam(p[1], p[2])
    return m


FIXTURES = {
    "cube": make_cube,
    "cylinder": make_cylinder,
    "lathe": make_lathe,
    "hollow_tube": make_hollow_tube,
    "torus": make_torus,
    "sphere": make_sphere,
    "ngon_concave": make_ngon_concave,
}

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, fn in FIXTURES.items():
        mesh = fn()
        path = os.path.join(OUT, name + ".ruvu")
        mesh.write(path)
        print("%-14s verts=%-5d faces=%-5d seams=%d" %
              (name, len(mesh.verts), len(mesh.faces), len(mesh.seams)))


def write_obj(mesh, path):
    """Triangulated OBJ, the format the Auto Seam worker reads."""
    with open(path, "w") as fh:
        fh.write("# RotateUV test fixture\n")
        for (x, y, z) in mesh.verts:
            fh.write("v %.17g %.17g %.17g\n" % (x, y, z))
        for fc in mesh.faces:
            for k in range(1, len(fc) - 1):
                fh.write("f %d %d %d\n" % (fc[0], fc[k], fc[k + 1]))
