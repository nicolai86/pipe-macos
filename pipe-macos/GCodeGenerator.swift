import Foundation
import SceneKit

// MARK: - Pack Entry

/// One piece within a multi-part pack layout.
struct PackEntry {
    let shape: SelectedShape
    /// X coordinate of the piece's low-X end in pack space (mm).
    let packStartX: CGFloat
    /// Degrees to add to all A angles so that A=0 aligns with the roll-corrected "up" face.
    let rollOffset: CGFloat
    /// X coordinate of the piece's high-X end in pack space (mm).
    var packEndX: CGFloat { packStartX + (shape.stockInfo?.length ?? 0) }
}

// MARK: - Global Feature (Thermal Hedging)

/// A surface feature resolved into pack (global) coordinates, used by the thermal-hedging sequencer.
struct GlobalFeature {
    let feature: SurfaceFeature
    let stock: StockInfo
    /// X offset of the owning piece's low-X end in pack space (mm).
    let packStartX: CGFloat
    /// X offset of the owning piece's high-X end in pack space (mm).
    let packEndX: CGFloat
    /// A-axis roll offset applied to the owning piece (degrees).
    let rollOffset: CGFloat
    /// Zero-based index of the owning piece within the pack.
    let pieceIndex: Int

    /// Feature center X in pack (global) coordinates (mm).
    var globalX: CGFloat { packStartX + feature.xCenter }
    /// Feature center A in pack (global) coordinates (degrees).
    var globalA: CGFloat { feature.aCenterDeg + rollOffset }
}

// MARK: - Unit Mode

/// Output unit system for generated G-code.
///
/// - `.metric`:  G21 — all linear coordinates in millimetres, feed rates in mm/min.
/// - `.inches`:  G20 — all linear coordinates in inches, feed rates in in/min.
///
/// The A axis is always in degrees regardless of unit mode.
enum GCodeUnit: String, CaseIterable {
    case metric = "mm"
    case inches = "in"
}

// MARK: - GCode Generation Settings

/// All tunable parameters for G-code post-processing.
///
/// Default values target a mid-range rotary plasma setup (Hypertherm Powermax 65/85,
/// NEMA 23 stepper-driven chuck, ~1.5m max tube length).  Adjust per machine and
/// consumable chart before cutting.
struct GCodeSettings {

    // -------------------------------------------------------------------------
    // MARK: Feed Rates
    // -------------------------------------------------------------------------

    /// Plasma cutting feed rate (mm/min).
    ///
    /// Set from the Hypertherm cut chart for your amperage, gas type, and material
    /// thickness.  Too fast → incomplete cut / dross on underside.  Too slow →
    /// excessive heat, warping, and top-side dross.
    ///
    /// Typical range: 500–5000 mm/min.
    /// - 6mm mild steel / 65 A: ~2500 mm/min
    /// - 6mm mild steel / 45 A: ~1500 mm/min
    /// - 3mm mild steel / 45 A: ~4000 mm/min
    var feedRate: CGFloat = 1000.0

    /// Rapid-traverse (non-cutting) feed rate (mm/min).
    ///
    /// Caps all G0 / repositioning moves.  Should be set to the machine's maximum
    /// safe traverse speed; going higher risks missed steps on stepper-driven axes.
    ///
    /// Typical range: 2000–10 000 mm/min.
    var rapidRate: CGFloat = 3000.0

    // -------------------------------------------------------------------------
    // MARK: Z-Axis Clearance
    // -------------------------------------------------------------------------

    /// Baseline safe Z height above the tube surface used for rapid repositioning (mm).
    ///
    /// The torch retracts to this height before every inter-feature rapid move.
    /// `enableDynamicSafeZ` augments this value for rectangular stock where the
    /// circumscribed radius exceeds the flat-face half-height.
    ///
    /// Typical range: 15–50 mm.  Values below 10 mm risk collision on A-axis
    /// rotation rapids between features.
    var safeHeight: CGFloat = 25.0

    /// When `true`, dynamically increases safe Z for rectangular HSS to clear the
    /// tube's corner radius during A-axis repositioning rapids.
    ///
    /// Disable only if your CAM workflow guarantees the A axis never rotates during
    /// a rapid with the torch lowered, or for round stock where it has no effect.
    var enableDynamicSafeZ: Bool = true

    // -------------------------------------------------------------------------
    // MARK: Pierce & Cut Heights
    // -------------------------------------------------------------------------

    /// Torch standoff distance above the tube surface during the pierce phase (mm).
    ///
    /// A higher pierce height reduces dross ejected onto the nozzle and extends
    /// consumable life, at the cost of a slightly larger pierce hole.  Values come
    /// directly from the plasma unit's cut chart.
    ///
    /// Typical range: 3.0–6.4 mm (Hypertherm Powermax 65/85 charts).
    /// - 6 mm mild steel / 65 A: 3.8 mm
    /// - 3 mm mild steel / 45 A: 3.2 mm
    var pierceHeight: CGFloat = 3.8

    /// Torch standoff distance above the tube surface during steady-state cutting (mm).
    ///
    /// Directly controls arc voltage and therefore cut quality.  Lower than
    /// recommended → top-side dross and shortened consumable life.  Higher →
    /// underside bevel and incomplete fusion on thick material.
    ///
    /// Typical range: 1.5–4.8 mm (Hypertherm Powermax charts).
    /// - 6 mm mild steel / 65 A: 3.2 mm
    /// - 3 mm mild steel / 45 A: 2.4 mm
    var cutHeight: CGFloat = 3.2

    // -------------------------------------------------------------------------
    // MARK: Kerf Compensation
    // -------------------------------------------------------------------------

    /// Full kerf width of the plasma arc (mm).
    ///
    /// The cut path is offset by half this value (kerfWidth / 2) to compensate for
    /// material removed by the arc.  Measure empirically for your consumable and
    /// material: make a calibration cut, measure the slot width with calipers.
    ///
    /// Typical range: 1.0–3.5 mm.
    /// - Hypertherm 65 A fine-cut consumables on 3 mm steel: ~1.5 mm
    /// - Hypertherm 65 A standard consumables on 6 mm steel: ~2.0–2.5 mm
    var kerfWidth: CGFloat = 2.0

    /// When `true`, applies kerf offset to the toolpath offline (geometric bisector
    /// method in the X–A plane) instead of relying on controller G41/G42.
    ///
    /// Leave `true` for all standard use.  Disable only when post-processing for a
    /// controller that applies its own G41/G42 and cannot accept a pre-offset path.
    var enableKerfComp: Bool = true

    // -------------------------------------------------------------------------
    // MARK: Nonlinear Error Compensation
    // -------------------------------------------------------------------------

    /// When `true`, inserts additional intermediate machine points wherever the
    /// linearised chord between two points deviates from the true tube surface by
    /// more than `nonlinearErrorTolerance`.
    ///
    /// Increases point count (and file size) on tight-radius features but is
    /// essential for accurate cuts on small-OD tube.  Disable only to reduce file
    /// size for very large packs with simple sever cuts.
    var enableNonlinearErrorCompensation: Bool = true

    /// Maximum allowable deviation of the linear chord from the true tube surface
    /// before an intermediate point is inserted (mm).
    ///
    /// Lower values produce smoother cuts and more G-code points.
    ///
    /// Typical range: 0.01–0.20 mm.
    /// - Precision structural: 0.03–0.05 mm
    /// - General fabrication: 0.10 mm
    /// - Rough/structural cuts only: 0.20 mm
    ///
    /// Values below 0.01 mm approach floating-point noise and are not meaningful.
    var nonlinearErrorTolerance: CGFloat = 0.05

    // -------------------------------------------------------------------------
    // MARK: Singularity Damping (Damped Jacobian)
    // -------------------------------------------------------------------------

    /// When `true`, applies a Damped Least Squares filter to A-axis motion at
    /// points where the tube surface normal changes rapidly (e.g., HSS corners).
    ///
    /// Prevents the A axis from being commanded to accelerate beyond its physical
    /// limits at corner transitions on rectangular stock.  Has no practical effect
    /// on round tube where the normal rotates smoothly.
    var enableSingularityDamping: Bool = true

