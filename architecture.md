# pipe-macos: Shape & Feature Detection Architecture

## Why STEP, Not STL

STL is a mesh-only format: it discards all analytic surface information and represents everything as triangles. For CNC rotary plasma cutting:

- Cylinder axes cannot be recovered precisely — only approximated from noisy triangle normals.
- Plane normals are integer-quantised by mesh resolution.
- Feature boundaries are implicit (a ring of triangles), not explicit edges.

STEP (ISO 10303) is a B-Rep format. Every face carries its exact surface type (PLANE, CYLINDER, CONE, …), the analytic parameters of that surface (axis direction, radius, location), and the topological adjacency of faces through shared edges. This makes axis extraction, cross-section measurement, and feature boundary tracing exact rather than approximate.

The OCCT bridge (OpenCASCADE Technology, accessed via `STEPBridgeWrapper`) reads a STEP file and emits structured JSON with:
- Per-solid face list, each face tagged with `surface_type` and analytic parameters
- Per-face edge list with sampled 3D points and `adjacentFaceIDs`
- Tessellated vertices/triangles for rendering
- A PCA axis (principal component of all vertex positions)

---

## Pipeline Overview

```
STEP file
   │
   ▼
OCCT bridge  →  JSON per solid
   │
   ├─ Step 1: PCA seed axis
   ├─ Step 2: Cluster planar normals
   ├─ Step 3: Refine axis from perpendicular wall pairs
   ├─ Step 4: Refine further from cylinder surface
   ├─ Step 5: Derive cross-section axes (uAxis, vAxis)
   ├─ Step 6: Extremum measurement → dimensions, profile
   │
   └─ AAG feature extraction
        ├─ Identify outer hull faces
        ├─ Collect hull-boundary edges (AAG traversal)
        ├─ Chain edges into closed loops
        └─ Classify loops as hole / cutout / notch / startCut / endCut
              → SurfaceFeature with 2D (X, A) toolpath path
```

---

## Step 1 — PCA Axis Seed

The OCCT bridge computes the principal axis of the solid's vertex cloud (third eigenvector = least-variance axis = the long direction of a tube). This is stored as `pca.axis3{X,Y,Z}`.

PCA is used only as a stable, unambiguous seed. It is never used for final measurements because it drifts on asymmetric features (fishmouths, copes) and carries no absolute orientation.

---

## Step 2 — Cluster Exact Planar Normals

OCCT provides exact (not tessellation-derived) plane normals for every `PLANE` face. These are clustered by direction, grouping anti-parallel normals (opposite walls) into a single cluster using `|dot(n1, n2)| > 0.95`. Each cluster accumulates a vertex count as a weight.

Clusters are sorted by descending weight. This de-noises the normal set: for an HSS tube with cope/miter cuts, the side-wall clusters (high vertex count) dominate the cut-face clusters (low vertex count).

---

## Step 3 — Tube Axis from Perpendicular Wall Pairs

For square/rectangular HSS, two perpendicular side-wall normal clusters exist. Their cross-product is the tube axis — more precise than PCA because it is derived from the exact OCCT normals, not from vertex statistics.

**Scoring:** each candidate pair is scored by `(combined vertex weight) × alignment_with_PCA`. The alignment gate of `> 0.95` (≈ 18°) is critical: cope/miter cut faces introduce extra planar normals whose cross-products give a global axis with alignment ≈ 0.42–0.91 against PCA. Only true side-wall pairs (alignment ≈ 1.0) pass. Sign ambiguity is resolved by requiring the candidate to be in the same hemisphere as the PCA axis.

If no perpendicular pair passes the gate, `tubeAxis` stays as `pcaAxis`.

---

## Step 4 — Cylinder Axis Refinement (Round Tube)

For round tubes, the outer cylindrical surface's axis is exact and more precise than PCA. The largest cylinder face (by vertex count) that is aligned with the current `tubeAxis` (`|dot| > 0.9`) overrides it. The cylinder radius is also retained for profile classification.

Drilled holes are rejected by the alignment gate: a hole bored perpendicular to the tube has its cylinder axis ⊥ tubeAxis so `|dot| ≈ 0`.

---

## Step 5 — Cross-Section Axes (uAxis / vAxis)

`uAxis` is the "reference zero" direction in the cross-section plane — the direction that G-code `A=0` physically points to (after roll correction).

