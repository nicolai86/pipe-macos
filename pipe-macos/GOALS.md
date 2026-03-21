# Pipe macOS
## Overview

Pipe macOS is an advanced, high-precision CAM post-processor and 3D visualization tool designed specifically for 4-axis (XYZA) rotary CNC plasma cutters. Built to ingest raw STEP files, it serves as the ultimate bridge between 3D CAD assemblies and flawless machine execution. By bypassing the limitations of standard controllers, Pipe macOS delivers 5-axis equivalent cutting performance for structural HSS (Square/Rectangular) and HSS-O (Round) tubing.

## Constraints

- My CNC rotary plasma cutter has no roll/ tilt functionality in the torch mount.

## Hardware setup
Understanding this is important for GCode generation

My X axis is where the stock moves along. The plasma torch is fixed at the far end, so for cutting most shapes X has to move forward and backward to keep the stock properly positioned below the torch
My Y axis moves the torch left-to-right above the stock.
My Z axis moves the plasma torch up-and-down.
My A axis rotates the stock.

Y=0 is exactly above the X axis, so plunging on Z is always centered on whatever face is pointing up.

X and A have to move and accelerate heavy stock, so they are using Teknic clearpath servos (SDHP-3446P-ELN) with a 10:1 reduction. The X axis moves with M1.5 rack and pinion (TODO pinion teeth count). The A axis uses a ZBT200 hollow rotator.
Y and Z use STP-MTRH-23079 stepper motors; The Y Axis also has a 10:1 gear reduction on a M1.5 rack and pinion (TODO pinion teeth count). The Z axis has a 1605 leadscrew.
All axis have different acceleration constraints, so the software has to account for the different capabilities of each motion axis.

## Intelligent Feature Detection & 3D Packing
Robust Object Recognition: Utilizes Attributed Adjacency Graph (AAG) and Principal Component Analysis (PCA) to achieve rotation-invariant, high-speed feature detection. It automatically identifies the exact shape, profile, and dimensions of all stock within a STEP file.

Universal Assembly Rendering: Parses and renders complete 3D assemblies, visually distinguishing between cuttable stock and non-stock components.

Smart Packing Workspace: Upon selecting a target stock profile, the software automatically aggregates identical profiles and aligns them along a common axis in the Pack View.

Dynamic Nesting: The Pack View acts as the absolute source of truth for G-Code generation. Users can seamlessly add, remove, or modify part quantities, with all changes instantly reflected in the 3D packing model.

 Dual-Loop THC Conflict Management (The Square Tube Problem): 
    Disable THC for the rotation of HSS tubes so that the system avoids jittering the torch into the workpiece

## Advanced Rotary Kinematics Engine (2026 SOTA)
Because standard controllers like SimCNC do not natively support Inverse Time Feedrate (G93) or true Tool Center Point (TCP) for rotary axes, Pipe macOS handles all advanced trajectory planning offline:

Offline TCP Interpolation: Dynamically coordinates the Y, Z, and A axes to keep the torch perfectly perpendicular to the metal surface at all times, tracking complex corner radii while maintaining true surface speed.

Non-Linear Jacobian Velocity Profiling: A sophisticated forward/backward look-ahead algorithm calculates centripetal-equivalent cornering forces using second derivatives. It dynamically throttles the spoofed G94 vector feedrate to ensure no individual motor (X, Y, Z, or A) ever exceeds its physical acceleration limits, completely eliminating servo stalls and corner blowout.

Chirality-Aware Plasma Swirl Engine: Mathematically evaluates the signed area (winding direction) of extracted features to enforce physical plasma swirl rules. It automatically forces counter-clockwise physical travel for internal cuts and clockwise travel for external cuts, ensuring the "good" edge is always on the right side of the kerf.

Kerf-Aware Geometric Lead-Ins: Generates mathematically perfect tangent sweep arcs that originate deep within the scrap zone. It dynamically injects G41 or G42 based on the swirl chirality and explicitly clamps the linear lead-in length to exceed the tool radius, preventing controller buffer crashes.

Longest-Segment Pierce Optimization: Analyzes the geometry of internal cutouts and automatically shifts the pierce point to the exact midpoint of the longest straight segment, giving Torch Height Control (THC) maximum time to stabilize before cornering.

Tangential Overburn: Replaces standard rotational overburn with a purely tangential vector extension, ensuring the plasma arc stays safely inside the existing kerf upon finishing a cut, preventing lead-out divots on the keep-stock.

Hierarchical B-Rep Topological Extraction: Bypasses distance-guessing edge stitchers by maintaining strict OpenCASCADE wire continuity, ensuring complex features spanning multiple faces are flawlessly stitched without jumping kerf gaps.

## SimCNC Integration
The G-code output is heavily optimized for SimCNC's specific operational constraints:

Delegated Probing: Initial Height Sensing (IHS), pierce dwelling, and drops to cut-height are fully delegated to the controller's internal M3 macro.

Pre-Digested Trajectory: SimCNC acts as a high-performance execution terminal. All velocity smoothing, corner deceleration, and continuous-velocity blending are pre-calculated by Pipe macOS, eliminating data starvation and trajectory aliasing.