    /// λ (lambda) damping factor for the Damped Least Squares A-axis filter.
    ///
    /// Controls the trade-off between torch-tilt accuracy and A-axis smoothness at
    /// corners.  Higher values damp more aggressively: the torch tilts less
    /// accurately through the corner but the A-axis motion is smoother and more
    /// achievable by the motor.
    ///
    /// Formula: dampingRatio = ds² / (ds² + λ²).  At λ=0 the filter is off
    /// (identical to `enableSingularityDamping = false`).
    ///
    /// Typical range: 0.5–5.0.
    /// - Light damping (fast corner transitions): 0.5–1.0
    /// - Balanced (recommended for most machines): 2.0
    /// - Heavy damping (slow/stiff A-axis drives): 3.0–5.0
    var singularityDampingFactor: CGFloat = 2.0

    // -------------------------------------------------------------------------
    // MARK: Lead-In Geometry
    // -------------------------------------------------------------------------

    /// Length of the straight entry segment that precedes the arc portion of the
    /// lead-in (mm).
    ///
    /// The torch pierces at the far end of this segment and travels along it before
    /// entering the arc.  Placing the pierce point away from the cut contour
    /// prevents pierce-hole dross from ending up on the finished part edge.
    ///
    /// Typical range: 3–15 mm.  Values below 2 mm may not give the arc enough room.
    /// Large values waste material on internal features with tight clearance.
    var leadInDistance: CGFloat = 5.0

    /// Angular sweep of the tangential arc lead-in (degrees).
    ///
    /// The arc blends the straight entry segment into the cut contour tangentially.
    /// 90° produces a quarter-circle arc.  Values below ~30° produce an arc too
    /// short to be useful; values above 180° risk the arc re-entering already-cut
    /// material on small internal features.
    ///
    /// Typical range: 45–135°.
    /// - Recommended for internal holes: 90°
    /// - Recommended for sever cuts: 60–90°
    var leadInAngle: CGFloat = 90.0

    /// Radius of the tangential arc lead-in (mm).
    ///
    /// Smaller radius = tighter arc = less clearance needed inside the feature.
    /// The arc must fit within the scrap-side material; on small holes, keep this
    /// below ~30% of the hole radius.
    ///
    /// Typical range: 2–8 mm.
    var leadInAngleDistance: CGFloat = 3.0

    // -------------------------------------------------------------------------
    // MARK: Overburn
    // -------------------------------------------------------------------------

    /// Angular distance the torch travels tangentially past the start/end of the
    /// cut before torch-off (degrees of tube rotation).
    ///
    /// Overburn ensures the cut fully closes without a "notch" at the torch-off
    /// point.  Too little → visible step/notch at closure.  Too much → scoring the
    /// already-cut edge and unnecessary heat input.
    ///
    /// Typical range: 5–20°.
    /// - Thin wall (≤3 mm): 5–8°
    /// - Standard wall (4–6 mm): 8–12°
    /// - Heavy wall (>6 mm): 12–20°
    var overburnDegrees: CGFloat = 10.0

    // -------------------------------------------------------------------------
    // MARK: Controller Mode
    // -------------------------------------------------------------------------

    /// When `true`, generates SimCNC-compatible G94 "4D spoofed" feed rates.
    ///
    /// SimCNC interprets the F-word as a rate over the total Euclidean 4D machine
    /// distance (√(ΔX²+ΔY²+ΔZ²+ΔA²)) rather than the 3D linear distance.  This
    /// preserves the intended execution time for each segment across all four axes.
    ///
    /// Set `false` for standard Fanuc/LinuxCNC/Mach4 controllers, which interpret
    /// F as the XYZ linear feed rate.
    var useSimCNC: Bool = true

    /// When `true`, injects M220 (THC OFF / corner lock) and M221 (THC ON) codes
    /// at transitions between corner and flat regions of rectangular HSS.
    ///
    /// Prevents the Torch Height Controller from chasing the rapidly changing arc
    /// voltage through HSS corner transitions, which would cause the torch to
    /// incorrectly plunge or retract.  Has no effect on round tube (no corners).
    ///
    /// Requires a THC that supports M220/M221 (Mach4 with THC plugin, SimCNC THC,
    /// Mesa THCAD-compatible setups).  Disable for THC systems that use a different
    /// corner-lock protocol.
    var enableDynamicTHC: Bool = true

    // -------------------------------------------------------------------------
    // MARK: Unit Mode
    // -------------------------------------------------------------------------

    /// Output unit system for the generated G-code program.
    ///
    /// `.metric` (default) emits `G21` and outputs all linear values in mm / mm·min⁻¹.
    /// `.inches` emits `G20` and outputs all linear values in inches / in·min⁻¹.
    ///
    /// All settings (feedRate, safeHeight, kerfWidth, etc.) are **always entered in mm**
    /// regardless of this selection; the generator converts automatically on output.
    var units: GCodeUnit = .metric

    // -------------------------------------------------------------------------
    // MARK: Per-Axis Acceleration Limits
    // -------------------------------------------------------------------------

    /// Maximum acceleration of the X axis (tube axial / linear) (mm/s²).
    ///
    /// Used by the velocity profiler to compute junction speeds and acceleration
    /// ramps.  Must match the value configured in the machine controller (Mach4
    /// motor tuning / LinuxCNC INI `MAX_ACCELERATION`).  Setting too high produces
    /// motor stalls or missed steps; too low leaves feed rate potential unused.
    ///
    /// Typical range: 200–2000 mm/s² (stepper) / 500–5000 mm/s² (servo).
    var maxAccelX: CGFloat = 500.0

    /// Maximum acceleration of the Y axis (torch lateral) (mm/s²).
    ///
    /// Same constraints as `maxAccelX`.  The Y axis is rarely used in rotary
    /// cutting (torch is centred over the tube axis) but is included for lead-in
    /// arc moves.
    ///
    /// Typical range: 200–2000 mm/s².
    var maxAccelY: CGFloat = 500.0

    /// Maximum acceleration of the Z axis (torch height) (mm/s²).
    ///
    /// The Z axis moves only during rapids, pierce descents, and retract sequences.
    /// It does not move during steady-state cutting on round stock; on rectangular
    /// stock it tracks the surface normal height variation.
    ///
    /// Typical range: 100–500 mm/s² (rack-and-pinion Z) / 200–1000 mm/s² (ball-screw Z).
    var maxAccelZ: CGFloat = 300.0

    /// Maximum acceleration of the A axis (tube rotation) (degrees/s²).
    ///
    /// The A axis is typically a stepper-driven chuck or roller system with
    /// significant inertia from the tube.  Values that are too high cause stepper
    /// stalls or tube slippage in roller chucks.  Values that are too low reduce
    /// attainable cut speed on round tube (the A axis is the primary cutting axis
    /// for sever cuts).
    ///
    /// Typical range: 200–2000 °/s² (stepper chuck) / 500–5000 °/s² (servo chuck).
    /// Note: 1000 °/s² ≈ 2.8 rev/s² — verify this is achievable with your chuck
    /// inertia and driver current settings before using values above 1500 °/s².
    var maxAccelA: CGFloat = 1000.0

    // -------------------------------------------------------------------------
    // MARK: Thermal Hedging (Feature Sequencing)
    // -------------------------------------------------------------------------

    /// When `true`, reorders features to spread heat across the tube before
    /// executing sever cuts.
    ///
    /// Internal features (holes, notches, cutouts) are sequenced first using a
    /// nearest-neighbour traversal weighted by `thermalHedgingWeightX` and
    /// `thermalHedgingWeightA`.  Sever cuts follow in right-to-left X order so
    /// that cut-off sections fall away from work already in progress.
    ///
    /// Disable to use simple priority-based sequencing (endCut → internals →
    /// startCut, right-to-left within each group), which produces shorter programs
    /// but may concentrate heat at one end of the tube.
    var enableThermalHedging: Bool = true

    /// Relative weight of axial (X) distance in the thermal-hedging nearest-
    /// neighbour cost function.
    ///
    /// The travel cost between two features is:
    ///   cost = √( (weightX·ΔX)² + (weightA·arcLen)² )
    ///
    /// Setting `thermalHedgingWeightX = 2.0` and `thermalHedgingWeightA = 1.0`
    /// makes the sequencer prefer features that are closer axially, useful when
    /// axial repositioning is slow relative to tube rotation.
    ///
    /// Typical range: 0.5–3.0.  Both weights at 1.0 gives equal cost per mm in
    /// each direction.
    var thermalHedgingWeightX: CGFloat = 1.0

