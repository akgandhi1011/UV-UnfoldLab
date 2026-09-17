# RotateUV Native Unfold V2 / Standard Geometry V2.2

This package upgrades only the native UV solve stage while preserving the established RotateUV UI and the feature-aware seam workflow.

## What changed

- `RotateUV_AutoSeam.exe`: V2.2 package label; the successful V2.1 feature-aware/standard-geometry behavior is intentionally frozen rather than rewritten.
- `RotateUV_Unfold.exe`: custom LSCM approximation removed.
- Native Unfold V2 uses **libigl v2.6.0**:
  1. exact planar projection for truly planar charts,
  2. libigl LSCM initialization for cut non-planar charts,
  3. harmonic circle initialization if LSCM starts with local inversions,
  4. libigl SLIM with **symmetric Dirichlet** energy for iterative low-distortion optimization,
  5. chart packing back to 0-1 UV space.

The input/output protocol is intentionally compatible with the previous MaxScript integration, so the workflow remains:

`Generate -> Preview -> Apply -> Native Unfold`

## Why this is different from Native Unfold V1

V1 contained a home-grown least-squares conformal approximation and fallback projection. V2 delegates the non-planar parameterization/optimization to established libigl implementations of LSCM and SLIM.

SLIM is used after the initial parameterization to reduce distortion while favoring locally injective mappings. V2 never accepts a SLIM result with more flipped triangles than its initialization.

## Build

Create a new GitHub repository from this clean package and run the workflow:

`Build RotateUV Native Unfold V2 + Standard Geometry V2.2`

The workflow checks out libigl v2.6.0 and downloads the official Eigen 3.4.0 release archive from GitLab. Eigen is not checked out through the former `libigl/eigen` GitHub step, avoiding that CI failure point.

The artifact is:

`RotateUV-Native-Unfold-V2-Windows`

Expected artifact files:

- `RotateUV_AutoSeam.exe`
- `RotateUV_Unfold.exe`
- `Rotate_UV_PRO_NATIVE_UNFOLD_V2.ms`
- `Rotate_UV_PRO_NATIVE_UNFOLD_V2.mcr`
- `README_NATIVE_UNFOLD_V2.md`
- `THIRD_PARTY_NOTICES.md`

## First tests

Do not test every model at once. Test these in order:

1. capped cylinder -- regression; existing result should remain good,
2. tube/torus -- must have enough seams to make the chart topologically disk-like before unfolding,
3. chamfered box -- check that major faces/bevel bands remain coherent,
4. sphere -- must have at least one valid opening seam; a completely closed sphere cannot be flattened injectively.

For each object:

`Generate -> Preview -> Apply -> Native Unfold`

If the seam preview itself is wrong, Native Unfold cannot repair the topology; that remains a seam-planner issue. If the preview is right but UVs are poor, that is the V2 solver issue to tune.
