Stock Profile Classification Debug Guide

Problem Statement

The compute​True​Cross​Section function is failing to correctly identify rectangular tube dimensions when the tube is rotated in 3D space, causing is​Same​Stock​Profile to fail matching identical tubes with different orientations.

Root Cause Analysis

Current Debug Output Issues

Solid 2 (38.1×38.1 mm square, rotated):

```
Found 4 normals perpendicular to tube axis
Candidate side walls:
  [0] axis=(0.91381156, -0.0, -0.40613848), count=130  ← MITER FACE
  [1] axis=(1.0, -0.0, -0.0), count=64                 ← Side wall
  [2] axis=(0.0, 0.09950372, -0.99503714), count=34    ← Side wall?
  [3] axis=(0.0, -0.0, 1.0), count=16                  ← End cap
Using top 4 side walls for measurement
⚠️ Failed to find two orthogonal side-wall axes

```

• Issue: Miter face [0] has highest vertex count (130), polluting the selection
• Result: Can't find two perpendicular axes → fallback to bounding box

Solid 3 (38.1×38.1 mm square, rotated differently):

```
Found 3 normals perpendicular to tube axis
Candidate side walls:
  [0] axis=(0.75257665, 0.0, 0.65850455), count=192   ← MITER FACE
  [1] axis=(0.70352644, 0.10050379, -0.70352644), count=32
  [2] axis=(0.65850455, -0.0, -0.75257665), count=16
Using top 3 side walls
Dominant side-wall axes: a1=(0.75257665, 0.0, 0.65850455), a2=(0.70352644, 0.10050379, -0.70352644)
True cross-section: width=52.66, height=191.05  ← GARBAGE (miter-stretched)

```

• Issue: Miter face [0] selected as primary axis
• Result: Projection onto miter face produces nonsensical dimensions

The Core Problem

Miter faces have high vertex counts because they're large surface areas created by tessellating angled cuts. This makes them appear "dominant" in frequency-based selection, even though they're not the true rectangular side walls.

Detection Strategy

What Makes a Valid Side Wall?

For a rectangular tube, side walls have these properties:

1. Perpendicular to tube axis (already filtered ✅)
2. Form perpendicular pairs (4 walls → 2 orthogonal pairs)
3. Have perpendicular partners in the candidate list

What Makes a Miter Face?

Miter faces:

1. Perpendicular to tube axis ✅ (passes first filter)
2. Tilted relative to tube body (not aligned with cardinal directions)
3. No perpendicular partner (only 1-2 miter faces, not 4 like side walls)
4. High vertex count (large angled surface area)

Proposed Fix

Current Logic (Broken)

```
// Takes top 4 by frequency → includes miter faces
let validSideWalls = Array(sideWallNormals.prefix(4))

```

New Logic (Filter by Perpendicularity)

```
// Find normals that have at least one perpendicular partner
var validSideWalls: [(axis: SIMD3<Float>, count: Int)] = []

for candidate in sideWallNormals {
    var hasPerpendicularPartner = false
    
    for other in sideWallNormals {
        if candidate.axis == other.axis { continue }
        
        // Check if perpendicular (dot product ≈ 0)
        let dotProduct = abs(dot(candidate.axis, other.axis))
        if dotProduct < 0.15 { // Perpendicular
            hasPerpendicularPartner = true
            break
        }
    }
    
    if hasPerpendicularPartner {
        validSideWalls.append(candidate)
    } else {
        print("Excluding [\(candidate.axis)]: no perpendicular partner (likely miter)")
    }
}

// Take top 2 by frequency (the two perpendicular wall pairs)
let topSideWalls = Array(validSideWalls.sorted { $0.count > $1.count }.prefix(2))
```

Expected Behavior After Fix

Solid 2:

Candidate side walls:
  [0] axis=(0.91381156, -0.0, -0.40613848), count=130
  [1] axis=(1.0, -0.0, -0.0), count=64
  [2] axis=(0.0, 0.09950372, -0.99503714), count=34
  [3] axis=(0.0, -0.0, 1.0), count=16
Excluding [0.91381156, -0.0, -0.40613848]: no perpendicular partner (likely miter)
Excluding [0.0, -0.0, 1.0]: no perpendicular partner (likely end cap)
Found 2 side walls with perpendicular partners
Using top 2 perpendicular side walls
Dominant side-wall axes: a1=(1.0, 0.0, 0.0), a2=(0.0, 0.09950372, -0.99503714)
True cross-section: width=38.1, height=38.1 ✅


Solid 3:

Candidate side walls:
  [0] axis=(0.75257665, 0.0, 0.65850455), count=192
  [1] axis=(0.70352644, 0.10050379, -0.70352644), count=32
  [2] axis=(0.65850455, -0.0, -0.75257665), count=16
Excluding [0.75257665, 0.0, 0.65850455]: no perpendicular partner (likely miter)
Found 2 side walls with perpendicular partners
Using top 2 perpendicular side walls
Dominant side-wall axes: a1=(0.70352644, 0.10050379, -0.70352644), a2=(0.65850455, -0.0, -0.75257665)
True cross-section: width=38.1, height=38.1 ✅

Additional Issues to Check

1. Normal Rounding Precision
Current code rounds to 0.1, which may cause near-perpendicular normals to fail the perpendicularity test after quantization.

Check: If two normals are nearly perpendicular in raw form, do they remain perpendicular after rounding?

2. Half-Space Folding
Code forces normals to positive half-space to collapse opposite normals. This is correct for parallel faces (top/bottom become same key), but perpendicular faces should remain distinct.

Verify: Perpendicular normals should NOT collapse after half-space forcing.

3. Tolerance Values
• Perpendicular test: dot​Product < 0​.15
• Tube axis alignment: perp​To​Axis < 0​.15

Question: Are these tolerances appropriate for 0.1-rounded normals?

Testing Checklist

• [ ] Solid 2: Correctly identifies 2 perpendicular side walls
• [ ] Solid 2: Excludes miter face with count=130
• [ ] Solid 3: Correctly identifies 2 perpendicular side walls
• [ ] Solid 3: Excludes miter face with count=192
• [ ] Both solids: Final dimensions match 38.1 × 38.1 ± 2mm
• [ ] is​Same​Stock​Profile: Returns true for both solids

Next Steps

1. Apply the perpendicular partner filter
2. Run debug output to verify miter exclusion
3. Check final cross-section dimensions
4. Test is​Same​Stock​Profile matching