    /// Relative weight of angular (A) arc-length distance in the thermal-hedging
    /// nearest-neighbour cost function.
    ///
    /// Increase above 1.0 to prefer features that require less tube rotation to
    /// reach (useful when the A axis is slow or the tube is heavy).  Decrease below
    /// 1.0 to prioritise axial clustering.
    ///
    /// Typical range: 0.5–3.0.
    var thermalHedgingWeightA: CGFloat = 1.0
}

// MARK: - Machine TCP Data Structure

/// A resolved 4-axis machine position for a single toolpath point.
///
/// Coordinates are in machine (controller) space:
/// - `Xm`: axial position along the tube (mm)
/// - `Ym`: torch lateral position, perpendicular to tube axis in the horizontal plane (mm)
/// - `Zm`: torch height above the tube surface baseline (mm, relative)
/// - `Am`: tube rotation angle (degrees, unbounded / continuous)
///
/// The `mat*` fields carry the intermediate material-space coordinates used by the
/// nonlinear error compensation and velocity profiler.
struct MachinePoint {
    /// Axial machine position (mm).  Maps directly to the G-code X word.
    var Xm: CGFloat
    /// Lateral machine position (mm).  Maps to the G-code Y word.
    var Ym: CGFloat
    /// Height machine position, relative to tube surface baseline (mm).
    /// Add `cutHeight` or `pierceHeight` when emitting G-code Z words.
    var Zm: CGFloat
    /// Tube rotation angle (degrees, continuous / unbounded).
    /// Maps to the G-code A word.
    var Am: CGFloat
    /// Material-space axial coordinate (same as Xm in current kinematics).
    var matX: CGFloat
    /// Material-space cross-section U coordinate (horizontal, perpendicular to tube axis) (mm).
    var matU: CGFloat
    /// Material-space cross-section V coordinate (vertical, perpendicular to tube axis) (mm).
    var matV: CGFloat
    /// `true` when the point lies on a corner region of rectangular HSS, used to
    /// gate THC corner-lock injection and singularity damping.
    var isCorner: Bool
}

// MARK: - Velocity Profiling Segment

/// Per-segment data produced by the velocity profiler.
///
/// One `TrajectorySegment` spans the move from `machinePoints[i]` to
/// `machinePoints[i+1]`.  All delta fields are signed differences (end minus start).
struct TrajectorySegment {
    /// Arc-length of this segment on the true tube surface (mm).
    /// Used as the canonical speed reference: surface speed = dS / dt.
    var dS: CGFloat
    /// Euclidean 4D machine distance √(ΔXm²+ΔYm²+ΔZm²+ΔAm²).
    /// Used to compute the SimCNC G94 spoofed feed rate F = dMachine / dt.
    var dMachine: CGFloat
    /// X-axis displacement for this segment (mm).
    var dXm: CGFloat
    /// Y-axis displacement for this segment (mm).
    var dYm: CGFloat
    /// Z-axis displacement for this segment (mm).
    var dZm: CGFloat
    /// A-axis displacement for this segment (degrees).
    var dAm: CGFloat
    /// Maximum allowable tangential acceleration along the surface path for this
    /// segment (mm/min²), derived from the most constrained individual axis.
    var aPath: CGFloat
    /// Final output feed rate for this segment (mm/min), written to the F word.
    /// Computed by the forward–backward velocity pass; 0.0 until profiling runs.
    var finalF: CGFloat = 0.0
}

// MARK: - GCode Generator
class GCodeGenerator {
    var settings = GCodeSettings()
    
    // MARK: - Single Part Generation
    func generateGCode(for stock: StockInfo, rollOffset: CGFloat = 0.0) -> String {
        var gcode: [String] = []
        gcode.append(contentsOf: generateHeader(stock: stock))
        gcode.append(contentsOf: generateStartupSequence(totalLength: stock.length, stock: stock))
        
        var currentA: CGFloat = 0
        
        if settings.enableThermalHedging {
            let radius = stock.profile == .round ? (stock.od ?? 50.0)/2.0 : max(stock.odX ?? 50.0, stock.odY ?? 50.0)/2.0
            let allFeatures = stock.features.map { GlobalFeature(feature: $0, stock: stock, packStartX: 0, packEndX: stock.length, rollOffset: rollOffset, pieceIndex: 0) }
            
            var internals = allFeatures.filter { $0.feature.type == .hole || $0.feature.type == .cutout || $0.feature.type == .notch }
            var severs = allFeatures.filter { $0.feature.type == .startCut || $0.feature.type == .endCut }
            
            internals = sequenceForThermalHedging(features: internals, radius: radius)
            // Execute severs right-to-left
            severs.sort { $0.globalX > $1.globalX }
            
            let finalSequence = internals + severs
            for gf in finalSequence {
                let (toolpath, finalA) = generateTCPToolpath(
                    feature: gf.feature, stock: gf.stock,
                    packStartX: gf.packStartX, packEndX: gf.packEndX,
                    rollOffset: gf.rollOffset, currentA: currentA, isPackMode: false
                )
                gcode.append(contentsOf: toolpath)
                gcode.append("")
                currentA = finalA
            }
        } else {
            let sortedFeatures = sortFeatures(stock.features)
            for feature in sortedFeatures {
                let (toolpath, finalA) = generateTCPToolpath(
                    feature: feature, stock: stock,
                    packStartX: 0, packEndX: stock.length,
                    rollOffset: rollOffset, currentA: currentA, isPackMode: false
                )
                gcode.append(contentsOf: toolpath)
                gcode.append("")
                currentA = finalA
            }
        }
        
        gcode.append(contentsOf: generateEndSequence(stock: stock))
        return gcode.joined(separator: "\n")
    }

