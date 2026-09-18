# Third-party notices

## libigl
RotateUV Native Unfold V3 uses libigl v2.6.0 for LSCM parameterization and SLIM optimization.
libigl is distributed under the Mozilla Public License 2.0 for the core functionality used here.
Project: https://github.com/libigl/libigl

## Eigen
libigl uses Eigen for dense and sparse linear algebra. This build checks out Eigen 3.4.0.
Project: https://gitlab.com/libeigen/eigen

No libigl or Eigen DLL is required at runtime for this build; the worker is compiled from source by GitHub Actions.

## Scope of use
Only libigl core headers are used: `igl/lscm.h`, `igl/harmonic.h`, `igl/slim.h`,
`igl/boundary_loop.h` and `igl/map_vertices_to_circle.h`, all MPL 2.0. Nothing
under `igl/copyleft/` is included; that directory is GPL and would change the
licence of this tool.
