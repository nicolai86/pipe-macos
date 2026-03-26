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
