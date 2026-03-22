---
  Code Review: 4-Axis Rotary Plasma CNC Pipeline vs. 2026 State-of-the-Art

  ---
  1. STEP Parsing (STEPBridge.mm)

  What's correct:
  - OCCT is the right foundation — FreeCAD, OpenShell, Salome all use it; no viable alternative at this precision level.
  - BRepTools_WireExplorer for topologically ordered edge traversal is the only correct OCCT approach. TopExp_Explorer would give unordered edges and break loop reconstruction.
  - PCA via GProp_GProps::PrincipalProperties() is geometrically sound for symmetric prismatic stock.
  - GCPnts_UniformAbscissa for arc-length-uniform discretization is correct; the point count formula ceil(edgeLength / 1.0) + 1 yields proper endpoint inclusion.

  Issues and recommendations:

  A. PCA axis assignment is fragile for non-symmetric cuts.
  ThirdAxisOfInertia() (minimum inertia = extrusion axis) is only reliable for symmetric profiles. A heavily notched tube — especially where a large sever cut removes >30% of the wall — shifts the inertia tensor's principal axes significantly. The
  minimum-inertia axis can flip 90° relative to the true extrusion direction.

  Robust fix: Cross-validate the PCA axis against the bounding-box aspect ratio. The long axis of the bounding box should agree with ax3 within ~15°. If not, prefer the bounding-box axis and log a warning. This is what Hypertherm ProNest's STEP importer
  does via a secondary validation pass.

  B. Only SOLID entities explored.
  TopExp_Explorer solidExp(shape, TopAbs_SOLID);
  Multi-body STEP files with CompSolid or OPEN_SHELL entities produce zero solids from this traversal. STEP files exported by SolidWorks "Save As STEP" often produce shells, not solids. Fix: if solidExp yields nothing, fall back to TopAbs_SHELL.

  C. 1mm discretization is too coarse for small OD on tight-radius features.
  For a 25.4mm OD round tube, 1mm of arc = ~4.5° of rotation. At typical plasma feed rates (1000–3000 mm/min), this produces visually acceptable toolpaths, but:
  - For holes smaller than ~12mm diameter on round stock, 1mm spacing gives only ~38 points on the feature circumference. Profile deviation from the true circle is ~0.01mm at this spacing, which is acceptable.
  - The real issue is rectangular HSS corner transitions. A 25mm×25mm tube has a corner arc radius of ~2–3mm. At 1mm spacing, a 180° corner is represented by only 9 points. Kerf offset on these 9 points produces a poorly-shaped offset contour.

  Consider: use 0.5mm spacing, or make the step size adaptive (e.g., min(1.0, R * 0.05) where R is the local curvature radius from BRepAdaptor_Curve::GetType()).

  D. C++ exceptions pass through uncaught.
  The @try/@catch only catches NSException. OCCT throws Standard_Failure and its derivatives (e.g., Standard_ConstructionError, Standard_OutOfRange) as C++ exceptions, not NSExceptions. These propagate uncaught through the ObjC @try block on Apple Clang.
  Result: any OCCT assertion failure crashes the process rather than returning nil. Fix:
  @try {
      // ...
  } @catch (NSException *e) {
      return nil;
  } catch (Standard_Failure& e) {
      // handle OCCT exception
      return nil;
  } catch (...) {
      return nil;
  }

  E. Face type coverage is incomplete.
  Only Geom_CylindricalSurface and Geom_Plane are classified. Missing:
  - Geom_ConicalSurface: swaged pipe reducers, tube-to-tube weld preps
  - Geom_ToroidalSurface: pipe elbows (relevant for fitting work)
  - Geom_BSplineSurface: surfaces from NURBS-based CAD systems

  For types you don't classify (surfaceType=5), the face contributes to tessellation for rendering but its wire contours still feed the feature-extraction pipeline in ModelLoader.swift. Unknown surface wires produce unclassifiable features or garbage
  paths. At minimum, log the surface type integer so you can audit what you're silently ignoring.

  ---
  2. Feature Extraction (ModelLoader.swift)

  What's correct:
  - Accumulated-angle loop detection (threshold 350°) for full-profile features is the standard computer vision approach for closed planar contours on surfaces.
  - The touchesStart / touchesEnd logic for sever cut classification is correct in principle.
  - Using face adjacency (the AAG/edge-to-face map from STEPBridge) to link features to their enclosing surfaces is the right architecture.

  Issues and recommendations:

  A. Round/rect classification heuristic is radius-magnitude-dependent.
  isRound = maxCylRadius > 5.0
  This threshold of 5mm will misclassify:
  - A 6mm OD round tube as round (correct)
  - A 100mm OD rectangular tube that has 8mm-radius internal holes: maxCylRadius = 50mm (outer cylinder in some representations) — but since rectangular tubes have no outer cylinder face, this is irrelevant in practice.
  - Actually the bigger risk: a rectangular tube with large corner radii (e.g., 4mm on a 25×25mm tube). OCCT may model the corner arcs as short cylindrical surfaces. maxCylRadius = 4.0, which is < 5.0, so .round is not triggered. But a 25×50mm rectangular
   tube with 5mm corner radii would return maxCylRadius = 5.0 and misclassify as round.

  Fix: Don't use absolute radius as the discriminator. Instead, check if any cylindrical surface has a radius > 40% of the bounding-box diagonal. That's the OD of round stock. Corner-radius cylinders are always < 15% of the diagonal.

  B. Profile .square vs .rectangular uses a 2mm tolerance on absolute OD dimensions.
  abs(crossMax - crossMin) < 2.0  // → .square
  For small tube (25mm): 2mm tolerance is 8% of size — reasonable.
  For large tube (150mm): 2mm tolerance is 1.3% — probably too tight (manufacturing tolerances on rolled steel HSS are typically ±1.5mm on the larger dimension).

  This is minor but could cause .rectangular classification for nominal-square stock at large sizes.

  C. Feature path ordering may not match cut direction.
  The edge wires from BRepTools_WireExplorer produce edges in topological order, which may be clockwise or counterclockwise depending on how the CAD face was constructed. The chirality detection downstream (shoelace in GCodeGenerator) corrects for overall
   direction, but the individual edge points within a loop may still have inconsistent orientation between different CAD tools (SolidWorks vs. Catia STEP outputs are known to differ in wire orientation conventions).

  You handle this by reversing in the shoelace step, which is correct, but only if all edge points within a single wire loop are consistently ordered. A wire with half its edges forward and half reversed would produce a self-intersecting toolpath that the
   shoelace wouldn't fix.

  ---
  3. G-Code Generation (GCodeGenerator.swift)

  This is the most technically ambitious part, and it's largely sound. Here are the precise issues:

  A. k = π*OD/360 is wrong for rectangular HSS.
  let k = (.pi * OD) / 360.0
  This converts A-degrees to mm surface arc-length using the circumference formula for a circle of diameter OD. For round stock: exact. For rectangular HSS: the perimeter is 2*(W+H), not π*OD. One full rotation (360°) on a 50.8×25.4mm rect tube traverses
  152.4mm of perimeter, not π * 50.8 = 159.5mm. This 5% error in k propagates into:
  - Kerf offset width (offset too large by 5%)
  - Lead-in radius (lead-in arc overshoots by 5%)
  - Overburn distance (slightly too long)
  - Chirality detection (signed area is off, but only affects direction, not magnitude)
  - Velocity profiling (junction speeds computed with wrong arc-length scale)

  The corrected k for rectangular profiles: k = (2*(W+H)) / 360.0. But even this is only correct for the average, because the actual arc-length per degree of rotation varies around the perimeter (flat faces: constant, corners: R * Δθ). The strictly
  correct approach is to track path points by actual perimeter arc-length rather than by A-degree, which requires the getProfilePoint → arc-length mapping to be precomputed. This is a significant architectural change but is what all industrial rotary
  plasma CAM systems (e.g., Hypertherm ProNest Tube, BLM Group's artube) do.

  B. Kerf offset at concave corners can produce spikes (no miter-limit).
  The bisector intersection in applyOfflineKerfOffset computes the correct offset point for convex corners, but for acute-angle convex corners (exterior angle > 90°), the intersection point can be far outside the material. This is the "miter spike"
  problem in 2D offsetting:

  Original corner (90°) → offset spike can be 2× kerfWidth away from corner

  No miter-limit is applied. The abs(cross) < 1e-6 check handles collinear segments but not extreme-angle corners. On a rectangular tube where the toolpath exits one flat face and enters the corner arc, the angle change at the first discretized corner
  point can be 45°+ degrees. With a 1mm kerf radius, the miter spike can be ~1.4mm past the expected position. Plasma kerf is ~2mm wide; a 1.4mm spike is inside the material and gets cut, producing a notch in the tube.

  Fix: Apply a miter-limit of 2–3× kerf width. If the spike distance exceeds the limit, clip to a bevel (two points per corner instead of one).

  This is the most impactful correctness issue in the codebase.

  C. Pierce delay is missing.
  lines.append("M3 S1                         ; torch on")
  // immediately:
  lines.append("G0 Z\(fmt(pierceMp.Zm + settings.pierceHeight)) ; lower to pierce height")

  Wait — actually the order is: retract → rapid to pierce XYA → descend to pierce height → M3. Then the very next G-code is the first G1 cutting move. Real plasma requires a pierce dwell: the arc establishes in ~50–300ms depending on material thickness
  and amperage. Without a dwell (G4 Pxxx in Fanuc, G4 Xxx in Mach), the machine starts moving before the arc is fully established. This produces a ragged pierce hole and potential arc dropout.

  Standard practice: G4 P0.3 (300ms dwell) immediately after M3. The dwell time should be a setting, with Hypertherm recommended values ranging from 50ms (thin sheet) to 500ms for thick wall.

  D. Lead-in phase doesn't maintain pierce height.
  The G-code structure is:
  G0 Z[pierce_height]
  M3
  G1 X[lead_in_start] Y[...] Z[cut_height] F[...]  ← already at cut height

  The torch descends from pierce height to cut height on the first G1 move of the lead-in arc. This means the arc is still establishing while the torch is simultaneously dropping 0.6mm (pierceHeight - cutHeight). Professional plasma CAM maintains pierce
  height through the entire lead-in arc, then transitions to cut height at the point where the lead-in meets the main cut contour.

  Fix: Insert a Z transition line (G1 Z[cut_height] F[z_feed]) at the end of the lead-in sequence, before the main contour begins.

  E. IHS (Initial Height Sensing) is absent.
  All professional plasma CNC systems perform an IHS cycle before each pierce:
  1. Descend at slow feed until arc voltage / ohmic contact triggers
  2. Record the surface Z position
  3. Retract to pierce height from that measured position

  Without IHS, the code relies on the programmed Z-zero being accurate. For round tubes, runout and tube sag (especially on long pieces) means the actual surface height can vary by ±1–3mm from the programmed position. This directly causes over-piercing
  (torch too close, dross blowback onto nozzle) or under-piercing (arc dropout).

  IHS requires controller support and a probing cycle. Adding it would look like:
  G38.2 Z-[probe_depth] F[probe_feed]  ; probe until contact (LinuxCNC)
  ; or controller-specific IHS codes for Mach4/SimCNC

  This is the second most impactful missing feature after pierce delay.

  F. Damped Jacobian uses round-tube kinematics for rectangular profiles.
  In dampedMachinePoints computation:
  let newYm = currRaw.matU * cos(thetaRad) - currRaw.matV * sin(thetaRad)
  let newZm = currRaw.matU * sin(thetaRad) + currRaw.matV * cos(thetaRad)
  This is a rotation of (matU, matV) by angle newAm. This is the correct kinematic transform for a round tube where (U, V) are the radial cross-section coordinates and the transform is a rotation. For rectangular HSS, the relationship between torch angle
  and torch position is not a simple rotation — it's the getProfilePoint raycast. The damped angle correction recomputes Ym/Zm as if it were a round tube, which places the torch off-surface on rectangular stock during the corner transition.

  The correct approach: after computing newAm, call getProfilePoint(angleDeg: newAm * 180/π) and use those (u, v) coordinates for Ym/Zm instead of the rotation formula.

  G. Corner radius R = min(W,H) * 0.1 is a hardcoded assumption.
  Real HSS corner radii per ASTM A500:
  - For 25×25mm HSS: inner corner radius ≈ 1.5T (wall thickness), outer ≈ 2.5T
  - For 2"×2"×0.25" (6.35mm wall): inner R ≈ 9.5mm, outer R ≈ 15.9mm
  - 10% of min(W,H) = 10% × 25.4 = 2.54mm ← significantly underestimates real corner radius

  The consequence: getProfilePoint returns the wrong surface position at corners, the A-axis motion profile at corners is incorrect (too sharp a transition, because the modeled corner radius is too small), and the safe-Z clearance is underestimated.

  Fix: Accept wall thickness as a parameter (or detect it from the CAD model by subtracting inner and outer cylinder radii for round stock, or face-to-face distance for rect stock). Then compute R = 2.0 * wallThickness for the outer corner per ASTM A500.

  H. THC is not disabled during lead-in and overburn.
  M221 (THC on) is injected only based on isCorner for each machine point. The lead-in arc and overburn extension are generated from the finalPath array, which passes through the same machine point conversion and gets the same THC state. THC should be
  explicitly locked off (M220) for the entire lead-in and overburn sequence — the arc is not yet stable during lead-in (torch still establishing), and the overburn is intentionally outside the cut path. Most professional post-processors hard-code THC off
  for lead-in/out.

  I. Velocity profiling uses Euclidean 4D distance including A-axis degrees.
  let dMachine = sqrt(dXm*dXm + dYm*dYm + dZm*dZm + dAm*dAm)
  Mixing mm (dXm, dYm, dZm) with degrees (dAm) in a Euclidean distance is dimensionally inconsistent. A 10mm X move and a 10° A move are not comparable. The junction speed limits and SimCNC G94 feedrate calculation both use dMachine, so the G94 F-value is
   wrong whenever there is significant A-axis motion.

  The correct dMachine for SimCNC G94 mode should be the 4D Euclidean distance where A is converted to the equivalent linear distance: dAm * (π * OD / 360). For standard mode, G-code F is surface speed which is dS based (already using the correct surface
  metric). This is a correctness issue in SimCNC G94 mode specifically.

  J. Sorting prioritizes endCut before internals.
  case .endCut: return 0     // executed first
  case .hole, .cutout, .notch: return 1
  case .startCut: return 2   // executed last

  This is the right order (cut interior first, then sever from right-to-left). But the thermal hedging path (enableThermalHedging = true) puts internals first and severs right-to-left, while the non-thermal-hedging path uses this sort. The two paths
  produce different sequencing, which could confuse users comparing output with/without thermal hedging enabled.

  ---
  Summary: Priority Ranking

  ┌──────────┬──────────────────────────────────────────────────────────────┬───────────────────────────────────────────┐
  │ Priority │                            Issue                             │                  Impact                   │
  ├──────────┼──────────────────────────────────────────────────────────────┼───────────────────────────────────────────┤
  │ Critical │ Missing pierce delay (G4 dwell after M3)                     │ Bad pierce quality, arc dropout           │
  ├──────────┼──────────────────────────────────────────────────────────────┼───────────────────────────────────────────┤
  │ Critical │ k factor wrong for rectangular HSS                           │ 5% kerf/lead-in geometry error throughout │
  ├──────────┼──────────────────────────────────────────────────────────────┼───────────────────────────────────────────┤
  │ High     │ No miter-limit in kerf offset                                │ Spike artifacts at corner transitions     │
  ├──────────┼──────────────────────────────────────────────────────────────┼───────────────────────────────────────────┤
  │ High     │ Damped Jacobian uses round-tube kinematics for rect profiles │ Torch off-surface at HSS corners          │
  ├──────────┼──────────────────────────────────────────────────────────────┼───────────────────────────────────────────┤
  │ High     │ Corner radius hardcoded at 10% vs. ASTM A500 actual          │ Wrong A-axis profile, wrong safe-Z        │
  ├──────────┼──────────────────────────────────────────────────────────────┼───────────────────────────────────────────┤
  │ High     │ THC not disabled during lead-in/overburn                     │ Arc instability during path entry         │
  ├──────────┼──────────────────────────────────────────────────────────────┼───────────────────────────────────────────┤
  │ High     │ Missing IHS cycle                                            │ Surface-height errors on runout/sag       │
  ├──────────┼──────────────────────────────────────────────────────────────┼───────────────────────────────────────────┤
  │ Medium   │ Lead-in maintains cut height, not pierce height              │ Lead-in trace mark on material            │
  ├──────────┼──────────────────────────────────────────────────────────────┼───────────────────────────────────────────┤
  │ Medium   │ 4D dMachine mixes mm and degrees                             │ Wrong SimCNC G94 feedrate                 │
  ├──────────┼──────────────────────────────────────────────────────────────┼───────────────────────────────────────────┤
  │ Medium   │ OCCT C++ exceptions not caught                               │ Process crash on malformed STEP           │
  ├──────────┼──────────────────────────────────────────────────────────────┼───────────────────────────────────────────┤
  │ Medium   │ PCA axis fragile under heavy notch cuts                      │ Misdetection of tube axis                 │
  ├──────────┼──────────────────────────────────────────────────────────────┼───────────────────────────────────────────┤
  │ Low      │ No TopAbs_SHELL fallback for multi-body STEP                 │ Some STEP files parse as empty            │
  ├──────────┼──────────────────────────────────────────────────────────────┼───────────────────────────────────────────┤
  │ Low      │ No per-feature process parameters                            │ Same speed/height for all feature types   │
  └──────────┴──────────────────────────────────────────────────────────────┴───────────────────────────────────────────┘
