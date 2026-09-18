# Changes in V3.0.0

Everything below was verified by the test suites in `tests/`, run against both
the old and new workers on the same fixtures. Numbers are measured, not estimated.

## Measured before / after

End-to-end (Auto Seam -> Native Unfold), `tests/run_pipeline.py`. Stretch is
`max(s1, 1/s2)` of the scale-normalized Jacobian, so 1.0000 means an exact
isometry. Lower is better; seam count closer to the reference layout is better.

| Fixture     | Seams before | Seams after | Stretch before | Stretch after |
| ----------- | ------------ | ----------- | -------------- | ------------- |
| cube        | 7            | 7           | 1.0000         | 1.0000        |
| cylinder    | 1            | 50          | infinite       | 1.0000        |
| hollow_tube | 26           | 101         | 4.5488         | 1.0000        |
| lathe       | 44           | 48          | 1.4298         | 1.3108        |
| sphere      | 174          | 12          | 1.0444         | 3.5929        |
| torus       | 36           | 36          | 1.5525         | 1.5517        |

Pipeline pass rate went from 2/6 to 5/6.

Notes on two rows that need reading carefully:

- **cylinder** produced 1 seam edge before, so the whole shell stayed one chart
  with a one-edge slit and the solve degenerated (infinite stretch). It now gets
  both cap loops plus a slit and unrolls exactly.
- **sphere** shows stretch going *up*, from 1.04 to 3.59. That is correct. The old
  planner shredded the sphere into 174 scattered cut edges, which makes each
  fragment nearly flat and therefore cheap to flatten; a sphere cut once cannot
  be flattened without distortion. 12 seams with 3.59 stretch is the right
  answer; 174 seams with 1.04 was a useless atlas.

Solver-only results, `tests/run_tests.py`, using the reference seam layouts from
the target images: 7/7 pass, versus 3/7 before. The four prior failures were all
chart orientation - the old output left the dominant boundary direction at 153,
138, 151 and 16 degrees instead of on an axis.

## Native Unfold worker (`src/unfold_worker.cpp`)

- **Exact developable unroll.** New stage between the planar shortcut and SLIM:
  hinge-unfolds the chart across its dual spanning tree, which is exactly
  isometric for cylinder walls, annuli, cones, box nets and flat patches. Accepted
  only when it is flip-free, within 1.0005 stretch and non-overlapping, so a
  non-developable chart still falls through to LSCM + SLIM. Exact, deterministic,
  and no solver needed for most hard-surface geometry.
- **Chart auto-orientation.** Length-weighted boundary direction histogram with
  sub-bin refinement, rotated onto U, then the quarter turn that leaves the chart
  landscape. This is what fixes the scrambled box UVs.
- **Texel-density preservation.** Each chart is scaled by `sqrt(area3D / areaUV)`
  before packing, so relative scale between shells is kept. `--no-preserve-scale`
  restores per-chart normalization.
- **Scale-invariant distortion report.** Per-chart and global max/mean stretch,
  area distortion, shear, flips and overlap count, written to the result header
  and printed to stdout. The Jacobian is divided by the chart's optimal uniform
  scale first, otherwise a small chart reports enormous distortion for no reason.
- **Overlap detection.** Uniform-grid broad phase plus a separating-axis test,
  used both as the developable acceptance test and as a reported metric.
- **Ear-clipping triangulation.** Replaces the fan from corner 0, which produced
  degenerate or inverted triangles on non-convex n-gons.
- **Honest flip accounting** and **parallel chart solves** (`--threads`), with
  SLIM iterating in batches and exiting on energy convergence instead of always
  burning the full budget.
- New flags: `--version`, `--no-orient`, `--no-preserve-scale`, `--no-developable`,
  `--threads N`, `--padding F`. Result format is now `RUVUV 2`.

## Auto Seam worker (`src/autoseam_worker.cpp`)

- **Sphere meridian path.** A smooth closed genus-0 surface now gets a single
  pole-to-pole cut. Poles come from the valence anomaly of a UV sphere when
  present, otherwise from a graph-geodesic farthest pair. Previously a sphere had
  no edge above `featureAngle`, so `featureCycleCore` returned empty and the
  legacy fallback shredded it: 174 cut edges, now 12.
- **Removed the `sharpFrac > 0.10` gate** on the axial path. An ordinary cylinder
  has cap creases worth only ~6% of total edge length, so the gate rejected it and
  pushed it into the patch-net planner, which under-cut it to a single edge.
  `tryAxialStandardAssist` already validates round, co-axial, well-separated
  stations on its own, so the gate was redundant as well as harmful.
- **Structural openings are protected from pruning.** `pruneTinyBranches` could
  cascade through a freshly added slit and delete it, turning a closed shell back
  into a non-disk chart. Slits and region connectors are now registered and never
  pruned.
- New flags: `--version`, `--verbose` (reports which planner path each component
  took, and its raw cut count).

## MaxScript (`Rotate_UV_PRO_NATIVE_UNFOLD_V2.ms` / `.mcr`)

- **The `.mcr` is no longer a byte-copy of the `.ms`.** It was identical, including
  a development auto-open block, so the dialog opened by itself whenever Max
  evaluated the macros folder. The `.mcr` is now the `macroScript` only, and loads
  the `.ms` on demand if it has not been evaluated. The auto-open block is gone
  from the `.ms` too.
- **Seam collection rewritten.** `nativeUnfoldCollectGeomSeams` no longer calls
  `uv.selectEdges` + `uv.edgeToVertSelect` per seam edge and then rescans every
  face with a linear array search. It builds the TV pair set once and walks the
  faces a single time with .NET `Hashtable` lookups, with the old array path kept
  as a fallback if .NET is unavailable.
- **Worker version handshake.** Both workers are queried with `--version` and
  anything below 3.0.0 is reported clearly instead of failing later with a parse
  error. Native Unfold falls back to Max Unfold3D in that case.
- **Result header parsed by name** until `FACES`, so new metrics do not break an
  older script and vice versa. `RUVUV 1` and `RUVUV 2` are both accepted.
- **Status line reports quality:** chart count, max and average stretch, flip and
  overlap warnings.

## Tests (new)

- `tests/make_fixtures.py` builds cube, cylinder, lathe, hollow tube, torus,
  sphere and a concave n-gon, each with the reference seam layout, as `.ruvu` and
  triangulated `.obj`.
- `tests/run_tests.py` runs the solver and recomputes distortion and flips
  **independently** from the fixture geometry. It does not trust the worker's own
  report - that is how the original scale-dependent stretch metric was caught.
- `tests/run_pipeline.py` runs both workers in sequence and verifies the result.
- Both suites run in CI after the build.

## Known gaps

- **lathe / stacked cylinder** still fails the exact-unroll target at 1.31 stretch.
  The axial planner keeps only the two extreme station loops, so one chart spans a
  radius change. `collectPlanarLoopCandidates` does not recognize intermediate
  shoulder rings as structural loops. This is the next thing to fix.
- **Hollow tube** works but is not minimal: 101 cuts where one radial slit through
  all four surfaces plus the structural minimum would do.
- **No pinning.** SLIM is still called with empty constraint sets, so there is no
  pinned-UV unfold, no unfold-selected-only, no constrain-to-U/V.
- **The distortion bound is still not enforced.** `DISTORTION_BOUND` selects a
  profile; nothing iterates cut-solve-measure-recut. The distortion report added
  here is the prerequisite for that work.
- Packing is still a shelf packer with a quarter turn - no mask-based packing,
  pixel-accurate padding or UDIM.
