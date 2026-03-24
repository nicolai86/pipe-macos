1. Evolve from Static DLS to Dynamic Jacobian DampingCurrent Implementation:In GCodeGenerator.swift, your singularity avoidance relies on a static Damped Least-Squares (DLS) calculation using a fixed singularityDampingFactor ($\lambda$).The Limitation:A fixed $\lambda$ introduces a continuous, mathematically intentional tracking error across the entire toolpath, even on completely flat faces where singularities are not a risk.The Improvement:The damping factor must be dynamic. Implement an algorithm where $\lambda$ scales proportionally based on the condition number of the Jacobian matrix, or by monitoring the determinant $|J(\Theta)|$.When operating far from a singularity (e.g., flat tube faces), $\lambda \to 0$, allowing the equation to behave as a standard pseudoinverse for mathematically perfect tracking.As the machine approaches a geometric transition that risks gimbal lock, $\lambda$ smoothly increases to penalize excessive joint velocities.Context for a deeper dive: I can walk you through implementing a manipulability ellipsoid function to dynamically calculate this condition number if you'd like to refine the math.
2. Transition to RTCP (Rotational Tool Center Point) OutputCurrent Implementation:Your convertToMachine function calculates the exact inverse kinematics offline, generating literal machine joint positions ($Xm, Ym, Zm, Am$). This is a legacy "CAM-Calculated TCP" approach.The Limitation:If the machine operator swaps a plasma consumable shield that is just $1.0\text{ mm}$ longer than the dimension programmed into your offline CAM, the physical pivot length changes. Because your G-code contains hardcoded Cartesian offsets, the torch tip will swing wildly off the cut path during A-axis rotations, resulting in ruined HSS stock.The Improvement:Implement a toggle to output RTCP-compliant G-code (e.g., using G43.4 for Fanuc/Syntec or TRAORI for Siemens). Instead of calculating the final joint angles offline, output the part-centric coordinates alongside the tool orientation vector: $(X, Y, Z, I, J, K)$.The physical CNC controller will then process the inverse kinematics in real-time, allowing the operator to adjust tool-length offsets directly at the pendant without needing a new G-code file from your software.

2. Perfecting the G94 "Spoofed" Feedrate FormulaSince you cannot use G93 Inverse Time, you must calculate a highly specific G94 Units/Min feedrate for every single micro-segment to maintain Constant Surface Speed (CSS). Your code has a useSimCNC flag, but the math can be tightened.The Problem: SimCNC calculates the time to complete a line of G-code by treating the A-axis degrees as if they were linear units (mm). If you command a move of X=10mm and A=90°, SimCNC calculates a vector length of $\sqrt{10^2 + 90^2} = 90.55$.The Fix: To trick SimCNC into moving the plasma arc at your target surface velocity ($V_{surface}$), your Swift code must calculate the exact physical surface distance of the segment, determine the time it should take, and back-calculate the G94 $F$ value.Use this specific formula for your fG94 calculation:$$F_{spoofed} = V_{surface} \cdot \frac{\sqrt{\Delta X_{machine}^2 + \Delta Y_{machine}^2 + \Delta Z_{machine}^2 + \Delta A_{machine}^2}}{\text{True Surface Distance}}$$This ensures that regardless of how SimCNC blends the axes, the temporal execution of the block results in the correct surface speed.

3. Z-Axis THC Conflict Resolution (Stutter Mitigation)Your current Jacobian solver outputs exact $Z_m$ coordinates for every segment (curr.Zm + settings.cutHeight).The Problem: SimCNC features a highly aggressive standalone THC (Torch Height Control) module that intercepts and overrides Z-axis step pulses based on live arc voltage. If your G-code is continuously commanding Z-axis micro-adjustments while the THC is simultaneously trying to drive the Z-axis to maintain voltage, the trajectory planner and the THC loop will fight each other. This causes severe Z-axis stutter and vertical ribbing on your cut edge.The Fix: For round stock (HSS-O), your G-code should output a static, locked Z-height for the entire cut, allowing the hardware THC complete autonomy to track the warped tube. You only need to explicitly output Z-axis moves when clearing the corners of square/rectangular tubing, which pairs perfectly with your existing M220 (THC Off) and M221 (THC On) macro logic.

4. Parametric "Rapid Re-Post" ArchitectureBecause you cannot use G43.4 RTCP, your generated G-code is rigidly tied to the physical pivot length of your specific torch setup.The Problem: If you swap a plasma retaining cap and the torch is now 1.2mm shorter, the inverse kinematics embedded in your G-code are instantly wrong. The torch will drift off the cutline during A-axis rotations.The Fix: Since you can't fix this at the machine pendant, you must make it effortless to fix in your software. Expose torchPivotOffset as a primary, top-level UI parameter in your Mac application. Ensure your Swift application can regenerate and push a new G-code file in under 2 seconds, effectively treating the offline post-processor as a fast, external RTCP calculator.

