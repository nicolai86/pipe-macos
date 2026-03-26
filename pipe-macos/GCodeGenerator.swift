import Foundation
import SceneKit
import simd

// MARK: - Pack Entry

/// One piece within a multi-part pack layout.
struct PackEntry {
    let shape: SelectedShape
    /// X coordinate of the piece's low-X end in pack space (mm).
    let packStartX: CGFloat
    /// X coordinate of the piece's high-X end in pack space (mm).
    var packEndX: CGFloat { packStartX + (shape.stockInfo?.length ?? 0) }
}

// MARK: - Global Feature (Thermal Hedging)

/// A surface feature resolved into pack (global) coordinates, used by the thermal-hedging sequencer.
struct GlobalFeature {
    let feature: GeometricFeature
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
struct GCodeSettings {

    // -------------------------------------------------------------------------
    // MARK: Feed Rates
    // -------------------------------------------------------------------------

    var feedRate: CGFloat = 1000.0
    var rapidRate: CGFloat = 3000.0

    // -------------------------------------------------------------------------
    // MARK: Z-Axis Clearance
    // -------------------------------------------------------------------------

    var safeHeight: CGFloat = 25.0
    var enableDynamicSafeZ: Bool = true

    // -------------------------------------------------------------------------
    // MARK: Pierce & Cut Heights
    // -------------------------------------------------------------------------

    var pierceHeight: CGFloat = 3.8
    var cutHeight: CGFloat = 3.2

    // -------------------------------------------------------------------------
    // MARK: Kerf Compensation
    // -------------------------------------------------------------------------

    var kerfWidth: CGFloat = 2.0
    var enableKerfComp: Bool = true

    // -------------------------------------------------------------------------
    // MARK: Nonlinear Error Compensation
    // -------------------------------------------------------------------------

    var enableNonlinearErrorCompensation: Bool = true
    var nonlinearErrorTolerance: CGFloat = 0.05

    // -------------------------------------------------------------------------
    // MARK: Adaptive Singularity Damping (ADLS)
    // -------------------------------------------------------------------------

    /// When `true`, applies an Adaptive Damped Least Squares filter to A-axis motion.
    /// WHY: On rectangular stock, the kinematic Jacobian becomes singular at corners (radius of rotation -> 0).
    /// This causes the required A-axis angular velocity to approach infinity to maintain constant surface speed.
    /// ADLS dynamically damps these "velocity blow-ups" to prevent motor stalls while staying within a
    /// defined path-error tolerance.
    var enableSingularityDamping: Bool = true

    /// The maximum damping factor applied at the peak of a singularity (corner).
    var singularityDampingFactor: CGFloat = 2.0

    /// The threshold of manipulability (dS/dA) below which damping begins to activate.
    var dampingThreshold: CGFloat = 0.1

    // -------------------------------------------------------------------------
    // MARK: Lead-In Geometry
    // -------------------------------------------------------------------------

    var leadInDistance: CGFloat = 5.0
    var leadInAngle: CGFloat = 90.0
    var leadInAngleDistance: CGFloat = 3.0

    // -------------------------------------------------------------------------
    // MARK: Overburn
    // -------------------------------------------------------------------------

    var overburnDegrees: CGFloat = 10.0

    // -------------------------------------------------------------------------
    // MARK: Controller Mode
    // -------------------------------------------------------------------------

    var useSimCNC: Bool = true
    /// WHY: On HSS stock, the G-code actively commands Z-axis moves to track flat faces
    /// and corners. If the controller's arc-voltage THC is active at the same time,
    /// a dual-loop conflict occurs, causing the Z-axis to oscillate or dive.
    /// Dynamic THC injects lock codes at corners to prioritize the kinematic toolpath.
    var enableDynamicTHC: Bool = true
    var units: GCodeUnit = .metric

    // -------------------------------------------------------------------------
    // MARK: Per-Axis Acceleration Limits
    // -------------------------------------------------------------------------

