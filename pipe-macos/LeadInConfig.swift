import Foundation

// MARK: - Lead-In Strategy

/// The geometric approach the torch takes when entering a cut.
///
/// Each strategy is suited to different feature types and sizes. The resolver
/// in `GCodeGenerator` auto-selects based on feature type and dimensions, but
/// any feature can carry a per-feature `LeadInConfig` override.
enum LeadInStrategy: String, Codable, CaseIterable, Identifiable {

    /// **Rotational arc** — A-axis-only sweep; no X movement.
    ///
    /// The torch rotates around the tube before crossing the cut line, so it
    /// is already at full cutting speed on entry and the pierce mark lands in
    /// scrap material off the end of the tube. No X-axis witness mark is left
    /// on the sever face.
    ///
    /// _Best for:_ `startCut`, `endCut`.
    case rotationalArc

    /// **Tangent arc** — circular arc that meets the cut path tangentially.
    ///
    /// Because the torch arrives tangent to the kerf, it is already at cutting
    /// speed when it first touches the cut line. This eliminates the dwell divot
    /// that a linear approach leaves at the pierce point.
    ///
    /// _Best for:_ holes ≥ ~15 mm, cutouts, notches with sufficient clearance.
    case tangentArc

    /// **Linear (angled)** — straight line approaching the cut path from outside.
    ///
    /// Simpler than a tangent arc and fits in tighter spaces. The angle is
    /// measured from the cut-path tangent at the pierce point; 0° is a straight
    /// along-tangent approach, 90° is perpendicular. Values of 30°–60° are
    /// typical for clean angled entry without excessive pierce-dwell.
    ///
    /// _Best for:_ holes 8–15 mm, tight cutouts, notches.
    case linear

    /// **Center pierce** — pierce at the feature centroid, straight line to cut path.
    ///
    /// The torch fires in the middle of the waste area. A straight approach line
    /// then carries it outward to the nearest point on the cut path. The pierce
    /// mark is safely away from the kerf edge, preventing blowout on the part
    /// boundary.
    ///
    /// _Best for:_ holes smaller than `GCodeSettings.smallHoleDiameterThreshold`
    /// (default 12 mm) where a tangent arc cannot fit inside.
    case centerPierce

    /// **Spiral** — Archimedean spiral from the feature centroid to the cut path.
    ///
    /// Produces a smoother velocity ramp-up than `centerPierce` because the
    /// continuously-increasing radius means constant arc length per angular step.
    /// The torch is already moving in a circular arc when it reaches the cut
    /// line, reducing kerf blowout compared to a straight approach.
    ///
    /// _Best for:_ holes 10–20 mm where surface finish matters.
    case spiral

    /// **None** — pierce directly on the cut line; no approach geometry.
    ///
    /// The pierce mark is visible on the kerf edge. Only acceptable when there
    /// is no room for any approach geometry, or when the feature is so small
    /// that the mark will be hidden in the finished part.
    ///
    /// _Best for:_ holes < 5 mm, relief slots, test cuts.
    case none

    // MARK: Display

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rotationalArc: return "Rotational arc"
        case .tangentArc:    return "Tangent arc"
        case .linear:        return "Linear"
        case .centerPierce:  return "Center pierce"
        case .spiral:        return "Spiral"
        case .none:          return "None (on-path)"
        }
    }

    var shortDescription: String {
        switch self {
        case .rotationalArc:
            return "A-axis sweep only. No X movement. Ideal for sever cuts."
        case .tangentArc:
            return "Circular arc meets cut path tangentially. No dwell mark."
        case .linear:
            return "Straight angled approach. Fits tighter spaces than an arc."
        case .centerPierce:
            return "Pierce at centroid, line to cut path. Safe for small holes."
        case .spiral:
            return "Archimedean spiral from centroid. Smooth entry for medium holes."
        case .none:
            return "Pierce on cut line. Leaves visible mark. Use for tiny features."
        }
    }

    /// Whether this strategy is valid as the lead-in for a sever cut
    /// (startCut / endCut). Sever cuts must not move X before the cut line
    /// is reached, so only the rotational-arc approach is safe.
    var isSuitableForSeverCut: Bool {
        self == .rotationalArc || self == .none
    }

    /// Whether this strategy requires the feature to have a measurable interior
    /// (i.e., the torch needs to pierce inside the scrap area).
    var requiresInterior: Bool {
        self == .centerPierce || self == .spiral
    }
}

