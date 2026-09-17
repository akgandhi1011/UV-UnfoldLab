# Third-party notices

## libigl
RotateUV Native Unfold V2 uses libigl v2.6.0 for LSCM parameterization and SLIM optimization.
libigl is distributed under the Mozilla Public License 2.0 for the core functionality used here.
Project: https://github.com/libigl/libigl

## Eigen
libigl uses Eigen for dense and sparse linear algebra. This build checks out Eigen 3.4.0.
Project: https://gitlab.com/libeigen/eigen

No libigl or Eigen DLL is required at runtime for this build; the worker is compiled from source by GitHub Actions.
