# Pipe macOS

## Goals

This software is supposed to be the backbone for rotary CNC plasma cutting.

Given a STEP file input, it performs object feature detection to correctly identify the shape, form and size of every stock in the STEP file.
The feature detection is rotation invariant, robust, fast and stable.

Once the STEP file is parsed, it renders all components from the step file, even if the component is NOT stock it understands how to cut on an XZYA rotary plasma cutter.

Once a single stock profile is selected, the software automatically displays identical stock profiles, aligned on a common axis in the packing view.