// MARK: - Lead-In Configuration

/// All parameters that control lead-in approach geometry for one feature or
/// feature type.
///
/// `LeadInConfig` is stored per-feature-type in `GCodeSettings` and can be
/// overridden per individual feature via `GCodeSettings.leadInOverrides`.
/// It is passed to `ToolpathPlanner.buildLeadIn()` to produce the approach
/// geometry that is prepended to the cut path.
///
/// Only the parameters relevant to the active `strategy` are used; the others
/// act as presets and are preserved so switching strategies doesn't discard
/// previously-tuned values.
struct LeadInConfig: Codable, Equatable {

    // -------------------------------------------------------------------------
    // MARK: Strategy
    // -------------------------------------------------------------------------

    var strategy: LeadInStrategy

    // -------------------------------------------------------------------------
    // MARK: Rotational Arc  (strategy == .rotationalArc)
    // -------------------------------------------------------------------------

    /// Linear distance equivalent of the A-axis sweep before the torch reaches
    /// the cut line, in mm. Converted to degrees at runtime using the tube
    /// circumference. Longer values give a wider purge window and a more gradual
    /// speed ramp, at the cost of more scrap material consumed.
    ///
    /// _Typical range:_ 5–15 mm. Default: 8 mm.
    var rotationalSweepMm: Double = 8.0
    
    /// NEW: X-axis distance to push the lead-in start point into the scrap zone.
    /// This turns the pure rotational sweep into a helical sweep, preventing
    /// collisions with protruding features (like hooks) on the kept part.
    ///
    /// _Typical range:_ 0–10 mm. Default: 3 mm.
    var scrapClearanceXMm: Double = 3.0

    // -------------------------------------------------------------------------
    // MARK: Tangent Arc  (strategy == .tangentArc)
    // -------------------------------------------------------------------------

    /// Radius of the circular arc approach, in mm. Must be small enough that
    /// the arc fits inside the feature (internal cuts) or outside the stock
    /// boundary (external). Values larger than half the feature's smallest
    /// dimension will be clamped at runtime.
    ///
    /// _Typical range:_ 3–8 mm. Default: 5 mm.
    var arcRadius: Double = 5.0

    /// Angle subtended by the arc, in degrees. 90° produces a true tangent
    /// entry (the straight approach segment arrives perpendicular to the cut
    /// tangent). Larger values increase the angular sweep; 180° would reverse
    /// approach direction at the start of the arc.
    ///
    /// _Typical range:_ 45°–135°. Default: 90°.
    var arcAngleDeg: Double = 90.0

    /// Length of the straight segment prepended before the arc begins, in mm.
    /// Gives the torch time to stabilise at cut height and reach full feed rate
    /// before the curved section starts.
    ///
    /// _Typical range:_ 2–6 mm. Default: 3 mm.
    var approachLength: Double = 3.0

    // -------------------------------------------------------------------------
    // MARK: Linear  (strategy == .linear)
    // -------------------------------------------------------------------------

    /// Total length of the straight approach line, in mm.
    ///
    /// _Typical range:_ 3–10 mm. Default: 5 mm.
    var linearLength: Double = 5.0