    // MARK: - Pack G-code Generation
    func generatePackGCode(entries: [PackEntry]) -> String {
        guard !entries.isEmpty, let refStock = entries[0].shape.stockInfo else {
            return "; Empty pack — no G-code generated"
        }

        let totalLength = entries.max(by: { $0.packEndX < $1.packEndX })?.packEndX ?? 0
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy, HH:mm"

        let safeZ = settings.enableDynamicSafeZ ? getDynamicSafeZ(stock: refStock) : settings.safeHeight

        var lines: [String] = [
            "%",
            "(PACK G-CODE  —  \(entries.count) PIECE\(entries.count == 1 ? "" : "S"))",
            "(GENERATED: \(formatter.string(from: Date())))",
            refStock.profile == .round
                ? "(STOCK: \(refStock.profile.rawValue)  OD \(fmtU(refStock.od ?? 0))\(unitLabel))"
                : "(STOCK: \(refStock.profile.rawValue)  \(fmtU(refStock.odX ?? 0))×\(fmtU(refStock.odY ?? 0))\(unitLabel))",
            "(TOTAL STOCK LENGTH: \(fmtU(totalLength))\(unitLabel))",
            "",
            "\(unitModeWord)             ; \(unitModeComment)",
            "G90             ; absolute positioning",
            "G40             ; cancel cutter comp",
            "G49             ; cancel tool length offset",
            "G92 X\(fmtU(totalLength)) Y0 Z0 A0 ; set current position as right-most free end",
            "",
            "G0 Z\(fmtU(safeZ))     ; move to safe height",
            "M5              ; torch off (ensure)",
            "",
            "; === Cutting Pattern (free-end to chuck, \(entries.count) piece\(entries.count == 1 ? "" : "s")) ===",
        ]

        var currentA: CGFloat = 0

        if settings.enableThermalHedging {
            lines.append("; === Thermal Hedging Enabled: Global Cut Sequencing ===")
            var allFeatures: [GlobalFeature] = []
            
            for (idx, entry) in entries.enumerated() {
                guard let stock = entry.shape.stockInfo else { continue }
                for f in stock.features {
                    allFeatures.append(GlobalFeature(feature: f, stock: stock, packStartX: entry.packStartX, packEndX: entry.packEndX, rollOffset: entry.rollOffset, pieceIndex: idx))
                }
            }
            
            var internals = allFeatures.filter { $0.feature.type == .hole || $0.feature.type == .cutout || $0.feature.type == .notch }
            var severs = allFeatures.filter { $0.feature.type == .startCut || $0.feature.type == .endCut }
            
            let radius: CGFloat = refStock.profile == .round ? (refStock.od ?? 50.0)/2.0 : max(refStock.odX ?? 50.0, refStock.odY ?? 50.0)/2.0
            
            // Apply global greedy dispersion to internal features
            internals = sequenceForThermalHedging(features: internals, radius: radius)
            
            // Sever cuts MUST execute from the free end to the chuck (Highest X to Lowest X) to safely drop pieces
            severs.sort { $0.globalX > $1.globalX }
            
            let finalSequence = internals + severs
            
            for gf in finalSequence {
                lines.append("; ┌── Piece \(gf.pieceIndex + 1)/\(entries.count) | Feature: \(gf.feature.type.rawValue) at Global X=\(fmt(gf.globalX)) ──")
                let (toolpath, finalA) = generateTCPToolpath(
                    feature: gf.feature, stock: gf.stock,
                    packStartX: gf.packStartX, packEndX: gf.packEndX,
                    rollOffset: gf.rollOffset, currentA: currentA, isPackMode: true
                )
                lines += toolpath
                lines.append("")
                currentA = finalA
            }
            
        } else {
            let ordered = entries.sorted { $0.packStartX > $1.packStartX }
            for (pieceIdx, entry) in ordered.enumerated() {
                guard let stock = entry.shape.stockInfo else { continue }
                lines += [
                    "",
                    "; ┌── Piece \(pieceIdx + 1)/\(ordered.count)  "
                        + "X=\(fmt(entry.packStartX))–\(fmt(entry.packEndX))mm  "
                        + "L=\(fmt(stock.length))mm  "
                        + "\(stock.features.count) feature\(stock.features.count == 1 ? "" : "s") ──",
                ]

                let sortedFeatures = sortFeatures(stock.features)

                for feature in sortedFeatures {
                    let (toolpath, finalA) = generateTCPToolpath(
                        feature: feature, stock: stock,
                        packStartX: entry.packStartX, packEndX: entry.packEndX,
                        rollOffset: entry.rollOffset, currentA: currentA, isPackMode: true
                    )
                    lines += toolpath
                    lines.append("")
                    currentA = finalA
                }
            }
        }

        lines += generateEndSequence(stock: refStock)
        return lines.joined(separator: "\n")
    }
    
    // MARK: - Thermal Hedging Algorithm
    
    private func sequenceForThermalHedging(features: [GlobalFeature], radius: CGFloat) -> [GlobalFeature] {
        guard !features.isEmpty else { return [] }
        var remaining = features
        var sequenced: [GlobalFeature] = []
        
        // Start with the feature furthest to the right (+X) nearest the free end
        remaining.sort { $0.globalX > $1.globalX }
        var current = remaining.removeFirst()
        sequenced.append(current)
        
        while !remaining.isEmpty {
            // Find the feature furthest from the current feature to maximize heat distribution
            if let nextIdx = remaining.indices.max(by: { i, j in
                let distI = thermalDistance(current, remaining[i], radius: radius)
                let distJ = thermalDistance(current, remaining[j], radius: radius)
                return distI < distJ
            }) {
                current = remaining.remove(at: nextIdx)
                sequenced.append(current)
            }
        }
        return sequenced
    }

    private func thermalDistance(_ f1: GlobalFeature, _ f2: GlobalFeature, radius: CGFloat) -> CGFloat {
        let dx = (f1.globalX - f2.globalX) * settings.thermalHedgingWeightX
        
        // Calculate shortest angular path on the cylinder surface
        var da = abs(f1.globalA.truncatingRemainder(dividingBy: 360.0) - f2.globalA.truncatingRemainder(dividingBy: 360.0))
        if da > 180.0 { da = 360.0 - da }
        
        let arcLen = (da * .pi / 180.0 * radius) * settings.thermalHedgingWeightA
        
        return sqrt(dx*dx + arcLen*arcLen)
    }

    // MARK: - SOTA: Offline 2D Polyline Kerf Offset
    
    private func applyOfflineKerfOffset(to path: [ToolpathPoint], radius: CGFloat, isClosed: Bool, k: CGFloat) -> [ToolpathPoint] {
        guard path.count > 1, radius != 0 else { return path }
        
        // Convert A degrees to mm using conversion factor k
        let pts: [(x: CGFloat, y: CGFloat)] = path.map { ($0.x, $0.a * k) }
        var offsetPts: [(x: CGFloat, y: CGFloat)] = []
        
        for i in 0..<pts.count {
            let prevIdx = (i == 0) ? (isClosed ? pts.count - 2 : 0) : i - 1
            let nextIdx = (i == pts.count - 1) ? (isClosed ? 1 : pts.count - 1) : i + 1
            
            let pPrev = pts[prevIdx]
            let pCurr = pts[i]
            let pNext = pts[nextIdx]
            
            // In vector
            var vInX = pCurr.x - pPrev.x
            var vInY = pCurr.y - pPrev.y
            let lenIn = sqrt(vInX*vInX + vInY*vInY)
            if lenIn > 1e-6 { vInX /= lenIn; vInY /= lenIn }
            
            // Out vector
            var vOutX = pNext.x - pCurr.x
            var vOutY = pNext.y - pCurr.y
            let lenOut = sqrt(vOutX*vOutX + vOutY*vOutY)
            if lenOut > 1e-6 { vOutX /= lenOut; vOutY /= lenOut }
            
            // Failsafe for open endpoints to simulate continuity
            if !isClosed {
                if i == 0 { vInX = vOutX; vInY = vOutY }
                else if i == pts.count - 1 { vOutX = vInX; vOutY = vInY }
            }
            
            // 2D Normal Vectors pointing Left of the travel direction
            let nInX = -vInY, nInY = vInX
            let nOutX = -vOutY, nOutY = vOutX
            
            // Calculate strictly shifted coordinate parallel lines
            let p1x = pCurr.x + radius * nInX
            let p1y = pCurr.y + radius * nInY
            
            let p2x = pCurr.x + radius * nOutX
            let p2y = pCurr.y + radius * nOutY
            
            // Calculate mathematical intersection of the two shifted vectors
            let cross = vInX * vOutY - vInY * vOutX
            
            if abs(cross) < 1e-6 {
                // Segments are collinear; safe to drop the vertex straight down
                offsetPts.append((p1x, p1y))
            } else {
                // Standard geometric line intersection bisector
                let dx = p2x - p1x
                let dy = p2y - p1y
                let t = (dx * vOutY - dy * vOutX) / cross
                let ix = p1x + t * vInX
                let iy = p1y + t * vInY
                offsetPts.append((ix, iy))
            }
        }
        
        // Hard-clamp the closure to prevent micro-gaps
        if isClosed {
            offsetPts[offsetPts.count - 1] = offsetPts[0]
        }
        
        // Convert y coordinate back to degrees A
        return offsetPts.map { ToolpathPoint(x: $0.x, a: $0.y / k) }
    }

    // MARK: - State of the Art Offline TCP Generation
    
