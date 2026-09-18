# RotateUV Native Unfold V2 + Ideal Standard Geometry V2.3

This repository builds the RotateUV 3ds Max tool with a native seam worker and native libigl unfold worker.

## V2.3 Ideal Standard Geometry

The seam planner now uses high-confidence topology-first patterns before falling back to the general feature-aware planner.

- **Box / rectangular hard-surface solids:** creates a connected panel net by keeping a spanning tree of face hinges. It does **not** mark every box edge as a seam.
- **ChamferBox / beveled extrusions:** treats planar and chamfer regions as a panel graph and creates one connected low-cut net.
- **Cylinder:** separates caps and opens the side wall with one longitudinal seam.
- **Hollow Tube:** separates the outer/inner walls from annular caps, opens outer and inner walls longitudinally, and opens annular caps radially.
- **Torus / donut topology:** for smooth closed genus-1 meshes, creates one meridian cycle plus one longitude cycle rather than arbitrary partial rings.
- **General meshes:** automatically fall back to the existing V2.2 feature-aware seam planner.

The UI profile **Ideal Standard** is selected by default. Workflow remains:

`Generate -> Preview -> Apply -> Native Unfold`

Native Unfold uses libigl LSCM initialization followed by SLIM symmetric-Dirichlet optimization.

## Build

GitHub Actions builds:

- `RotateUV_AutoSeam.exe`
- `RotateUV_Unfold.exe`
- `Rotate_UV_PRO_NATIVE_UNFOLD_V2.ms`
- `Rotate_UV_PRO_NATIVE_UNFOLD_V2.mcr`

The workflow uses libigl 2.6.0 and Eigen 3.4.0.