    /// Angle of the approach line relative to the cut-path tangent at the
    /// pierce point, in degrees.
    ///
    /// - 0°  → straight along the tangent (cuts into the path head-on)
    /// - 90° → perpendicular to the cut direction (maximum dwell avoidance)
    ///
    /// Values of 30°–60° are typical for clean angled entry without wasting
    /// too much approach length fighting the perpendicular component.
    ///
    /// _Typical range:_ 20°–70°. Default: 45°.
    var linearAngleDeg: Double = 45.0

    // -------------------------------------------------------------------------
    // MARK: Center Pierce  (strategy == .centerPierce)
    // -------------------------------------------------------------------------

    /// Number of interpolated points along the straight line from the feature
    /// centroid to the cut path. More steps produce a smoother velocity
    /// ramp-up in the profiler and finer kerf-angle interpolation.
    ///
    /// _Typical range:_ 3–8. Default: 4.
    var centerPierceSteps: Int = 4

    // -------------------------------------------------------------------------
    // MARK: Spiral  (strategy == .spiral)
    // -------------------------------------------------------------------------

    /// Number of complete turns in the Archimedean spiral from centroid to cut
    /// path. Fractional values are allowed. More turns spread the approach
    /// velocity ramp over a longer arc, but increase the time spent in the
    /// waste area before reaching the cut line.
    ///
    /// _Typical range:_ 0.5–1.5. Default: 0.75 (270° sweep).
    var spiralTurns: Double = 0.75

    /// Number of interpolated points along the spiral. More points produce a
    /// smoother arc at the cost of slightly longer G-code output.
    ///
    /// _Typical range:_ 16–48. Default: 24.
    var spiralSteps: Int = 24

    // -------------------------------------------------------------------------
    // MARK: Static Defaults
    // -------------------------------------------------------------------------

    /// Default lead-in for `startCut` and `endCut` features.
    ///
    /// Uses a rotational arc so the torch sweeps around the tube before
    /// crossing the cut line — no X movement, no witness mark on the sever face.
    static let defaultSeverCut = LeadInConfig(strategy: .rotationalArc)

    /// Default lead-in for `hole` features above the small-hole threshold.
    ///
    /// A tangent arc provides a clean, dwell-free entry for larger holes where
    /// the arc radius fits comfortably inside the feature boundary.
    static let defaultHole = LeadInConfig(strategy: .tangentArc)

    /// Default lead-in for `hole` features *below* `GCodeSettings.smallHoleDiameterThreshold`.
    ///
    /// Center pierce keeps the blowout mark safely inside the waste area when
    /// there is not enough room for a tangent arc.
    static let defaultSmallHole = LeadInConfig(strategy: .centerPierce)

    /// Default lead-in for `cutout` features.
    ///
    /// Tangent arc, same rationale as `defaultHole`.
    static let defaultCutout = LeadInConfig(strategy: .tangentArc)

    /// Default lead-in for `notch` features.
    ///
    /// A straight angled approach fits into the typically-tighter geometry of
    /// a notch cut where a full tangent arc often cannot be inscribed.
    static let defaultNotch = LeadInConfig(strategy: .linear)
}

// MARK: - Lead-Out Strategy

/// The geometric path the torch takes when leaving a cut.
///
/// A lead-out (sometimes called "overburn") extends the torch path past the
/// nominal exit/closure point to ensure the kerf closes cleanly and no step
/// or notch is left at the torch-off position.
enum LeadOutStrategy: String, Codable, CaseIterable, Identifiable {

    /// **Linear** — continue in the exit-tangent direction for a set distance.
    ///
    /// The torch stays on the same heading as the last cut segment. An optional
    /// angle offset lets you veer slightly into or away from the part boundary.
    ///
    /// _Best for:_ holes, cutouts, notches, general overburn.
    case linear

    /// **Rotational arc** — A-axis-only sweep past the cut exit; no X movement.
    ///
    /// Equivalent to the rotational-arc lead-in used on sever cuts. Keeps the
    /// torch off the stock face while it ramps down, leaving no X-axis witness
    /// mark on the sever face.
    ///
    /// _Best for:_ startCut / endCut sever cuts.
    case rotationalArc