    var maxAccelX: CGFloat = 500.0
    var maxAccelY: CGFloat = 500.0
    var maxAccelZ: CGFloat = 300.0
    var maxAccelA: CGFloat = 1000.0

    // -------------------------------------------------------------------------
    // MARK: Per-Axis Jerk Limits (S-curve)
    // -------------------------------------------------------------------------

    /// WHY: Trapezoidal acceleration causes infinite jerk at ramp start/end, leading to
    /// mechanical resonance and vibration. This is especially critical for the A-axis (chuck)
    /// which has the highest inertia in the system. S-curve profiling smooths these
    /// transitions by limiting mm/s³ (jerk).
    var maxJerkX: CGFloat = 5000.0
    var maxJerkY: CGFloat = 5000.0
    var maxJerkZ: CGFloat = 2000.0
    var maxJerkA: CGFloat = 10000.0

    // -------------------------------------------------------------------------
    // MARK: Thermal Hedging
    // -------------------------------------------------------------------------

    var enableThermalHedging: Bool = true
    var thermalHedgingWeightX: CGFloat = 1.0
    var thermalHedgingWeightA: CGFloat = 1.0
}

// MARK: - Machine TCP Data Structure

struct MachinePoint {
    var Xm: CGFloat
    var Ym: CGFloat
    var Zm: CGFloat
    var Am: CGFloat
    var matX: CGFloat
    var matU: CGFloat
    var matV: CGFloat
    var isCorner: Bool
}

// MARK: - Velocity Profiling Segment

struct TrajectorySegment {
    var dS: CGFloat
    var dMachine: CGFloat
    var dXm: CGFloat
    var dYm: CGFloat
    var dZm: CGFloat
    var dAm: CGFloat
    var aPath: CGFloat
    var jPath: CGFloat
    var finalF: CGFloat = 0.0
}

/// A feature that has been through planning, kinematics, and velocity profiling.
struct ToolpathFeature {
    let source: PlannedFeature
    let machinePoints: [MachinePoint]
    let segments: [TrajectorySegment]
}

// MARK: - GCode Generator

class GCodeGenerator {
    var settings = GCodeSettings()

    // MARK: - Single Part Generation

    func generateGCode(for stock: StockInfo) -> String {
        let rollOffset = GCodeGenerator.calculateRollOffset(for: stock)
        let emitter = GCodeEmitter(settings: settings)
        var gcode: [String] = []
        gcode.append(contentsOf: emitter.emitHeader(stock: stock))
        gcode.append(contentsOf: emitter.emitStartup(totalLength: stock.length, stock: stock))

        var currentA: CGFloat = 0
        let radius: CGFloat = stock.profile == .round
            ? (stock.od ?? 50.0) / 2.0
            : max(stock.odX ?? 50.0, stock.odY ?? 50.0) / 2.0

        let allGlobalFeatures = stock.features.map {
            GlobalFeature(
                feature: $0, stock: stock, packStartX: 0,
                packEndX: stock.length, rollOffset: rollOffset, pieceIndex: 0
            )
        }

        let orderedFeatures: [GlobalFeature]
        if settings.enableThermalHedging {
            var internals = allGlobalFeatures.filter {
                $0.feature.type == .hole || $0.feature.type == .cutout || $0.feature.type == .notch
            }
            var severs = allGlobalFeatures.filter {
                $0.feature.type == .startCut || $0.feature.type == .endCut
            }
            internals = sequenceForThermalHedging(features: internals, radius: radius)
            severs.sort { $0.globalX > $1.globalX }
            orderedFeatures = internals + severs
        } else {
            orderedFeatures = sortFeatures(stock.features).map {
                GlobalFeature(
                    feature: $0, stock: stock, packStartX: 0,
                    packEndX: stock.length, rollOffset: rollOffset, pieceIndex: 0
                )
            }
        }

        for gf in orderedFeatures {
            let result = generateTCPToolpath(
                feature: gf.feature, stock: gf.stock,
                packStartX: gf.packStartX, rollOffset: gf.rollOffset,
                currentA: currentA, isPackMode: false
            )
            gcode.append(contentsOf: result.gcode)
            gcode.append("")
            if let last = result.feature.machinePoints.last {
                currentA = last.Am
            }
        }

        gcode.append(contentsOf: emitter.emitEnd(stock: stock))
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
        let emitter = GCodeEmitter(settings: settings)
        let safeZ = settings.enableDynamicSafeZ
            ? emitter.getDynamicSafeZ(stock: refStock) : settings.safeHeight
        let unitLabel = settings.units == .inches ? "in" : "mm"
        let unitModeWord = settings.units == .inches ? "G20" : "G21"
        let unitModeComment = settings.units == .inches ? "inch mode" : "metric mode"

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
                let rollOffset = GCodeGenerator.calculateRollOffset(for: stock)
                for f in stock.features {
                    allFeatures.append(GlobalFeature(
                        feature: f, stock: stock,
                        packStartX: entry.packStartX, packEndX: entry.packEndX,
                        rollOffset: rollOffset, pieceIndex: idx
                    ))
                }
            }
            let radius: CGFloat = refStock.profile == .round
                ? (refStock.od ?? 50.0) / 2.0
                : max(refStock.odX ?? 50.0, refStock.odY ?? 50.0) / 2.0
            var internals = allFeatures.filter {
                $0.feature.type == .hole || $0.feature.type == .cutout || $0.feature.type == .notch
            }
            var severs = allFeatures.filter {
                $0.feature.type == .startCut || $0.feature.type == .endCut
            }
            internals = sequenceForThermalHedging(features: internals, radius: radius)
            severs.sort { $0.globalX > $1.globalX }

