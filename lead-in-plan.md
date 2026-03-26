# Lead-In Configuration — Integration Plan

## Context

The current lead-in system lives entirely in `ToolpathPlanner.buildLeadIn()`. It reads
three flat scalars from `GCodeSettings` (`leadInDistance`, `leadInAngle`,
`leadInAngleDistance`) and produces one of three hardcoded behaviours based on feature
type: rotational-arc (severs), circular-arc (holes/cutouts), or linear fallback.

There is no per-feature-type configuration, no per-feature override, and no UI
representation of the computed lead-in geometry.

---

## Lead-In Strategies

| Strategy | When to use | Why |
|---|---|---|
| **Rotational arc** (A-only) | startCut / endCut | Keeps torch off the stock face; no Z/X witness mark on the sever |
| **Tangent arc** | Holes ≥ ~15 mm, cutouts, notches | Torch is at speed when it first touches the kerf → clean entry, no dwell divot |
| **Linear (angled)** | Holes 8–15 mm, tight cutouts | Simpler; arc won't fit inside feature; 30–45° off tangent reduces pierce-dwell |
| **Center pierce** | Holes < ~12 mm | Plasma blows out safely at interior centroid; line runs outward to cut path |
| **Spiral** | Holes 10–20 mm, surface finish matters | Smooth velocity ramp-up; increasing radius reduces kerf blowout risk |
| **None** | < 5 mm holes, relief slots | Not enough room; pierce directly on kerf, accept the mark |

**Practical auto-select rule:** use `centerPierce` when `hole_diameter < smallHoleDiameterThreshold`
(default 12 mm). Above that, `tangentArc`. Override per-feature as needed.

---

## Architecture Changes

### Step 1 — `LeadInConfig.swift` (new file) ✅

Define `LeadInStrategy` enum and `LeadInConfig` struct with per-strategy parameters and
static defaults for each feature type. All fields are `Codable` + `Equatable` for
settings persistence and SwiftUI binding.

**File:** `pipe-macos/LeadInConfig.swift`

### Step 2 — `GCodeSettings` migration

Replace the three flat scalars with per-type configs and a per-feature override dict:

```swift
// Remove:
var leadInDistance: CGFloat
var leadInAngle: CGFloat
var leadInAngleDistance: CGFloat

// Add:
var leadInBySeverCut:  LeadInConfig = .defaultSeverCut
var leadInByHole:      LeadInConfig = .defaultHole
var leadInByCutout:    LeadInConfig = .defaultCutout
var leadInByNotch:     LeadInConfig = .defaultNotch
var smallHoleDiameterThreshold: Double = 12.0
/// Per-feature overrides keyed by GeometricFeature.id
var leadInOverrides: [Int: LeadInConfig] = [:]
```