    /// **None** — torch cuts exactly to the exit point and stops.
    ///
    /// No overburn is applied. Acceptable only when the feature is very small
    /// or when the controller handles the arc-off delay in hardware.
    case none

    // MARK: Display

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linear:        return "Linear"
        case .rotationalArc: return "Rotational arc"
        case .none:          return "None (exact stop)"
        }
    }

    var shortDescription: String {
        switch self {
        case .linear:
            return "Extend in exit direction. Universal overburn for clean kerf closure."
        case .rotationalArc:
            return "A-axis sweep only past cut exit. No X movement. Use for sever cuts."
        case .none:
            return "Stop at exit point. No overburn — accepts visible torch-off mark."
        }
    }
}

// MARK: - Lead-Out Configuration

/// All parameters that control lead-out (overburn) geometry for one feature or feature type.
///
/// `LeadOutConfig` is stored per-feature-type in `GCodeSettings` (alongside `LeadInConfig`)
/// and can be overridden per individual feature via `GCodeSettings.leadOutOverrides`.
/// It is passed to `ToolpathPlanner.buildLeadOut()` which appends the exit geometry
/// to the cut path as a separate `leadOutPoints` array in `PlannedPath`.
struct LeadOutConfig: Codable, Equatable {

    var strategy: LeadOutStrategy

    // -------------------------------------------------------------------------
    // MARK: Linear  (strategy == .linear)
    // -------------------------------------------------------------------------

    /// Distance to extend past the exit point in mm. This is the "overburn"
    /// distance — the amount by which the plasma arc sweeps past the nominal
    /// closure or sever line. Larger values give a cleaner closure at the cost
    /// of slightly more heat near the start/closure point.
    ///
    /// _Typical range:_ 1–8 mm. Default: 3 mm.
    var extensionMm: Double = 3.0

    /// Angle of the exit line relative to the cut-path exit tangent, in degrees.
    ///
    /// - 0°  → continue straight in the exit direction (standard overburn)
    /// - +ve → veer towards the interior (away from kerf edge)
    /// - -ve → veer towards the exterior
    ///
    /// _Typical range:_ -20°–20°. Default: 0° (straight extension).
    var extensionAngleDeg: Double = 0.0

    // -------------------------------------------------------------------------
    // MARK: Rotational Arc  (strategy == .rotationalArc)
    // -------------------------------------------------------------------------

    /// Linear distance equivalent of the A-axis sweep past the exit point, in mm.
    /// Converted to degrees at runtime using the tube circumference. Larger values
    /// provide more margin for the torch to ramp down before leaving the kerf.
    ///
    /// _Typical range:_ 3–12 mm. Default: 5 mm.
    var rotationalSweepMm: Double = 5.0
    
    /// NEW: X-axis distance to push the lead-in start point into the scrap zone.
    /// This turns the pure rotational sweep into a helical sweep, preventing
    /// collisions with protruding features (like hooks) on the kept part.
    ///
    /// _Typical range:_ 0–10 mm. Default: 3 mm.
    var scrapClearanceXMm: Double = 3.0

    // -------------------------------------------------------------------------
    // MARK: Static Defaults
    // -------------------------------------------------------------------------

    /// Default lead-out for `startCut` and `endCut` sever cuts.
    ///
    /// Rotational arc keeps the exit motion off the sever face — no X-axis
    /// witness mark as the torch ramps down.
    static let defaultSeverCut = LeadOutConfig(strategy: .rotationalArc)

    /// Default lead-out for `hole` features.
    ///
    /// Linear extension of 3 mm closes the kerf loop cleanly.
    static let defaultHole = LeadOutConfig(strategy: .linear)

    /// Default lead-out for `cutout` features.
    static let defaultCutout = LeadOutConfig(strategy: .linear)

    /// Default lead-out for `notch` features.
    static let defaultNotch = LeadOutConfig(strategy: .linear)
}