    private func generateTCPToolpath(
        feature: SurfaceFeature,
        stock: StockInfo,
        packStartX: CGFloat,
        packEndX: CGFloat,
        rollOffset: CGFloat,
        currentA: CGFloat,
        isPackMode: Bool
    ) -> ([String], CGFloat) {
        guard let localPath = feature.path, localPath.count > 1 else { return ([], currentA) }

        let packPath = localPath.map { ToolpathPoint(x: $0.x + packStartX, a: $0.a + rollOffset) }

        let rawPierceA = packPath[0].a
        let shift = round((currentA - rawPierceA) / 360.0) * 360.0
        var adjPath = packPath.map { ToolpathPoint(x: $0.x, a: $0.a + shift) }
        
        let OD: CGFloat = stock.profile == .round ? (stock.od ?? 50.0) : max(stock.odX ?? 50.0, stock.odY ?? 50.0)
        let k = (.pi * OD) / 360.0 // Conversion factor: degrees to mm surface distance

        var isInternal = false
        if feature.type == .hole || feature.type == .cutout || feature.type == .notch {
            isInternal = true
        }

        // ====================================================================
        // --- SOTA PIERCE POINT OPTIMIZATION (LONGEST SEGMENT) ---
        // ====================================================================
        
        if isInternal && adjPath.count > 2 {
            var maxLen: CGFloat = -1
            var bestIdx = 0
            
            for i in 0..<adjPath.count - 1 {
                let dx = adjPath[i+1].x - adjPath[i].x
                let da_mm = (adjPath[i+1].a - adjPath[i].a) * k
                let len = sqrt(dx*dx + da_mm*da_mm)
                if len > maxLen { maxLen = len; bestIdx = i }
            }
            
            let midX = (adjPath[bestIdx].x + adjPath[bestIdx+1].x) / 2.0
            let midA = (adjPath[bestIdx].a + adjPath[bestIdx+1].a) / 2.0
            let midPt = ToolpathPoint(x: midX, a: midA)
            
            var newPath: [ToolpathPoint] = [midPt]
            newPath.append(contentsOf: adjPath[(bestIdx+1)..<(adjPath.count - 1)])
            newPath.append(contentsOf: adjPath[0...bestIdx])
            newPath.append(midPt)
            
            var continuousPath = [newPath[0]]
            for i in 1..<newPath.count {
                var currA = newPath[i].a
                let prevA = continuousPath.last!.a
                while currA - prevA > 180.0 { currA -= 360.0 }
                while currA - prevA < -180.0 { currA += 360.0 }
                continuousPath.append(ToolpathPoint(x: newPath[i].x, a: currA))
            }
            adjPath = continuousPath
        } else if (feature.type == .startCut || feature.type == .endCut) && adjPath.count > 1 {
            // Sever Cuts: Retain snap-to-face-center logic
            var bestIdx = 0
            var minDiff = CGFloat.greatestFiniteMagnitude
            for (i, pt) in adjPath.enumerated() {
                let modA = abs(pt.a.truncatingRemainder(dividingBy: 90.0))
                let diff = min(modA, 90.0 - modA)
                if diff < minDiff { minDiff = diff; bestIdx = i }
            }
            
            if bestIdx > 0 {
                var corePath = adjPath
                if abs(corePath.last!.a - (corePath.first!.a + 360.0)) < 1.0 { corePath.removeLast() }
                
                let reordered = Array(corePath[bestIdx...]) + Array(corePath[..<bestIdx])
                var newPath: [ToolpathPoint] = [reordered[0]]
                for i in 1..<reordered.count {
                    var current_A = reordered[i].a
                    let prev_A = newPath.last!.a
                    while current_A - prev_A > 180.0 { current_A -= 360.0 }
                    while current_A - prev_A < -180.0 { current_A += 360.0 }
                    newPath.append(ToolpathPoint(x: reordered[i].x, a: current_A))
                }
                
                let firstPt = newPath.first!
                var closeA = firstPt.a
                let lastA = newPath.last!.a
                while closeA - lastA > 180.0 { closeA -= 360.0 }
                while closeA - lastA < -180.0 { closeA += 360.0 }
                newPath.append(ToolpathPoint(x: firstPt.x, a: closeA))
                adjPath = newPath
            }
        }

        var finalPath = adjPath
        
        // ====================================================================
        // --- CHIRALITY-AWARE PLASMA SWIRL ENGINE ---
        // ====================================================================
        
        var signedArea: CGFloat = 0
        for i in 0..<finalPath.count - 1 {
            let p_i = finalPath[i]
            let p_next = finalPath[i+1]
            signedArea += (p_i.x * (p_next.a * k) - p_next.x * (p_i.a * k))
        }

        // --- DYNAMIC SCRAP-SIDE MULTIPLIER ---
        var isScrapLeft = false

        if isInternal {
            // Internal cut: Force CW in machine space. Scrap is on the Right.
            if signedArea > 0 { finalPath.reverse() }
            isScrapLeft = false
        } else {
            // Sever Cuts: Force CCW in machine space. Scrap is on the Left.
            if feature.type == .startCut {
                if finalPath.last!.a < finalPath.first!.a { finalPath.reverse() }
                isScrapLeft = true
            } else if feature.type == .endCut {
                if finalPath.last!.a > finalPath.first!.a { finalPath.reverse() }
                isScrapLeft = true
            }
        }
        
        // ====================================================================
        // --- OFFLINE KERF COMPENSATION (CONTROLLER G41/G42 REPLACEMENT) ---
        // ====================================================================
        if settings.enableKerfComp {
            // If Scrap is on the Left (Sever), we shift the path entirely to the Right (positive normal).
            // If Scrap is on the Right (Internal), we shift the path entirely to the Left (negative normal).
            let kerfRadius = isScrapLeft ? (settings.kerfWidth / 2.0) : -(settings.kerfWidth / 2.0)
            finalPath = applyOfflineKerfOffset(to: finalPath, radius: kerfRadius, isClosed: isInternal, k: k)
        }

        // 3. TANGENTIAL Overburn (Lead-Out Fix)
        if finalPath.count > 2 {
            let overburnDist = settings.overburnDegrees * k
            let pLast = finalPath.last!
            let pPrev = finalPath[finalPath.count - 2]
            
            let dx = pLast.x - pPrev.x
            let da_mm = (pLast.a - pPrev.a) * k
            let len = sqrt(dx*dx + da_mm*da_mm)
            
            if len > 0.001 {
                let dirX = dx / len
                let dirA_mm = da_mm / len
                let obX = pLast.x + dirX * overburnDist
                let obA_mm = (pLast.a * k) + dirA_mm * overburnDist
                finalPath.append(ToolpathPoint(x: obX, a: obA_mm / k))
            }
        }

        // 4. Generate Geometric Scrap-Side Lead-In
        let p0 = finalPath[0]
        let p1 = finalPath.count > 1 ? finalPath[1] : ToolpathPoint(x: p0.x + 1, a: p0.a)
        
        let dx = p1.x - p0.x
        let da_mm = (p1.a - p0.a) * k
        let gamma = atan2(da_mm, dx) // Initial cut tangent direction
        
        let leadR = settings.leadInAngleDistance
        let leadTheta = settings.leadInAngle * .pi / 180.0
        
        let leadL = settings.leadInDistance
        
        // Dynamically invert the tangent logic based on true scrap location
        let sideMultiplier: CGFloat = isScrapLeft ? 1.0 : -1.0
        
        var leadInPoints: [ToolpathPoint] = []
        
        if leadTheta > 0.01 && leadR > 0.01 {
            // Center of arc is guaranteed to be in the Scrap Zone
            let Cx = p0.x + leadR * cos(gamma + sideMultiplier * .pi / 2.0)
            let Cy = (p0.a * k) + leadR * sin(gamma + sideMultiplier * .pi / 2.0)
            
            let arrivalAngle = gamma - sideMultiplier * .pi / 2.0
            let startAngle = arrivalAngle - sideMultiplier * leadTheta
            
            let arcSteps = max(4, Int(leadTheta * 180 / .pi / 15)) // Dynamic segmenting
            for i in 0..<arcSteps {
                let t = startAngle + sideMultiplier * (leadTheta * CGFloat(i) / CGFloat(arcSteps))
                let x_arc = Cx + leadR * cos(t)
                let y_arc = Cy + leadR * sin(t)
                leadInPoints.append(ToolpathPoint(x: x_arc, a: y_arc / k))
            }
        }
        
        // Straight extension backing out of the tangent arc start
        let firstArcPt = leadInPoints.first ?? p0
        let entryTangent = gamma - sideMultiplier * leadTheta
        let pierceX = firstArcPt.x - leadL * cos(entryTangent)
        let pierceY = (firstArcPt.a * k) - leadL * sin(entryTangent)
        
        leadInPoints.insert(ToolpathPoint(x: pierceX, a: pierceY / k), at: 0)
        finalPath.insert(contentsOf: leadInPoints, at: 0)


        // ====================================================================
        // --- MACHINE POINT HELPER ---
        // ====================================================================
        func getWrappedMachinePoint(pt: ToolpathPoint, refAm: CGFloat?) -> MachinePoint {
            var mp = convertToMachine(pt: pt, stock: stock)
            if let prev = refAm {
                while mp.Am - prev > 180.0 { mp.Am -= 360.0 }
                while mp.Am - prev < -180.0 { mp.Am += 360.0 }
            } else if isPackMode {
                while mp.Am - currentA > 180.0 { mp.Am -= 360.0 }
                while mp.Am - currentA < -180.0 { mp.Am += 360.0 }
            }
            return mp
        }

        // ====================================================================
        // --- 1. SOTA: RAW MACHINE PATH GENERATION ---
        // ====================================================================
        var rawMachinePoints: [MachinePoint] = []
        var prevAmRaw: CGFloat? = nil

        for pt in finalPath {
            let mp = getWrappedMachinePoint(pt: pt, refAm: prevAmRaw)
            prevAmRaw = mp.Am
            rawMachinePoints.append(mp)
        }

        // ====================================================================
        // --- 2. SOTA: DAMPED JACOBIAN PSEUDOINVERSE (SINGULARITY AVOIDANCE) ---
        // ====================================================================
        var dampedMachinePoints: [MachinePoint] = []
        if !rawMachinePoints.isEmpty {
            dampedMachinePoints.append(rawMachinePoints[0])
            
            for i in 1..<rawMachinePoints.count {
                let prevDamped = dampedMachinePoints.last!
                let currRaw = rawMachinePoints[i]
                
                if settings.enableSingularityDamping {
                    // 1. Calculate Cartesian surface displacement (independent of rotation)
                    let dx = currRaw.matX - prevDamped.matX
                    let du = currRaw.matU - prevDamped.matU
                    let dv = currRaw.matV - prevDamped.matV
                    let ds_cartesian = sqrt(dx*dx + du*du + dv*dv)
                    
                    // 2. Calculate the difference between the target normal and our current physical angle
                    let target_dA = currRaw.Am - prevDamped.Am
                    
                    // 3. Apply the Damped Least Squares ratio
                    let lambdaSq = settings.singularityDampingFactor * settings.singularityDampingFactor
                    let dampingRatio = (ds_cartesian * ds_cartesian) / ((ds_cartesian * ds_cartesian) + lambdaSq)
                    
                    let damped_dA = target_dA * dampingRatio
                    let newAm = prevDamped.Am + damped_dA
                    
                    // 4. Recalculate Ym and Zm to ensure the physical torch tip stays perfectly on the cut line
                    let thetaRad = newAm * .pi / 180.0
                    let newYm = currRaw.matU * cos(thetaRad) - currRaw.matV * sin(thetaRad)
                    let newZm = currRaw.matU * sin(thetaRad) + currRaw.matV * cos(thetaRad)
                    
                    let baselineZ: CGFloat = (stock.profile == .round) ? (stock.od ?? 50.0)/2.0 : (stock.odY ?? stock.od ?? 50.0)/2.0
                    let relativeZm = newZm - baselineZ
                    
                    var dampedPt = currRaw
                    dampedPt.Am = newAm
                    dampedPt.Ym = newYm
                    dampedPt.Zm = relativeZm
                    
                    dampedMachinePoints.append(dampedPt)
                } else {
                    dampedMachinePoints.append(currRaw)
                }
            }
        }

        // ====================================================================
        // --- 3. SOTA: DUAL-CHORD NONLINEAR ERROR COMPENSATION ---
        // ====================================================================
        var machinePoints: [MachinePoint] = []
        
        if !dampedMachinePoints.isEmpty {
            machinePoints.append(dampedMachinePoints[0])
            
            for i in 1..<dampedMachinePoints.count {
                let startMp = machinePoints.last!
                let endMp = dampedMachinePoints[i]
                
                func appendWithCompensation(sMp: MachinePoint, eMp: MachinePoint, depth: Int = 0) {
                    if settings.enableNonlinearErrorCompensation && depth < 10 {
                        // 1. True kinematic midpoint on the DAMPED path
                        let midU = (sMp.matU + eMp.matU) / 2.0
                        let midV = (sMp.matV + eMp.matV) / 2.0
                        let midAm = (sMp.Am + eMp.Am) / 2.0
                        
                        let thetaRad = midAm * .pi / 180.0
                        let trueMidYm = midU * cos(thetaRad) - midV * sin(thetaRad)
                        
                        let baselineZ: CGFloat = (stock.profile == .round) ? (stock.od ?? 50.0)/2.0 : (stock.odY ?? stock.od ?? 50.0)/2.0
                        let trueMidZm = (midU * sin(thetaRad) + midV * cos(thetaRad)) - baselineZ
                        
                        // 2. Linear interpolation midpoint (how the controller moves physically)
                        let linMidY = (sMp.Ym + eMp.Ym) / 2.0
                        let linMidZ = (sMp.Zm + eMp.Zm) / 2.0
                        
                        // 3. Calculate deviation strictly in the non-linear axes
                        let dy = trueMidYm - linMidY
                        let dz = trueMidZm - linMidZ
                        let deviation = sqrt(dy*dy + dz*dz)
                        
                        // 4. Bisect if physical chord error exceeds tolerance
                        if deviation > settings.nonlinearErrorTolerance {
                            var midPt = eMp
                            midPt.matX = (sMp.matX + eMp.matX) / 2.0
                            midPt.matU = midU
                            midPt.matV = midV
                            midPt.Am = midAm
                            midPt.Ym = trueMidYm
                            midPt.Zm = trueMidZm
                            midPt.Xm = (sMp.Xm + eMp.Xm) / 2.0
                            
                            appendWithCompensation(sMp: sMp, eMp: midPt, depth: depth + 1)
                            appendWithCompensation(sMp: midPt, eMp: eMp, depth: depth + 1)
                            return
                        }
                    }
                    machinePoints.append(eMp)
                }
                
                appendWithCompensation(sMp: startMp, eMp: endMp)
            }
        }


        // ====================================================================
        // --- 4. SOTA: NON-LINEAR KINEMATIC JACOBIAN VELOCITY PROFILING ---
        // ====================================================================
        
        var segments: [TrajectorySegment] = []
        
        // Convert acceleration limits to mm/min^2 (and deg/min^2) for G94 compatibility
        let aMaxX = settings.maxAccelX * 3600.0
        let aMaxY = settings.maxAccelY * 3600.0
        let aMaxZ = settings.maxAccelZ * 3600.0
        let aMaxA = settings.maxAccelA * 3600.0
        
        // 1. Calculate Raw Segment Distances & Tangential Acceleration Limits
        for i in 1..<machinePoints.count {
            let prev = machinePoints[i-1]
            let curr = machinePoints[i]

            let dx = curr.matX - prev.matX
            let du = curr.matU - prev.matU
            let dv = curr.matV - prev.matV
            let dS = max(1e-6, sqrt(dx*dx + du*du + dv*dv)) // Ensure non-zero to prevent Div/0

            let dXm = curr.Xm - prev.Xm
            let dYm = curr.Ym - prev.Ym
            let dZm = curr.Zm - prev.Zm
            let dAm = curr.Am - prev.Am
            let dMachine = sqrt(dXm*dXm + dYm*dYm + dZm*dZm + dAm*dAm)

            // Calculate the maximum linear acceleration allowable along the path surface
            let limitA_X = abs(dXm) > 1e-6 ? aMaxX * dS / abs(dXm) : .greatestFiniteMagnitude
            let limitA_Y = abs(dYm) > 1e-6 ? aMaxY * dS / abs(dYm) : .greatestFiniteMagnitude
            let limitA_Z = abs(dZm) > 1e-6 ? aMaxZ * dS / abs(dZm) : .greatestFiniteMagnitude
            let limitA_A = abs(dAm) > 1e-6 ? aMaxA * dS / abs(dAm) : .greatestFiniteMagnitude

            let aPath = min(limitA_X, limitA_Y, limitA_Z, limitA_A)
            
            segments.append(TrajectorySegment(dS: dS, dMachine: dMachine, dXm: dXm, dYm: dYm, dZm: dZm, dAm: dAm, aPath: aPath))
        }

        // 2. Calculate Junction Speed Limits (The Non-Linear Jacobian Derivative)
        // This solves for centripetal-equivalent cornering forces based on 2nd derivatives.
        var vJunction = [CGFloat](repeating: settings.feedRate, count: machinePoints.count)

        if segments.count > 1 {
            for i in 1..<segments.count {
                let prev = segments[i-1]
                let curr = segments[i]

                let dS_avg = (prev.dS + curr.dS) / 2.0
                if dS_avg < 1e-6 { continue }

                // Rate of change of axis position per unit surface distance
                let rPrevX = prev.dXm / prev.dS, rCurrX = curr.dXm / curr.dS
                let rPrevY = prev.dYm / prev.dS, rCurrY = curr.dYm / curr.dS
                let rPrevZ = prev.dZm / prev.dS, rCurrZ = curr.dZm / curr.dS
                let rPrevA = prev.dAm / prev.dS, rCurrA = curr.dAm / curr.dS

                // Second derivative (change in rate)
                let drX = abs(rCurrX - rPrevX)
                let drY = abs(rCurrY - rPrevY)
                let drZ = abs(rCurrZ - rPrevZ)
                let drA = abs(rCurrA - rPrevA)

                // Max surface velocity allowed by instantaneous axis direction changes
                let vLimX = drX > 1e-6 ? sqrt(aMaxX * dS_avg / drX) : .greatestFiniteMagnitude
                let vLimY = drY > 1e-6 ? sqrt(aMaxY * dS_avg / drY) : .greatestFiniteMagnitude
                let vLimZ = drZ > 1e-6 ? sqrt(aMaxZ * dS_avg / drZ) : .greatestFiniteMagnitude
                let vLimA = drA > 1e-6 ? sqrt(aMaxA * dS_avg / drA) : .greatestFiniteMagnitude

                let minCornerV = min(vLimX, vLimY, vLimZ, vLimA)
                vJunction[i] = min(settings.feedRate, minCornerV)
            }
        }

        // 3. The Forward Pass (Acceleration Limits)
        var vFwd = [CGFloat](repeating: 0.0, count: machinePoints.count)
        vFwd[0] = vJunction[0]

        for i in 0..<segments.count {
            let seg = segments[i]
            let vExitLimit = sqrt(pow(vFwd[i], 2) + 2.0 * seg.aPath * seg.dS)
            vFwd[i+1] = min(vExitLimit, vJunction[i+1])
        }

        // 4. The Backward Pass (Deceleration Pre-planning)
        var vFinal = [CGFloat](repeating: 0.0, count: machinePoints.count)
        vFinal[segments.count] = vFwd[segments.count]

        for i in stride(from: segments.count - 1, through: 0, by: -1) {
            let seg = segments[i]
            let vEntryLimit = sqrt(pow(vFinal[i+1], 2) + 2.0 * seg.aPath * seg.dS)
            vFinal[i] = min(vFwd[i], vEntryLimit)
        }

        // 5. Convert Safe Surface Speeds to feedrates
        for i in 0..<segments.count {
            if settings.useSimCNC {
                // SimCNC G94 4D spoofed feedrate: preserves execution time across all axes
                var vSafe = (vFinal[i] + vFinal[i+1]) / 2.0
                if vSafe < 1.0 { vSafe = 1.0 }
                let dt = segments[i].dS / vSafe
                let fG94 = dt > 1e-6 ? segments[i].dMachine / dt : settings.rapidRate
                segments[i].finalF = min(fG94, settings.rapidRate)
            } else {
                // Standard mode: clamp kinematically profiled surface speed directly to feedRate
                let vSafe = min((vFinal[i] + vFinal[i+1]) / 2.0, settings.feedRate)
                segments[i].finalF = max(vSafe, 1.0)
            }
        }

        // --- G-Code Output Generation ---
        var lines: [String] = []
        let typeStr = feature.type.rawValue.capitalized
        let directionStr = isInternal ? "CW (Physical CCW)" : "CCW (Physical CW)"
        lines.append("; --- \(typeStr)  X=\(fmt(feature.xCenter + packStartX))mm  A=\(fmt(feature.aCenterDeg + rollOffset))° ---")
        lines.append("; TCP Active | Swirl Comp: \(directionStr) | Tangential OB | Comp: Offline (\(settings.enableKerfComp ? "Enabled" : "Disabled"))")
        
        let pierceMp = machinePoints[0]
        let dynamicSafeZ = settings.enableDynamicSafeZ ? getDynamicSafeZ(stock: stock) : (pierceMp.Zm + settings.safeHeight)
        
        // Retract strictly BEFORE moving X, Y, A to avoid diagonal collisions during A-axis corner swings
        lines.append("G0 Z\(fmtU(dynamicSafeZ))  ; retract to asymmetric safe Z envelope")
        lines.append("G0 X\(fmtU(pierceMp.Xm)) Y\(fmtU(pierceMp.Ym)) A\(fmt(pierceMp.Am)) ; rapid to pierce location")
        lines.append("G0 Z\(fmtU(pierceMp.Zm + settings.pierceHeight)) ; lower to pierce height")
        lines.append("M3 S1                         ; torch on")

        // Track the current THC state to inject toggles smoothly
        var currentTHCState = true
        if settings.enableDynamicTHC {
            if pierceMp.isCorner {
                lines.append("M220                  ; THC OFF (Corner Lock)")
                currentTHCState = false
            } else {
                lines.append("M221                  ; THC ON (Flat Segment)")
            }
        }

        // Executing the Profiled Trajectory
        for i in 1..<machinePoints.count {
            let curr = machinePoints[i]
            let seg = segments[i-1]
            
            // Apply Dynamic THC Control
            if settings.enableDynamicTHC {
                if curr.isCorner && currentTHCState {
                    lines.append("M220                  ; THC OFF (Corner Lock)")
                    currentTHCState = false
                } else if !curr.isCorner && !currentTHCState {
                    lines.append("M221                  ; THC ON (Flat Segment)")
                    currentTHCState = true
                }
            }
            
            lines.append("G1 X\(fmtU(curr.Xm)) Y\(fmtU(curr.Ym)) Z\(fmtU(curr.Zm + settings.cutHeight)) A\(fmt(curr.Am)) F\(fmtF(seg.finalF, segment: seg))")
        }

        // Torch Off and clean retract
        lines.append("M5                            ; torch off")
        lines.append("G0 Z\(fmtU(dynamicSafeZ))  ; retract to asymmetric safe Z envelope before next move")
        return (lines, machinePoints.last!.Am)
    }