Feature Detection

  1. Saddle / cope cut classification
  The detector currently produces four types (hole, notch, cutout, sever). Pipe-to-pipe intersections — saddle cuts — are the most common complex cut in structural fabrication and are not identified. They have
  distinct properties: the loop is a closed ellipse-like curve on a round tube, spans near-360° in A but varies continuously in X. Detecting them explicitly (via loop shape analysis in the X–A plane — high X
  variance, full A coverage) would allow better pierce placement, speed scheduling, and lead-in geometry.

  2. Geodesic surface unrolling instead of cylindrical projection
  Feature paths are currently projected to 2D as (axial_distance, atan2_angle). For straight round tubes this is exact. For rectangular HSS the A-axis is actually a piecewise linear function of arc length (flat
  faces + corners), not a uniform angle. Unrolling the path along the true surface arc length for the kerf-compensation and lead-in geometry would improve accuracy on rectangular profiles, especially at
  tight-radius corners.

  3. Replace the fixed 2 mm stitch tolerance with a CAD-derived value
  The 2 mm stitching tolerance is derived from the 1 mm edge discretisation step and works well in practice, but it is a heuristic. Computing the maximum allowed stitch gap from the actual mesh deflection reported
  by BRepMesh_IncrementalMesh (0.1 mm in the current code) would allow the tolerance to scale automatically if the mesh quality setting is ever changed.

  4. Inner bore feature extraction
  The current manifold edge test identifies features as cuts through the outer wall. Tubes with pre-bored holes (e.g., structural sections with service holes) have inner-bore faces that are misclassified or
  skipped. Tracking inner vs outer hull separately (the isInner wire flag is already extracted from the bridge but not currently used in the Swift side) would handle this.

  ---
  Kinematics & GCode

  7. G93 Inverse Time Mode as an alternative to G94 spoofing
  The 4D spoofed G94 feedrate is a clever workaround for SimCNC's limitation, but it is mathematically fragile when the A-axis displacement is small relative to the XYZ displacement (the denominator dMachine
  becomes XYZ-dominated and the time preservation breaks down). G93 (Inverse Time) is the standard solution for this exact problem — the F-word specifies reciprocal time (1/min) rather than velocity, making it
  exact regardless of axis mix. If SimCNC adds G93 support, or for LinuxCNC/Mach4 post-processors, this would be the correct output mode.

  8. Clipper/Clipper2-based kerf offset instead of the geometric bisector
  The current offline kerf bisector works correctly on smooth convex paths but produces overcutting on re-entrant corners and can create self-intersecting offset paths on tight concave geometry (e.g., narrow
  slots). Clipper2 (the polygon clipping library used in PrusaSlicer, FreeCAD, and most modern CAM tools) handles all degenerate cases including self-intersections, island detection, and winding-order correction,
  and is MIT-licensed with a clean C++ API that slots directly into the existing OCCT bridge.

  9. Velocity-dependent arc angle for rectangular HSS
  When the torch traverses a corner on rectangular HSS, the A axis rotates ~90° while X and Z barely move. The current profiler throttles feedrate based on A-axis acceleration limits, which is correct. However the
  plasma arc has a physical kerf that drifts in the direction of motion at high speed ("plasma lag"). On a 90° A-axis sweep the effective cut direction changes continuously, so at high A-speeds the bottom of the
  cut lags behind the top. A velocity-adaptive dwell or speed cap specifically for HSS corner sweeps would improve cut squareness in heavy material.

  10. Automatic speed reduction on tight-radius internal features
  Currently a single feedRate is applied to all features. In plasma cutting, tight-radius arcs require lower feed rates to maintain cut quality — the arc cannot follow the curvature at full speed. Computing a
  per-segment curvature from the X–A path and applying a curvature-based speed cap (similar to how Fusion360's "Minimum Radius" feed reduction works) would automatically protect small holes and notch radii.

  ---
  Pack Layout

  11. Automatic kerf gap insertion between pieces
  The current packer places pieces immediately adjacent. In reality, the sever cuts consume a kerf width of material from each neighbouring piece end. Without accounting for this, the piece adjacent to a sever is
  slightly undersized. Inserting kerfWidth / 2 clearance gaps automatically at each sever boundary would make pack layout dimensionally correct without manual adjustment.

  12. 1D remnant-aware bin packing
  Since all pieces share the same cross-section profile, the packing problem is purely 1D (lengths along the stock bar). A proper first-fit-decreasing algorithm would find the minimum number of stock bars and the
  optimal cut order to minimise waste and remnant length. The current greedy thermal sequence optimises heat distribution but not material utilisation.

  ---
  Post-Processor Architecture

  13. Controller-agnostic post-processor layer
  The output is currently hard-wired for SimCNC (G94 spoofing, M220/M221 THC, M3 pierce delegation). A thin post-processor abstraction — where the core generates a neutral toolpath IR (machine points + timing) and
  a swappable post-processor emits the final G-code syntax — would allow targeting LinuxCNC, Mach4, Fanuc, and Beckhoff TwinCAT without duplicating the kinematics. This is exactly how commercial CAM tools
  (Fusion360, Mastercam) handle multi-controller support.

  14. Toolpath simulation / dry run output
  There is currently no way to preview the 4D toolpath in 3D before cutting. Generating a SceneKit animation of the torch position over time (using the already-computed machinePoints and segments arrays) would
  allow catching collisions, excessive Z moves, and bad lead-in placement before touching the machine.

  ---
  Plasma Physics

  15. Dross-side awareness in sever cut chirality
  The current chirality engine forces CCW travel for sever cuts with scrap on the left. In plasma cutting, the swirl direction of the gas causes the bottom of the cut to be cleaner on the right side of travel. For
  sever cuts where both sides are "keep" stock (e.g., cutting a bar in half), the operator should be able to specify which side is the priority face and the chirality engine should honor it.

  16. Pierce height → cut height transition profile
  Currently pierce height and cut height are separate Z values but the transition between them happens as an instantaneous step in the G-code (the M3 macro handles it). For thick material (>6 mm), a controlled Z
  ramp from pierce height to cut height during the lead-in motion reduces the risk of the arc extinguishing during the transition and improves lead-in dross. This could be emitted as an explicit G1 Z move during
  the lead-in arc.
