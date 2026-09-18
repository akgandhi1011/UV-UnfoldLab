# RotateUV Native Unfold V3.0.0

A 3ds Max UV tool: MaxScript UI plus two standalone Windows workers, aiming at
Maya-grade unfold results. See `CHANGES.md` for what changed from V2.5 and the
measured before/after numbers.

## Layout

| Path | What it is |
| --- | --- |
| `Rotate_UV_PRO_NATIVE_UNFOLD_V2.ms` | the tool: UI, rotation, align, arrange, straighten, worker bridge |
| `Rotate_UV_PRO_NATIVE_UNFOLD_V2.mcr` | macro registration only - safe to drop in the macros folder |
| `src/unfold_worker.cpp` | Native Unfold: developable unroll + libigl LSCM/SLIM |
| `src/autoseam_worker.cpp` | Auto Seam: topology-aware seam planner |
| `tests/` | fixture generator and two regression suites |
| `.github/workflows/build-windows.yml` | builds both workers and runs the tests |

## Install

1. Run the workflow (or build locally, see below) and download the artifact.
2. Put `Rotate_UV_PRO_NATIVE_UNFOLD_V2.ms`, `RotateUV_Unfold.exe` and
   `RotateUV_AutoSeam.exe` in the same folder, or in `<scripts>\RotateUVAtlas\`.
3. Put the `.mcr` in your user macros folder. The button appears under
   Customize -> Customize User Interface -> Category **TEST** -> Rotate UV.

The script requires workers **3.0.0 or newer** and says so plainly if it finds an
older one. Native Unfold falls back to Max Unfold3D when no usable worker is found.

## Unfold pipeline

Each chart is tried in this order, so the cheapest exact method wins:

1. **Planar projection** - flat charts, exact.
2. **Developable unroll** - hinge-unfolds across the dual spanning tree. Exactly
   isometric for cylinder walls, annuli, cones and box nets. Accepted only when
   flip-free, within 1.0005 stretch and non-overlapping.
3. **LSCM (or harmonic) init + SLIM** symmetric Dirichlet, for curved charts.
4. **Axis projection** fallback for degenerate charts.

Then: measured distortion, auto-orientation onto an axis, relative texel-density
normalization, and shelf packing with a quarter turn.

## Seam planner

Component by component, first confident match wins:

1. **Axial** - round co-axial stations (cylinder, tube, lathe): cap separator
   loops plus one continuous longitudinal slit.
2. **Torus** - genus 1 and smooth: one minor loop plus one major loop.
3. **Sphere meridian** - closed, genus 0, smooth: one pole-to-pole cut.
4. **Hard-surface patch net** - coplanar triangles collapsed into patches, then a
   maximum-quality spanning tree of the patch graph kept as hinges. Smooth bevel
   transitions are preferred as hinges, sharp corners as seams.
5. **Feature-aware legacy** fallback for freeform meshes.

Profiles: Minimal Seams (default), Balanced, Low Distortion.

## Worker CLI

```
RotateUV_Unfold.exe in.ruvu out.ruvuv [slimIterations] [options]
  --no-orient            keep the raw solver orientation
  --no-preserve-scale    normalize each chart independently
  --no-developable       skip the exact isometric unroll
  --threads N            worker threads (default: hardware concurrency)
  --padding F            atlas margin, 0..0.2 (default 0.02)
  --version

RotateUV_AutoSeam.exe in.obj out.seams profileBound [--verbose]
  --verbose              report the planner path and cut count per component
  --version
```

## Tests

```
python3 tests/make_fixtures.py
python3 tests/run_tests.py    dist/RotateUV_Unfold.exe
python3 tests/run_pipeline.py dist/RotateUV_AutoSeam.exe dist/RotateUV_Unfold.exe
```

`run_tests.py` recomputes distortion and flips independently from the fixture
geometry rather than trusting the worker's own report. Fixtures carry the
reference seam layouts: sphere = one meridian, cylinder = cap loops + one slit,
torus = two fundamental loops, cube = cross net.

Current status: solver suite 7/7, pipeline suite 5/6. The one failure is the
stacked cylinder, documented under Known gaps in `CHANGES.md`.

## Build locally (Linux, for testing the workers)

```
pip install --target tp cmeel-eigen
curl -sL -o igl.tgz https://codeload.github.com/libigl/libigl/tar.gz/refs/tags/v2.6.0 && tar xzf igl.tgz
g++ -O2 -std=c++17 -DNDEBUG -Ilibigl-2.6.0/include -Itp/cmeel.prefix/include/eigen3 \
    src/unfold_worker.cpp -o RotateUV_Unfold -pthread
g++ -O2 -std=c++17 -DNDEBUG src/autoseam_worker.cpp -o RotateUV_AutoSeam
```

Windows builds use MSVC via the GitHub Actions workflow, which is the supported path.
