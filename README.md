# RotateUV Native Unfold V2.5 FINAL

## Final seam strategy

**Minimal Seams** is the default and no separate "Ideal Standard" profile is exposed.

The auto-seam planner now works in this order:

1. **Round Cylinder / Tube** - detects circular axial stations, creates only structural cap/wall separator loops, then adds controlled longitudinal and radial openings. Rounded rectangular ChamferBoxes are explicitly prevented from entering this path.
2. **Smooth Torus** - uses one meridian cycle plus one longitude cycle.
3. **Topology-aware hard-surface net** - collapses coplanar triangles into logical surface patches, builds the patch adjacency graph, then keeps a maximum-quality spanning tree as hinges. Only the remaining cycle-breaking patch boundaries are cut. Smooth bevel/chamfer transitions are preferred as hinges, while sharper corners are preferred seam locations. This applies to Box, ChamferBox, furniture, bridge panels, machinery and similar Editable Poly hard-surface models without relying on primitive names.
4. **Feature-aware fallback** - retained for freeform meshes that do not confidently match the structured paths.

Native Unfold remains **libigl LSCM + SLIM** after seams are applied.

### Profiles

1. Minimal Seams (default, topology-aware)
2. Balanced
3. Low Distortion

### Expected seam behavior

- Box: connected box-net style shell.
- ChamferBox: connected panel/bevel net; avoids the old 2-3-edge under-cut and avoids treating the rounded rectangle as a Tube.
- Cylinder: cap separator + one wall opening.
- Hollow Tube: outer/inner structural loops plus controlled wall and annular-cap openings, not repeated random rings.
- Torus: two fundamental opening cycles.
- General hard-surface objects: large coherent surface groups remain connected wherever possible.

### Build

Use `.github/workflows/build-windows.yml`. The workflow builds the Auto Seam worker and the libigl Native Unfold worker and uploads a Windows artifact.