**HSS:** `uAxis` = dominant side-wall normal (one of the two perpendicular face directions, chosen as the highest-weight cluster after rejecting end caps and cut faces). A "perpendicular partner" test (`|dot| < 0.15` against another cluster) filters out end caps (whose normal is the tube axis) and isolated cope/miter faces.

**Round tube fallback:** `uAxis = normalize(cross(tubeAxis, arb))` where `arb = (0,1,0)` unless `tubeAxis.x > 0.9` (then `arb = (1,0,0)`). This is arbitrary for round stock — a circle looks the same at any angle — but the formula must be consistent between ModelLoader and the pack simulation.

`vAxis = normalize(cross(tubeAxis, uAxis))` completes a right-handed frame.

---

## Step 6 — Extremum Measurement

All render vertices are projected onto `(tubeAxis, uAxis, vAxis)`:
- Axial span `[minX, maxX]` → `length`
- Cross-section spans `[minNegU, maxPosU]` and `[minNegV, maxPosV]` → `odX`, `odY` (or `od` for round)
- Centroid `origin` (used in pack scene to translate geometry to pack space)

**Profile classification:**
- `maxCylRadius > 5 mm` → round (small corner-radius cylinders on HSS are ≈ 2–4 mm)
- Otherwise HSS: square if `|odX − odY| < 2 mm`, else rectangular

---

## AAG Feature Extraction

### What is AAG?

Attributed Adjacency Graph: a graph where nodes are faces and edges connect topologically adjacent faces. Each node carries attributes (surface type, normal, area) and each edge carries the transition type (convex/concave/smooth). Feature recognition reads subgraphs matching known patterns.

Here, a simplified AAG is used: rather than explicit graph data structures, the adjacency is exploited via `adjacentFaceIDs` on each edge, provided directly by OCCT.

### Outer Hull Identification

The "outer hull" is the set of faces that form the stock surface before any features are cut. Two face types are identified as hull faces:

**Planar hull faces:** A planar face is on the outer hull if its signed distance from the origin along its own normal equals the global maximum of `dot(all_vertices, n)`. Tolerance: 2 mm. This is rotation-invariant — no alignment with uAxis/vAxis needed.

**Cylindrical hull faces (HSS corner radii and round tube OD):** A cylinder is on the outer hull if its axis aligns with tubeAxis (`|dot| > 0.9`) AND its centre + radius reaches the cross-section extremum in either the U or V direction. Tolerance: 0.5 mm (tighter than the 2 mm planar tolerance to distinguish inner from outer corner radii).

### Feature Boundary Edges (AAG Traversal)

A boundary edge is collected from a hull face if:
- It is a manifold edge (`adjacentFaceIDs.count ≥ 2`) — seam/degenerate edges excluded
- At least one adjacent face is NOT on the outer hull

This is the classic AAG feature recognition step: a hull-face–inner-face transition marks a feature boundary.

### Edge Stitching → Closed Loops

Boundary edges are chained into closed polyloops by endpoint proximity. Stitch tolerance is `max(1.5 mm, 1% of tube length)` — scale-relative to handle models from small fittings to structural beams. Only geometrically closed loops (end ≈ start within the same tolerance) are kept; open chains are discarded as partial/degenerate geometry.

### 2D Unrolling and Feature Classification

Each loop point is projected to `(X, A)` coordinates:
- `X` = axial position along the tube (0 at the G92-referenced free end)
- `A` = `atan2(dot(radialVec, vAxis), dot(radialVec, uAxis))` in degrees, range [0, 360)

**Winding test:** the sum of signed angular deltas around the closed loop is accumulated. `|Σ| > 350°` means the loop encircles the tube cross-section completely (a full-circumference cut). This distinguishes end cuts from notches without any threshold on absolute angular span.

**Classification:**

| Condition | Type |
|-----------|------|
| Full-circumference AND touches axial start (low X end) | `startCut` — sever from chuck |
| Full-circumference AND touches axial end (high X end) | `endCut` — trim free end |
| Touches axial start or end (but not full-circumference) | `notch` |
| Interior (neither end) | `hole` / `cutout` |

Axial tolerance: `max(3 mm, 1.5% of tube length)`.

The path is stored as an unwrapped `[ToolpathPoint]` (continuous A, no 360° jumps) for direct use as a G-code toolpath. For end/start cuts, the path is additionally sorted by A ascending so the torch traces smoothly around the circumference.

---

## Angular Reference and Roll Correction