    // MARK: - Mathematical Core: HSS Kinematic Mapping
    
    /// Dynamically calculates the true circumscribed bounding radius needed to clear all corners
    /// while rapidly moving the A axis, avoiding diagonal tube crashes.
    private func getDynamicSafeZ(stock: StockInfo) -> CGFloat {
        let baselineZ: CGFloat
        let maxRadius: CGFloat
        
        if stock.profile == .round {
            baselineZ = (stock.od ?? 50.0) / 2.0
            maxRadius = baselineZ
        } else {
            let W = stock.odX ?? stock.od ?? 50.0
            let H = stock.odY ?? stock.od ?? 50.0
            baselineZ = H / 2.0
            
            let R = min(W, H) * 0.1 // Standardized 10% corner radius
            let wHalf = W / 2.0
            let hHalf = H / 2.0
            
            // True geometric circumscribed envelope
            maxRadius = sqrt(pow(wHalf - R, 2) + pow(hHalf - R, 2)) + R
        }
        
        let extraClearance = max(0, maxRadius - baselineZ)
        return settings.safeHeight + extraClearance
    }

    private func getProfilePoint(angleDeg: CGFloat, stock: StockInfo) -> (u: CGFloat, v: CGFloat, Nu: CGFloat, Nv: CGFloat) {
        if stock.profile == .round {
            let r = (stock.od ?? max(stock.odX ?? 50, stock.odY ?? 50)) / 2.0
            let rad = angleDeg * .pi / 180.0
            return (r * cos(rad), r * sin(rad), cos(rad), sin(rad))
        } else {
            let W = stock.odX ?? stock.od ?? 50.0
            let H = stock.odY ?? stock.od ?? 50.0
            let R = min(W, H) * 0.1 // Standardized 10% corner radius
            let w = W - 2*R
            let h = H - 2*R

            let rad = angleDeg * .pi / 180.0
            let cosPhi = cos(rad)
            let sinPhi = sin(rad)

            var bestT: CGFloat = .greatestFiniteMagnitude
            var bestU: CGFloat = 0, bestV: CGFloat = 0
            var bestNu: CGFloat = 0, bestNv: CGFloat = 0

            // 1. Raycast Flat Faces
            if cosPhi > 1e-6 {
                let t = (W/2) / cosPhi
                if abs(t * sinPhi) <= h/2 { bestT = t; bestU = W/2; bestV = t * sinPhi; bestNu = 1; bestNv = 0 }
            }
            if cosPhi < -1e-6 {
                let t = (-W/2) / cosPhi
                if abs(t * sinPhi) <= h/2 && t < bestT { bestT = t; bestU = -W/2; bestV = t * sinPhi; bestNu = -1; bestNv = 0 }
            }
            if sinPhi > 1e-6 {
                let t = (H/2) / sinPhi
                if abs(t * cosPhi) <= w/2 && t < bestT { bestT = t; bestU = t * cosPhi; bestV = H/2; bestNu = 0; bestNv = 1 }
            }
            if sinPhi < -1e-6 {
                let t = (-H/2) / sinPhi
                if abs(t * cosPhi) <= w/2 && t < bestT { bestT = t; bestU = t * cosPhi; bestV = -H/2; bestNu = 0; bestNv = -1 }
            }

            // 2. Raycast Corner Radii
            let centers: [(CGFloat, CGFloat)] = [(w/2, h/2), (-w/2, h/2), (-w/2, -h/2), (w/2, -h/2)]
            for (cx, cy) in centers {
                let b = -2 * (cx * cosPhi + cy * sinPhi)
                let c = cx*cx + cy*cy - R*R
                let discriminant = b*b - 4*c
                if discriminant >= 0 {
                    for t in [(-b - sqrt(discriminant)) / 2, (-b + sqrt(discriminant)) / 2] {
                        if t > 1e-6 && t < bestT {
                            let u = t * cosPhi
                            let v = t * sinPhi
                            let validU = (cx > 0) ? (u >= cx - 1e-4) : (u <= cx + 1e-4)
                            let validV = (cy > 0) ? (v >= cy - 1e-4) : (v <= cy + 1e-4)
                            if validU && validV {
                                bestT = t; bestU = u; bestV = v
                                let len = sqrt((u-cx)*(u-cx) + (v-cy)*(v-cy))
                                bestNu = (u-cx)/len; bestNv = (v-cy)/len
                            }
                        }
                    }
                }
            }
            
            // Failsafe
            if bestT == .greatestFiniteMagnitude { return (0, H/2, 0, 1) }
            
            return (bestU, bestV, bestNu, bestNv)
        }
    }