Backwards-compatible: keep the old scalars as `@available(*, deprecated)` aliases
for one cycle, or just update all call sites (they're internal).

### Step 3 — `PlannedPath` split

Add `leadInPoints` so the UI can render lead-in geometry separately from the cut path:

```swift
struct PlannedPath {
    var leadInPoints: [ToolpathPoint]   // approach geometry only — NEW
    var cutPoints:    [ToolpathPoint]   // the actual cut path
    let isInternal: Bool
}
```

The emitter concatenates `leadInPoints + cutPoints` as before — no emitter changes needed.

### Step 4 — `ToolpathPlanner.buildLeadIn()` refactor

```swift
private static func buildLeadIn(
    path: [ToolpathPoint],
    config: LeadInConfig,
    feature: GeometricFeature,
    settings: GCodeSettings,
    isInternal: Bool,
    isScrapLeft: Bool
) -> (leadIn: [ToolpathPoint], cutPath: [ToolpathPoint])
```

Internal dispatch:
```swift
switch config.strategy {
case .rotationalArc:  buildRotationalArcLeadIn(...)
case .tangentArc:     buildTangentArcLeadIn(...)
case .linear:         buildLinearLeadIn(...)
case .centerPierce:   buildCenterPierceLeadIn(...)
case .spiral:         buildSpiralLeadIn(...)
case .none:           return ([], path)
}
```

### Step 5 — Config resolver in `GCodeGenerator`

```swift
func resolveLeadInConfig(for feature: GeometricFeature, settings: GCodeSettings) -> LeadInConfig {
    // 1. Per-feature override wins
    if let override = settings.leadInOverrides[feature.id] { return override }

    // 2. Type-level default, with small-hole auto-select
    switch feature.type {
    case .startCut, .endCut:
        return settings.leadInBySeverCut
    case .hole:
        let diameter = feature.dimensions["diameter"] ?? feature.dimensions["width"] ?? 0
        return diameter < settings.smallHoleDiameterThreshold
            ? LeadInConfig(strategy: .centerPierce)
            : settings.leadInByHole
    case .cutout:
        return settings.leadInByCutout
    case .notch:
        return settings.leadInByNotch
    }
}
```

### Step 6 — Center-pierce geometry

New geometry for `centerPierce` strategy:

1. Compute centroid `(Cx, Ca)` of the hole's `rawPath` in surface space.
2. Find the cut-path point nearest to the centroid — this is the approach target.
3. Interpolate `N` steps from centroid to approach target.
4. Reorder cut path to start at approach target.

```swift
private static func buildCenterPierceLeadIn(
    path: [ToolpathPoint], config: LeadInConfig
) -> (leadIn: [ToolpathPoint], cutPath: [ToolpathPoint]) {
    let cx = path.map(\.x).reduce(0, +) / CGFloat(path.count)
    let ca = path.map(\.a).reduce(0, +) / CGFloat(path.count)

    let closest = path.enumerated().min { a, b in
        hypot(a.element.x - cx, a.element.a - ca) <
        hypot(b.element.x - cx, b.element.a - ca)
    }!

    let steps = config.centerPierceSteps
    let leadIn = (0...steps).map { i -> ToolpathPoint in
        let t = CGFloat(i) / CGFloat(steps)
        return ToolpathPoint(x: cx + t * (closest.element.x - cx),
                             a: ca + t * (closest.element.a - ca))
    }

    let cutPath = Array(path[closest.offset...]) + Array(path[..<closest.offset])
    return (leadIn, cutPath)
}
```

### Step 7 — Spiral geometry

Archimedean spiral from centroid outward to the cut-path radius, with continuously
increasing angular step size to maintain constant arc-length per segment:

```swift
private static func buildSpiralLeadIn(
    path: [ToolpathPoint], config: LeadInConfig, stockRadius: CGFloat
) -> (leadIn: [ToolpathPoint], cutPath: [ToolpathPoint]) {
    // Compute centroid and feature radius in (X, A·r) space
    // Spiral: r(θ) = r_max · θ / θ_total,  θ ∈ [0, turns·2π]
    // Map back to (X=Cx, A=Ca + θ_degrees) — pure rotational spiral on surface
    ...
}
```

### Step 8 — UI

**Feature detail panel additions:**

- Lead-in path rendered as dashed overlay on the 2D surface preview
  (orange for lead-in, blue for cut path)
- Per-feature strategy picker (appears when feature is selected)
- Conditional parameter sliders (only show params relevant to chosen strategy)
- "Auto" badge shown when no override is set (using type-level default)

**Settings panel additions:**

- Per-type default strategy selector (one row per feature type)
- Small-hole diameter threshold slider
- Parameter editors per type

---

## File Change Summary

| File | Change |
|---|---|
| `LeadInConfig.swift` (new) | `LeadInStrategy` enum + `LeadInConfig` struct |
| `GCodeSettings` (in GCodeGenerator.swift) | Replace 3 scalars → per-type configs + overrides dict |
| `ToolpathPlanner.swift` | Dispatch on `LeadInConfig.strategy`; return `(leadIn:, cutPath:)` |
| `PlannedPath` (in ToolpathPlanner.swift) | Add `leadInPoints: [ToolpathPoint]` |
| `GCodeGenerator.swift` | Add `resolveLeadInConfig()` helper |
| `GCodeEmitter.swift` | No change — emits `machinePoints` linearly |
| `ContentView.swift` | Lead-in overlay render + feature config panel |
| `SettingsView.swift` | Per-type lead-in configuration UI |

---

## Implementation Order

1. `LeadInConfig.swift` — pure data, no dependencies ✅
2. `GCodeSettings` migration — keep defaults, add new fields
3. `ToolpathPlanner` refactor — split return type, add strategy dispatch
4. New geometry: `centerPierce` and `spiral`
5. Unit tests for each strategy and the auto-select resolver
6. UI: overlay render (read-only) → config panel