            for gf in internals + severs {
                lines.append("; ┌── Piece \(gf.pieceIndex + 1)/\(entries.count) | Feature: \(gf.feature.type.rawValue) at Global X=\(fmt(gf.globalX)) ──")
                let result = generateTCPToolpath(
                    feature: gf.feature, stock: gf.stock,
                    packStartX: gf.packStartX, rollOffset: gf.rollOffset,
                    currentA: currentA, isPackMode: true
                )
                lines += result.gcode
                lines.append("")
                if let last = result.feature.machinePoints.last {
                    currentA = last.Am
                }
            }
        } else {
            let ordered = entries.sorted { $0.packStartX > $1.packStartX }
            for (pieceIdx, entry) in ordered.enumerated() {
                guard let stock = entry.shape.stockInfo else { continue }
                let rollOffset = GCodeGenerator.calculateRollOffset(for: stock)
                lines += [
                    "",
                    "; ┌── Piece \(pieceIdx + 1)/\(ordered.count)  "
                        + "X=\(fmt(entry.packStartX))–\(fmt(entry.packEndX))mm  "
                        + "L=\(fmt(stock.length))mm  "
                        + "\(stock.features.count) feature\(stock.features.count == 1 ? "" : "s") ──",
                ]
                for feature in sortFeatures(stock.features) {
                    let result = generateTCPToolpath(
                        feature: feature, stock: stock,
                        packStartX: entry.packStartX, rollOffset: rollOffset,
                        currentA: currentA, isPackMode: true
                    )
                    lines += result.gcode
                    lines.append("")
                    if let last = result.feature.machinePoints.last {
                        currentA = last.Am
                    }
                }
            }
        }