    private func convertToMachine(pt: ToolpathPoint, stock: StockInfo) -> MachinePoint {
        let profile = getProfilePoint(angleDeg: pt.a, stock: stock)
        
        let thetaRad = atan2(profile.Nu, profile.Nv)

        let Ym = profile.u * cos(thetaRad) - profile.v * sin(thetaRad)
        let Zm = profile.u * sin(thetaRad) + profile.v * cos(thetaRad)
        let machineA = thetaRad * 180.0 / .pi

        let baselineZ: CGFloat
        let isCorner: Bool
        
        if stock.profile == .round {
            baselineZ = (stock.od ?? max(stock.odX ?? 50, stock.odY ?? 50)) / 2.0
            isCorner = false
        } else {
            baselineZ = (stock.odY ?? stock.od ?? 50.0) / 2.0
            // Flat faces have normals strictly aligned with U or V axes (1 or -1)
            let isFlat = abs(profile.Nu) > 0.999 || abs(profile.Nv) > 0.999
            isCorner = !isFlat
        }
        let relativeZm = Zm - baselineZ

        return MachinePoint(Xm: pt.x, Ym: Ym, Zm: relativeZm, Am: machineA, matX: pt.x, matU: profile.u, matV: profile.v, isCorner: isCorner)
    }

    // MARK: - Utilities
    
