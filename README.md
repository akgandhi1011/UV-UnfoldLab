# RotateUV Native Unfold V2.4

## V2.4 changes

- `Ideal Standard` is no longer a separate profile. Standard-geometry recognition is embedded in **Minimal Seams**.
- **Minimal Seams** is now the default profile.
- 3ds Max **Tube** is distinguished from a smooth torus even though both are genus-1 topologies. Sharp axial Tube geometry is handled before torus recognition.
- Tube output targets clean structural loops plus controlled openings instead of selecting nearly every edge.
- Smooth torus recognition is stricter, preventing sharp Tube primitives from entering the torus path.
- ChamferBox/hard-surface nets now reject clearly under-cut 2-3 edge results and fall through to a more appropriate structured/fallback solution.
- Standard Box behavior is preserved.

### Profiles

1. Minimal Seams (default; includes automatic Box / ChamferBox / Cylinder / Tube / Torus recognition)
2. Balanced
3. Low Distortion

### Build

Use the included `.github/workflows/build-windows.yml` workflow. The repository contains the MaxScript UI, auto-seam worker and native unfold worker.