        lines += emitter.emitEnd(stock: refStock)
        return lines.joined(separator: "\n")
    }

    // MARK: - Roll Offset

    static func calculateRollOffset(for stock: StockInfo) -> CGFloat {
        let q1 = alignAxisToX(stock.axis)
        var rollDeg: CGFloat = 0
        if stock.profile != .round {
            let rotatedU = q1.act(normalize(stock.uAxis))
            let rollAngle = atan2(rotatedU.z, rotatedU.y)
            rollDeg = CGFloat(-rollAngle * 180.0 / .pi)
        }
        return rollDeg
    }

    private static func alignAxisToX(_ axis: SIMD3<Float>) -> simd_quatf {
        let target = SIMD3<Float>(1, 0, 0)
        let a = normalize(axis)
        let d = dot(a, target)
        if d > 0.9999 { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        if d < -0.9999 { return simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)) }
        return simd_quatf(angle: acos(d), axis: normalize(cross(a, target)))
    }

    // MARK: - TCP Toolpath (Orchestrator)

    private func generateTCPToolpath(
        feature: GeometricFeature,
        stock: StockInfo,
        packStartX: CGFloat,
        rollOffset: CGFloat,
        currentA: CGFloat,
        isPackMode: Bool
    ) -> (gcode: [String], feature: ToolpathFeature) {
        let planned = ToolpathPlanner(settings: settings).plan(
            feature: feature, stock: stock,
            packStartX: packStartX, rollOffset: rollOffset,
            previousMachineAm: currentA
        )
        guard !planned.plannedPath.points.isEmpty else {
            return ([], ToolpathFeature(source: planned, machinePoints: [], segments: []))
        }

        let machines = KinematicsEngine(settings: settings).convert(
            plannedFeature: planned, stock: stock,
            initialMachineAm: isPackMode ? currentA : nil
        )
        let segments = VelocityProfiler(settings: settings).profile(machinePoints: machines)
        let toolpathFeature = ToolpathFeature(source: planned, machinePoints: machines, segments: segments)
        let gcode = GCodeEmitter(settings: settings).emitFeature(
            toolpathFeature: toolpathFeature,
            stock: stock,
            packStartX: packStartX,
            rollOffset: rollOffset
        )
        return (gcode, toolpathFeature)
    }

    // MARK: - Thermal Hedging

    private func sequenceForThermalHedging(
        features: [GlobalFeature],
        radius: CGFloat
    ) -> [GlobalFeature] {
        guard !features.isEmpty else { return [] }
        var remaining = features
        var sequenced: [GlobalFeature] = []
        remaining.sort { $0.globalX > $1.globalX }
        var current = remaining.removeFirst()
        sequenced.append(current)
        while !remaining.isEmpty {
            if let nextIdx = remaining.indices.max(by: { i, j in
                thermalDistance(current, remaining[i], radius: radius)
                    < thermalDistance(current, remaining[j], radius: radius)
            }) {
                current = remaining.remove(at: nextIdx)
                sequenced.append(current)
            }
        }
        return sequenced
    }

    private func thermalDistance(
        _ f1: GlobalFeature,
        _ f2: GlobalFeature,
        radius: CGFloat
    ) -> CGFloat {
        let dx = (f1.globalX - f2.globalX) * settings.thermalHedgingWeightX
        var da = abs(
            f1.globalA.truncatingRemainder(dividingBy: 360.0)
            - f2.globalA.truncatingRemainder(dividingBy: 360.0)
        )
        if da > 180.0 { da = 360.0 - da }
        let arcLen = (da * .pi / 180.0 * radius) * settings.thermalHedgingWeightA
        return sqrt(dx * dx + arcLen * arcLen)
    }

    // MARK: - Feature Sorting

    private func sortFeatures(_ features: [GeometricFeature]) -> [GeometricFeature] {
        return features.sorted { a, b in
            func priority(_ t: SurfaceFeatureType) -> Int {
                switch t {
                case .endCut: return 0
                case .hole, .cutout, .notch: return 1
                case .startCut: return 2
                }
            }
            return priority(a.type) != priority(b.type)
                ? priority(a.type) < priority(b.type)
                : a.xCenter > b.xCenter
        }
    }

    // MARK: - Formatting (pack header only)

    private func fmt(_ val: CGFloat) -> String { String(format: "%.3f", val) }

    private func fmtU(_ val: CGFloat) -> String {
        settings.units == .inches
            ? String(format: "%.4f", val / 25.4)
            : String(format: "%.3f", val)
    }
}