    private func fmt(_ val: CGFloat) -> String {
        return String(format: "%.3f", val)
    }

    /// Format a linear coordinate value (mm internally) in the selected output unit.
    /// Angles (degrees) are **not** passed through this — use `fmt` for those.
    private func fmtU(_ val: CGFloat) -> String {
        if settings.units == .inches {
            return String(format: "%.4f", val / 25.4)
        }
        return String(format: "%.3f", val)
    }

    /// Format a feed-rate value (mm/min internally) in the selected output unit.
    ///
    /// For SimCNC G94 spoofed rates the 4D machine distance includes the A axis in
    /// degrees, which does not scale with length.  The conversion factor is therefore
    /// computed from the per-segment displacements so that the execution time (dt) is
    /// preserved exactly when the controller operates in inch mode.
    private func fmtF(_ val: CGFloat, segment: TrajectorySegment? = nil) -> String {
        var rate = val
        if settings.units == .inches {
            if settings.useSimCNC, let seg = segment, seg.dMachine > 1e-9 {
                // dMachine_in = √((ΔX/25.4)² + (ΔY/25.4)² + (ΔZ/25.4)² + ΔA²)
                let dMachineIn = sqrt(
                    pow(seg.dXm / 25.4, 2) +
                    pow(seg.dYm / 25.4, 2) +
                    pow(seg.dZm / 25.4, 2) +
                    pow(seg.dAm, 2)
                )
                rate = val * dMachineIn / seg.dMachine
            } else {
                rate = val / 25.4
            }
        }
        return String(format: "%.3f", rate)
    }

    /// Unit label for use in G-code comments.
    private var unitLabel: String { settings.units == .inches ? "in" : "mm" }

    /// G20/G21 mode word.
    private var unitModeWord: String { settings.units == .inches ? "G20" : "G21" }

    /// Human-readable unit mode description.
    private var unitModeComment: String { settings.units == .inches ? "inch mode" : "metric mode" }

    private func sortFeatures(_ features: [SurfaceFeature]) -> [SurfaceFeature] {
        return features.sorted { a, b in
            func priority(_ t: SurfaceFeatureType) -> Int {
                switch t {
                case .endCut: return 0
                case .hole, .cutout, .notch: return 1
                case .startCut: return 2
                }
            }
            let pA = priority(a.type), pB = priority(b.type)
            return pA != pB ? pA < pB : a.xCenter > b.xCenter
        }
    }

    // MARK: - Boilerplate
    private func generateHeader(stock: StockInfo) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy, HH:mm"
        
        var header = [
            "%",
            "(PROGRAM NAME: cylinder)",
            "(GENERATED: \(formatter.string(from: Date())))",
            "(STOCK: \(stock.profile.rawValue))"
        ]
        
        if stock.profile == .round {
            header.append("(OD: \(fmtU(stock.od ?? 0))\(unitLabel))")
        } else {
            header.append("(OD: \(fmtU(stock.odX ?? 0))\(unitLabel) x \(fmtU(stock.odY ?? 0))\(unitLabel))")
        }

        header.append("(LENGTH: \(fmtU(stock.length))\(unitLabel))")
        return header
    }

    private func generateStartupSequence(totalLength: CGFloat, stock: StockInfo, packMode: Bool = false, count: Int = 1) -> [String] {
        let safeZ = settings.enableDynamicSafeZ ? getDynamicSafeZ(stock: stock) : settings.safeHeight
        return [
            "\(unitModeWord)             ; \(unitModeComment)",
            "G90             ; absolute positioning",
            "G40             ; cancel cutter comp",
            "G49             ; cancel tool length offset",
            "G92 X\(fmtU(totalLength)) Y0 Z0 A0 ; set current position as right-most free end",
            "",
            "G0 Z\(fmtU(safeZ))     ; move to safe height",
            "M5              ; torch off (ensure)",
            "",
            packMode ? "; === Cutting Pattern (right-to-left, \(count) piece\(count == 1 ? "" : "s")) ===" : "; === Cutting Pattern ==="
        ]
    }

    private func generateEndSequence(stock: StockInfo?) -> [String] {
        let safeZ = (settings.enableDynamicSafeZ && stock != nil) ? getDynamicSafeZ(stock: stock!) : settings.safeHeight
        return [
            "; === Program End ===",
            "M5              ; torch off (redundant safety)",
            "G0 Z\(fmtU(safeZ))  ; retract to safe height",
            "G0 X0 Y0 A0     ; return to home (TCP centered)",
            "M30             ; end of program",
            "%"
        ]
    }
}