The A-axis angular reference is the direction `uAxis` points in the cross-section plane. G-code `A=0` physically means "the torch is aligned with `uAxis`."

For HSS, the machine should start with a flat face toward the torch (A=0 = flat face up). `uAxis` is the face normal of that flat face. A **roll offset** in degrees is computed as:

```
q1 = alignAxisToX(stock.axis)          // rotation that maps tubeAxis → world +X
rotatedU = q1.act(normalize(uAxis))    // where uAxis lands in pack space
rollOffset = -atan2(rotatedU.z, rotatedU.y) × 180/π
```

This roll offset is added to every A value in the generated G-code so that `A=0` physically corresponds to `uAxis` facing world `+Y` (toward the torch) after the pack alignment rotation.

### Simulation Angular Offset

In the pack scene simulation, the same quantity (in radians) is stored as `simA0Offset` and applied to the stock group's SceneKit rotation:

```
stockGroup.eulerAngles.x = -gcodeA × π/180 + simA0Offset
```

The sign flip on `gcodeA` is because positive G-code A is CCW looking from the chuck toward the torch, which in SceneKit (right-hand rule, rotation around +X = world tube axis direction) requires a negative euler angle.

---

## G-Code Generation

### Coordinate System

- Origin: free end of stock (G92 sets X = total pack length, Y=0, Z=0, A=0)
- X decreases as the chuck moves toward the torch
- A is continuous across features and pieces (no reset) to minimise A-axis travel
- Z: `safeHeight = 25 mm` (rapid traverse), `cutHeight = 1.5 mm` (firing)

### Toolpath

Each `SurfaceFeature.path` is used directly as the G-code toolpath — the B-Rep edge loop projected to `(X, A)` coordinates. No shape-fitting (circle, rectangle) is needed; the OCCT boundary IS the toolpath.

**Lead-in strategy:**
- End/start cuts: lead in from outside the stock in X (beyond the tube end)
- Holes/cutouts: pierce at centroid (always inside the removed material, never in remaining stock)
- Notches: lead in from the nearer tube end

**Overburn:** `overburnDegrees = 10°` past the closing point for all features — ensures complete severance and avoids uncut tabs from plasma lag.

### Pack G-Code Cut Order

Within each piece: `endCut → holes/cutouts/notches → startCut`. This keeps the piece supported by the remaining stock until all features are complete before the final sever. Across pieces: right-to-left (highest X first = farthest from chuck first), consistent with the machine loading direction.

---

## Data Flow Summary

```
STEP
  └─ OCCT bridge (C++/ObjC)
       └─ JSON: solids → faces → edges (with adjacency + analytic params)
            └─ ModelLoader.parseSolidJSON()
                 ├─ tubeAxis (Steps 1–4)
                 ├─ uAxis, vAxis (Step 5)
                 ├─ StockInfo: profile, od/odX/odY, length, axis, uAxis, origin (Step 6)
                 └─ extractFeaturesFromTopology() → [SurfaceFeature]
                      ├─ outer hull identification
                      ├─ boundary edge collection (AAG)
                      ├─ loop stitching
                      └─ 2D unroll + classify → path: [ToolpathPoint]

StockInfo + [SurfaceFeature]
  └─ GCodeGenerator
       ├─ generateGCode()       — single part
       └─ generatePackGCode()   — multi-part pack
            └─ generatePackFeatureToolpath() — B-Rep path → G1 moves + lead-in + overburn

Pack scene (ContentView / AppViewModel)
  ├─ buildPackScene()           — geometry, torch node, simA0Offset
  ├─ buildSimSegments()         — G-code lines → SimSegment[]
  └─ applySimState()            — stockGroup position/rotation + torch Y height
```

---

## Known Limitations and Future Work

- **Feature shape classification** is currently always stored as `.rectangle`; the loop geometry itself is exact but the `FeatureShape` enum is not yet updated to `.circle` for cylindrical holes detected from the loop's angular span.
- **Multi-profile packs** assume all pieces have the same profile and outer dimension. The UI enforces this via `profileMatches()`.
- **Closed loops only** — open-chain features (partial notches that don't close due to mesh artefacts) are silently dropped. A fallback for near-closed chains could improve robustness.
- **Single outer cylinder** — the feature extractor uses the tube's outer cylinder for hull identification but does not handle tubes with multiple outer cylinders (e.g., eccentric reducers).
