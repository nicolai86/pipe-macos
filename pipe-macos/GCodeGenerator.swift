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
    /// Higher values allow for smoother motion through tighter corners at the cost of slight path deviation.
    var singularityDampingFactor: CGFloat = 2.0

    /// The threshold of manipulability (dS/dA) below which damping begins to activate.
    /// Targets the "velocity blow-up" region of the kinematic Jacobian.
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

// MARK: - GCode Generator
class GCodeGenerator {
    var settings = GCodeSettings()

    // MARK: - Single Part Generation
    func generateGCode(for stock: StockInfo, rollOffset: CGFloat = 0.0)
        -> String
    {
        var gcode: [String] = []
        gcode.append(contentsOf: generateHeader(stock: stock))
        gcode.append(
            contentsOf: generateStartupSequence(
                totalLength: stock.length,
                stock: stock
            )
        )

        var currentA: CGFloat = 0

        if settings.enableThermalHedging {
            let radius =
                stock.profile == .round
                ? (stock.od ?? 50.0) / 2.0
                : max(stock.odX ?? 50.0, stock.odY ?? 50.0) / 2.0
            let allFeatures = stock.features.map {
                GlobalFeature(
                    feature: $0,
                    stock: stock,
                    packStartX: 0,
                    packEndX: stock.length,
                    rollOffset: rollOffset,
                    pieceIndex: 0
                )
            }

            var internals = allFeatures.filter {
                $0.feature.type == .hole || $0.feature.type == .cutout
                    || $0.feature.type == .notch
            }
            var severs = allFeatures.filter {
                $0.feature.type == .startCut || $0.feature.type == .endCut
            }

            internals = sequenceForThermalHedging(
                features: internals,
                radius: radius
            )
            severs.sort { $0.globalX > $1.globalX }

            let finalSequence = internals + severs
            for gf in finalSequence {
                let (toolpath, finalA) = generateTCPToolpath(
                    feature: gf.feature,
                    stock: gf.stock,
                    packStartX: gf.packStartX,
                    packEndX: gf.packEndX,
                    rollOffset: gf.rollOffset,
                    currentA: currentA,
                    isPackMode: false
                )
                gcode.append(contentsOf: toolpath)
                gcode.append("")
                currentA = finalA
            }
        } else {
            let sortedFeatures = sortFeatures(stock.features)
            for feature in sortedFeatures {
                let (toolpath, finalA) = generateTCPToolpath(
                    feature: feature,
                    stock: stock,
                    packStartX: 0,
                    packEndX: stock.length,
                    rollOffset: rollOffset,
                    currentA: currentA,
                    isPackMode: false
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

        let totalLength =
            entries.max(by: { $0.packEndX < $1.packEndX })?.packEndX ?? 0
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy, HH:mm"

        let safeZ =
            settings.enableDynamicSafeZ
            ? getDynamicSafeZ(stock: refStock) : settings.safeHeight

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
            lines.append(
                "; === Thermal Hedging Enabled: Global Cut Sequencing ==="
            )
            var allFeatures: [GlobalFeature] = []

            for (idx, entry) in entries.enumerated() {
                guard let stock = entry.shape.stockInfo else { continue }
                for f in stock.features {
                    allFeatures.append(
                        GlobalFeature(
                            feature: f,
                            stock: stock,
                            packStartX: entry.packStartX,
                            packEndX: entry.packEndX,
                            rollOffset: entry.rollOffset,
                            pieceIndex: idx
                        )
                    )
                }
            }

            var internals = allFeatures.filter {
                $0.feature.type == .hole || $0.feature.type == .cutout
                    || $0.feature.type == .notch
            }
            var severs = allFeatures.filter {
                $0.feature.type == .startCut || $0.feature.type == .endCut
            }
            let radius: CGFloat =
                refStock.profile == .round
                ? (refStock.od ?? 50.0) / 2.0
                : max(refStock.odX ?? 50.0, refStock.odY ?? 50.0) / 2.0

            internals = sequenceForThermalHedging(
                features: internals,
                radius: radius
            )
            severs.sort { $0.globalX > $1.globalX }

            let finalSequence = internals + severs
            for gf in finalSequence {
                lines.append(
                    "; ┌── Piece \(gf.pieceIndex + 1)/\(entries.count) | Feature: \(gf.feature.type.rawValue) at Global X=\(fmt(gf.globalX)) ──"
                )
                let (toolpath, finalA) = generateTCPToolpath(
                    feature: gf.feature,
                    stock: gf.stock,
                    packStartX: gf.packStartX,
                    packEndX: gf.packEndX,
                    rollOffset: gf.rollOffset,
                    currentA: currentA,
                    isPackMode: true
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
                        feature: feature,
                        stock: stock,
                        packStartX: entry.packStartX,
                        packEndX: entry.packEndX,
                        rollOffset: entry.rollOffset,
                        currentA: currentA,
                        isPackMode: true
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
                let distI = thermalDistance(
                    current,
                    remaining[i],
                    radius: radius
                )
                let distJ = thermalDistance(
                    current,
                    remaining[j],
                    radius: radius
                )
                return distI < distJ
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
        let arcLen =
            (da * .pi / 180.0 * radius) * settings.thermalHedgingWeightA
        return sqrt(dx * dx + arcLen * arcLen)
    }

    // MARK: - SOTA: Offline 2D Polyline Kerf Offset

    private func applyOfflineKerfOffset(
        to path: [ToolpathPoint],
        radius: CGFloat,
        isClosed: Bool,
        k: CGFloat
    ) -> [ToolpathPoint] {
        guard path.count > 1, radius != 0 else { return path }
        let pts: [(x: CGFloat, y: CGFloat)] = path.map { ($0.x, $0.a * k) }
        var offsetPts: [(x: CGFloat, y: CGFloat)] = []

        for i in 0..<pts.count {
            let prevIdx = (i == 0) ? (isClosed ? pts.count - 2 : 0) : i - 1
            let nextIdx =
                (i == pts.count - 1) ? (isClosed ? 1 : pts.count - 1) : i + 1
            let pPrev = pts[prevIdx]
            let pCurr = pts[i]
            let pNext = pts[nextIdx]

            var vInX = pCurr.x - pPrev.x
            var vInY = pCurr.y - pPrev.y
            let lenIn = sqrt(vInX * vInX + vInY * vInY)
            if lenIn > 1e-6 {
                vInX /= lenIn
                vInY /= lenIn
            }

            var vOutX = pNext.x - pCurr.x
            var vOutY = pNext.y - pCurr.y
            let lenOut = sqrt(vOutX * vOutX + vOutY * vOutY)
            if lenOut > 1e-6 {
                vOutX /= lenOut
                vOutY /= lenOut
            }

            if !isClosed {
                if i == 0 {
                    vInX = vOutX
                    vInY = vOutY
                } else if i == pts.count - 1 {
                    vOutX = vInX
                    vOutY = vInY
                }
            }

            let nInX = -vInY
            let nInY = vInX
            let nOutX = -vOutY
            let nOutY = vOutX
            let p1x = pCurr.x + radius * nInX
            let p1y = pCurr.y + radius * nInY
            let p2x = pCurr.x + radius * nOutX
            let p2y = pCurr.y + radius * nOutY
            let cross = vInX * vOutY - vInY * vOutX

            if abs(cross) < 1e-6 {
                offsetPts.append((p1x, p1y))
            } else {
                let dx = p2x - p1x
                let dy = p2y - p1y
                let t = (dx * vOutY - dy * vOutX) / cross
                offsetPts.append((p1x + t * vInX, p1y + t * vInY))
            }
        }
        if isClosed { offsetPts[offsetPts.count - 1] = offsetPts[0] }
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
        guard let localPath = feature.path, localPath.count > 1 else {
            return ([], currentA)
        }

        let packPath = localPath.map {
            ToolpathPoint(x: $0.x + packStartX, a: $0.a + rollOffset)
        }
        let rawPierceA = packPath[0].a
        let shift = round((currentA - rawPierceA) / 360.0) * 360.0
        var adjPath = packPath.map { ToolpathPoint(x: $0.x, a: $0.a + shift) }

        let OD: CGFloat =
            stock.profile == .round
            ? (stock.od ?? 50.0) : max(stock.odX ?? 50.0, stock.odY ?? 50.0)
        let k = (.pi * OD) / 360.0

        var isInternal =
            (feature.type == .hole || feature.type == .cutout
                || feature.type == .notch)

        if isInternal && adjPath.count > 2 {
            var maxLen: CGFloat = -1
            var bestIdx = 0
            for i in 0..<adjPath.count - 1 {
                let dx = adjPath[i + 1].x - adjPath[i].x
                let da_mm = (adjPath[i + 1].a - adjPath[i].a) * k
                let len = sqrt(dx * dx + da_mm * da_mm)
                if len > maxLen {
                    maxLen = len
                    bestIdx = i
                }
            }
            let midPt = ToolpathPoint(
                x: (adjPath[bestIdx].x + adjPath[bestIdx + 1].x) / 2.0,
                a: (adjPath[bestIdx].a + adjPath[bestIdx + 1].a) / 2.0
            )
            var newPath: [ToolpathPoint] = [midPt]
            newPath.append(
                contentsOf: adjPath[(bestIdx + 1)..<(adjPath.count - 1)]
            )
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
        } else if (feature.type == .startCut || feature.type == .endCut)
            && adjPath.count > 1
        {
            var bestIdx = 0
            var minDiff = CGFloat.greatestFiniteMagnitude
            for (i, pt) in adjPath.enumerated() {
                let modA = abs(pt.a.truncatingRemainder(dividingBy: 90.0))
                let diff = min(modA, 90.0 - modA)
                if diff < minDiff {
                    minDiff = diff
                    bestIdx = i
                }
            }
            if bestIdx > 0 {
                var corePath = adjPath
                if abs(corePath.last!.a - (corePath.first!.a + 360.0)) < 1.0 {
                    corePath.removeLast()
                }
                let reordered =
                    Array(corePath[bestIdx...]) + Array(corePath[..<bestIdx])
                var newPath: [ToolpathPoint] = [reordered[0]]
                for i in 1..<reordered.count {
                    var current_A = reordered[i].a
                    let prev_A = newPath.last!.a
                    while current_A - prev_A > 180.0 { current_A -= 360.0 }
                    while current_A - prev_A < -180.0 { current_A += 360.0 }
                    newPath.append(
                        ToolpathPoint(x: reordered[i].x, a: current_A)
                    )
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
        var signedArea: CGFloat = 0
        for i in 0..<finalPath.count - 1 {
            signedArea +=
                (finalPath[i].x * (finalPath[i + 1].a * k) - finalPath[i + 1].x
                    * (finalPath[i].a * k))
        }

        var isScrapLeft = false
        if isInternal {
            if signedArea > 0 { finalPath.reverse() }
            isScrapLeft = false
        } else {
            if feature.type == .startCut {
                if finalPath.last!.a < finalPath.first!.a {
                    finalPath.reverse()
                }
                isScrapLeft = true
            } else if feature.type == .endCut {
                if finalPath.last!.a > finalPath.first!.a {
                    finalPath.reverse()
                }
                isScrapLeft = true
            }
        }

        if settings.enableKerfComp {
            let kerfRadius =
                isScrapLeft
                ? (settings.kerfWidth / 2.0) : -(settings.kerfWidth / 2.0)
            finalPath = applyOfflineKerfOffset(
                to: finalPath,
                radius: kerfRadius,
                isClosed: isInternal,
                k: k
            )
        }

        if finalPath.count > 2 {
            let overburnDist = settings.overburnDegrees * k
            let pLast = finalPath.last!
            let pPrev = finalPath[finalPath.count - 2]
            let dx = pLast.x - pPrev.x
            let da_mm = (pLast.a - pPrev.a) * k
            let len = sqrt(dx * dx + da_mm * da_mm)
            if len > 0.001 {
                finalPath.append(
                    ToolpathPoint(
                        x: pLast.x + (dx / len) * overburnDist,
                        a: ((pLast.a * k) + (da_mm / len) * overburnDist) / k
                    )
                )
            }
        }

        let p0 = finalPath[0]
        let p1 =
            finalPath.count > 1
            ? finalPath[1] : ToolpathPoint(x: p0.x + 1, a: p0.a)
        let dx = p1.x - p0.x
        let da_mm = (p1.a - p0.a) * k
        let gamma = atan2(da_mm, dx)
        let leadR = settings.leadInAngleDistance
        let leadTheta = settings.leadInAngle * .pi / 180.0
        let leadL = settings.leadInDistance
        let sideMultiplier: CGFloat = isScrapLeft ? 1.0 : -1.0
        var leadInPoints: [ToolpathPoint] = []

        if leadTheta > 0.01 && leadR > 0.01 {
            let Cx = p0.x + leadR * cos(gamma + sideMultiplier * .pi / 2.0)
            let Cy =
                (p0.a * k) + leadR * sin(gamma + sideMultiplier * .pi / 2.0)
            let startAngle =
                (gamma - sideMultiplier * .pi / 2.0) - sideMultiplier
                * leadTheta
            let arcSteps = max(4, Int(leadTheta * 180 / .pi / 15))
            for i in 0..<arcSteps {
                let t =
                    startAngle + sideMultiplier
                    * (leadTheta * CGFloat(i) / CGFloat(arcSteps))
                leadInPoints.append(
                    ToolpathPoint(
                        x: Cx + leadR * cos(t),
                        a: (Cy + leadR * sin(t)) / k
                    )
                )
            }
        }
        let firstArcPt = leadInPoints.first ?? p0
        let entryTangent = gamma - sideMultiplier * leadTheta
        leadInPoints.insert(
            ToolpathPoint(
                x: firstArcPt.x - leadL * cos(entryTangent),
                a: ((firstArcPt.a * k) - leadL * sin(entryTangent)) / k
            ),
            at: 0
        )
        finalPath.insert(contentsOf: leadInPoints, at: 0)

        func getWrappedMachinePoint(pt: ToolpathPoint, refAm: CGFloat?)
            -> MachinePoint
        {
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

        var rawMachinePoints: [MachinePoint] = []
        var prevAmRaw: CGFloat? = nil
        for pt in finalPath {
            let mp = getWrappedMachinePoint(pt: pt, refAm: prevAmRaw)
            prevAmRaw = mp.Am
            rawMachinePoints.append(mp)
        }

        // ====================================================================
        // --- ADAPTIVE DAMPED LEAST SQUARES (ADLS) SINGULARITY DAMPING ---
        // ====================================================================
        var dampedMachinePoints: [MachinePoint] = []
        if !rawMachinePoints.isEmpty {
            dampedMachinePoints.append(rawMachinePoints[0])
            for i in 1..<rawMachinePoints.count {
                let prevDamped = dampedMachinePoints.last!
                let currRaw = rawMachinePoints[i]

                if settings.enableSingularityDamping {
                    let dx = currRaw.matX - prevDamped.matX
                    let du = currRaw.matU - prevDamped.matU
                    let dv = currRaw.matV - prevDamped.matV
                    let ds_cartesian = sqrt(dx * dx + du * du + dv * dv)
                    let target_dA = currRaw.Am - prevDamped.Am

                    // --- Adaptive Damping Calculation ---
                    // Manipulability 'm' is the ratio of surface travel to angular change.
                    // When 'm' is high (flat face), damping should be zero.
                    // When 'm' is low (corner), damping prevents A-axis velocity blow-up.
                    let m =
                        abs(target_dA) > 1e-6
                        ? ds_cartesian / abs(target_dA)
                        : settings.dampingThreshold

                    let lambda: CGFloat
                    if m < settings.dampingThreshold {
                        // Region of singularity: apply adaptive damping based on manipulability
                        let ratio = m / settings.dampingThreshold
                        lambda =
                            settings.singularityDampingFactor
                            * (1.0 - pow(ratio, 2))
                    } else {
                        lambda = 0.0  // No damping on flat surfaces
                    }

                    let dampingRatio =
                        (ds_cartesian * ds_cartesian)
                        / ((ds_cartesian * ds_cartesian) + pow(lambda, 2))
                    let newAm = prevDamped.Am + (target_dA * dampingRatio)

                    let thetaRad = newAm * .pi / 180.0
                    let newYm =
                        currRaw.matU * cos(thetaRad) - currRaw.matV
                        * sin(thetaRad)
                    let newZm =
                        currRaw.matU * sin(thetaRad) + currRaw.matV
                        * cos(thetaRad)
                    let baselineZ: CGFloat =
                        (stock.profile == .round)
                        ? (stock.od ?? 50.0) / 2.0
                        : (stock.odY ?? stock.od ?? 50.0) / 2.0

                    var dampedPt = currRaw
                    dampedPt.Am = newAm
                    dampedPt.Ym = newYm
                    dampedPt.Zm = newZm - baselineZ
                    dampedMachinePoints.append(dampedPt)
                } else {
                    dampedMachinePoints.append(currRaw)
                }
            }
        }

        var machinePoints: [MachinePoint] = []
        if !dampedMachinePoints.isEmpty {
            machinePoints.append(dampedMachinePoints[0])
            for i in 1..<dampedMachinePoints.count {
                let startMp = machinePoints.last!
                let endMp = dampedMachinePoints[i]
                func appendWithCompensation(
                    sMp: MachinePoint,
                    eMp: MachinePoint,
                    depth: Int = 0
                ) {
                    if settings.enableNonlinearErrorCompensation && depth < 10 {
                        let midU = (sMp.matU + eMp.matU) / 2.0
                        let midV = (sMp.matV + eMp.matV) / 2.0
                        let midAm = (sMp.Am + eMp.Am) / 2.0
                        let thetaRad = midAm * .pi / 180.0
                        let trueMidYm =
                            midU * cos(thetaRad) - midV * sin(thetaRad)
                        let baselineZ: CGFloat =
                            (stock.profile == .round)
                            ? (stock.od ?? 50.0) / 2.0
                            : (stock.odY ?? stock.od ?? 50.0) / 2.0
                        let trueMidZm =
                            (midU * sin(thetaRad) + midV * cos(thetaRad))
                            - baselineZ
                        let dev = sqrt(
                            pow(trueMidYm - (sMp.Ym + eMp.Ym) / 2.0, 2)
                                + pow(trueMidZm - (sMp.Zm + eMp.Zm) / 2.0, 2)
                        )
                        if dev > settings.nonlinearErrorTolerance {
                            var midPt = eMp
                            midPt.matX = (sMp.matX + eMp.matX) / 2.0
                            midPt.matU = midU
                            midPt.matV = midV
                            midPt.Am = midAm
                            midPt.Ym = trueMidYm
                            midPt.Zm = trueMidZm
                            midPt.Xm = (sMp.Xm + eMp.Xm) / 2.0
                            appendWithCompensation(
                                sMp: sMp,
                                eMp: midPt,
                                depth: depth + 1
                            )
                            appendWithCompensation(
                                sMp: midPt,
                                eMp: eMp,
                                depth: depth + 1
                            )
                            return
                        }
                    }
                    machinePoints.append(eMp)
                }
                appendWithCompensation(sMp: startMp, eMp: endMp)
            }
        }

        var segments: [TrajectorySegment] = []
        let aMaxX = settings.maxAccelX * 3600.0
        let aMaxY = settings.maxAccelY * 3600.0
        let aMaxZ = settings.maxAccelZ * 3600.0
        let aMaxA = settings.maxAccelA * 3600.0

        let jMaxX = settings.maxJerkX * 216000.0
        let jMaxY = settings.maxJerkY * 216000.0
        let jMaxZ = settings.maxJerkZ * 216000.0
        let jMaxA = settings.maxJerkA * 216000.0

        for i in 1..<machinePoints.count {
            let prev = machinePoints[i - 1]
            let curr = machinePoints[i]
            let dS = max(
                1e-6,
                sqrt(
                    pow(curr.matX - prev.matX, 2)
                        + pow(curr.matU - prev.matU, 2)
                        + pow(curr.matV - prev.matV, 2)
                )
            )
            let dXm = curr.Xm - prev.Xm
            let dYm = curr.Ym - prev.Ym
            let dZm = curr.Zm - prev.Zm
            let dAm = curr.Am - prev.Am
            let dMachine = sqrt(dXm * dXm + dYm * dYm + dZm * dZm + dAm * dAm)
            let aPath = min(
                abs(dXm) > 1e-6
                    ? aMaxX * dS / abs(dXm) : .greatestFiniteMagnitude,
                abs(dYm) > 1e-6
                    ? aMaxY * dS / abs(dYm) : .greatestFiniteMagnitude,
                abs(dZm) > 1e-6
                    ? aMaxZ * dS / abs(dZm) : .greatestFiniteMagnitude,
                abs(dAm) > 1e-6
                    ? aMaxA * dS / abs(dAm) : .greatestFiniteMagnitude
            )
            let jPath = min(
                abs(dXm) > 1e-6
                    ? jMaxX * dS / abs(dXm) : .greatestFiniteMagnitude,
                abs(dYm) > 1e-6
                    ? jMaxY * dS / abs(dYm) : .greatestFiniteMagnitude,
                abs(dZm) > 1e-6
                    ? jMaxZ * dS / abs(dZm) : .greatestFiniteMagnitude,
                abs(dAm) > 1e-6
                    ? jMaxA * dS / abs(dAm) : .greatestFiniteMagnitude
            )
            segments.append(
                TrajectorySegment(
                    dS: dS,
                    dMachine: dMachine,
                    dXm: dXm,
                    dYm: dYm,
                    dZm: dZm,
                    dAm: dAm,
                    aPath: aPath,
                    jPath: jPath
                )
            )
        }

        var vJunction = [CGFloat](
            repeating: settings.feedRate,
            count: machinePoints.count
        )
        if segments.count > 1 {
            for i in 1..<segments.count {
                let prev = segments[i - 1]
                let curr = segments[i]
                let dS_avg = (prev.dS + curr.dS) / 2.0
                if dS_avg < 1e-6 { continue }
                let drX = abs(curr.dXm / curr.dS - prev.dXm / prev.dS)
                let drY = abs(curr.dYm / curr.dS - prev.dYm / prev.dS)
                let drZ = abs(curr.dZm / curr.dS - prev.dZm / prev.dS)
                let drA = abs(curr.dAm / curr.dS - prev.dAm / prev.dS)
                vJunction[i] = min(
                    settings.feedRate,
                    min(
                        drX > 1e-6
                            ? sqrt(aMaxX * dS_avg / drX)
                            : .greatestFiniteMagnitude,
                        drY > 1e-6
                            ? sqrt(aMaxY * dS_avg / drY)
                            : .greatestFiniteMagnitude,
                        drZ > 1e-6
                            ? sqrt(aMaxZ * dS_avg / drZ)
                            : .greatestFiniteMagnitude,
                        drA > 1e-6
                            ? sqrt(aMaxA * dS_avg / drA)
                            : .greatestFiniteMagnitude
                    )
                )
            }
        }

        // --- S-Curve Velocity Profiling ---
        // Uses the S-curve distance formula: s = v_avg * (dv/a + a/j)
        // to find the maximum reachable velocity over each segment.

        func solveMaxV(v0: CGFloat, s: CGFloat, a: CGFloat, j: CGFloat)
            -> CGFloat
        {
            if s < 1e-6 { return v0 }
            // Case 1: reach a_max. Solve quadratic: j*v1^2 + a^2*v1 + (a^2*v0 - j*v0^2 - 2*s*a*j) = 0
            let b = a * a
            let c = a * a * v0 - j * v0 * v0 - 2.0 * s * a * j
            let disc = b * b - 4.0 * j * c
            if disc < 0 { return v0 + sqrt(2.0 * a * s) }  // Fallback to trapezoidal
            let v1_quad = (-b + sqrt(disc)) / (2.0 * j)

            // Case 2: don't reach a_max. s = (v0 + v1) * sqrt((v1 - v0)/j)
            // Approx v1 using trapezoidal then refine
            var v1 = v0 + sqrt(2.0 * min(a, sqrt(j * (v1_quad - v0 + 1.0))) * s)
            for _ in 0..<3 {
                let dv = max(0, v1 - v0)
                let t = 2.0 * sqrt(dv / j)
                let s_req = (v0 + v1) / 2.0 * t
                v1 = v1 * (s / max(s_req, 1e-6))
            }

            return max(v0, min(v1_quad, v1))
        }

        // 1. Forward pass (Jerk-limited)
        var vFwd = [CGFloat](repeating: 0.0, count: machinePoints.count)
        vFwd[0] = 0
        for i in 0..<segments.count {
            let seg = segments[i]
            let a = seg.aPath
            let j = seg.jPath
            vFwd[i + 1] = min(
                vJunction[i + 1],
                solveMaxV(v0: vFwd[i], s: seg.dS, a: a, j: j)
            )
        }

        // 2. Backward pass (Jerk-limited)
        var vFinal = [CGFloat](repeating: 0.0, count: machinePoints.count)
        vFinal[segments.count] = 0
        for i in stride(from: segments.count - 1, through: 0, by: -1) {
            let seg = segments[i]
            let a = seg.aPath
            let j = seg.jPath
            vFinal[i] = min(
                vFwd[i],
                solveMaxV(v0: vFinal[i + 1], s: seg.dS, a: a, j: j)
            )
        }
        for i in 0..<segments.count {
            if settings.useSimCNC {
                let vSafe = max((vFinal[i] + vFinal[i + 1]) / 2.0, 1.0)
                segments[i].finalF = min(
                    segments[i].dMachine / (segments[i].dS / vSafe),
                    settings.rapidRate
                )
            } else {
                segments[i].finalF = max(
                    min((vFinal[i] + vFinal[i + 1]) / 2.0, settings.feedRate),
                    1.0
                )
            }
        }

        var lines: [String] = []
        let typeStr = feature.type.rawValue.capitalized
        let directionStr =
            isInternal ? "CW (Physical CCW)" : "CCW (Physical CW)"
        lines.append(
            "; --- \(typeStr)  X=\(fmt(feature.xCenter + packStartX))mm  A=\(fmt(feature.aCenterDeg + rollOffset))° ---"
        )
        lines.append(
            "; TCP ADLS Active | Swirl Comp: \(directionStr) | Tangential OB | Comp: Offline (\(settings.enableKerfComp ? "Enabled" : "Disabled"))"
        )

        let pierceMp = machinePoints[0]
        let dynamicSafeZ =
            settings.enableDynamicSafeZ
            ? getDynamicSafeZ(stock: stock)
            : (pierceMp.Zm + settings.safeHeight)
        lines.append(
            "G0 Z\(fmtU(dynamicSafeZ))  ; retract to asymmetric safe Z envelope"
        )
        lines.append(
            "G0 X\(fmtU(pierceMp.Xm)) Y\(fmtU(pierceMp.Ym)) A\(fmt(pierceMp.Am)) ; rapid to pierce location"
        )
        lines.append(
            "G0 Z\(fmtU(pierceMp.Zm + settings.pierceHeight)) ; lower to pierce height"
        )
        lines.append("M3 S1                         ; torch on")

        var currentTHCState = true
        if settings.enableDynamicTHC {
            if pierceMp.isCorner {
                lines.append(
                    "#50 = #4061                  ; THC OFF (Corner Lock)"
                )
                lines.append(
                    "#4061 = 100                  ; THC OFF (Corner Lock)"
                )
                currentTHCState = false
            } else {
                lines.append(
                    "#4061 = #50                  ; THC ON (Flat Segment)"
                )
            }
        }

        for i in 1..<machinePoints.count {
            let curr = machinePoints[i]
            let seg = segments[i - 1]
            if settings.enableDynamicTHC {
                if curr.isCorner && currentTHCState {
                    lines.append(
                        "#50 = #4061"
                    )
                    lines.append("#4061 = 100; currentTHCState = false")
                } else if !curr.isCorner && !currentTHCState {
                    lines.append("#4061 = #50; currentTHCState = true")
                }
            }
            lines.append(
                "G1 X\(fmtU(curr.Xm)) Y\(fmtU(curr.Ym)) Z\(fmtU(curr.Zm + settings.cutHeight)) A\(fmt(curr.Am)) F\(fmtF(seg.finalF, segment: seg))"
            )
        }
        lines.append("M5; G0 Z\(fmtU(dynamicSafeZ))")
        return (lines, machinePoints.last!.Am)
    }

    private func getDynamicSafeZ(stock: StockInfo) -> CGFloat {
        if stock.profile == .round { return settings.safeHeight }
        let W = stock.odX ?? stock.od ?? 50.0
        let H = stock.odY ?? stock.od ?? 50.0
        let R = min(W, H) * 0.1
        return settings.safeHeight
            + (sqrt(pow(W / 2 - R, 2) + pow(H / 2 - R, 2)) + R - H / 2)
    }

    private func getProfilePoint(angleDeg: CGFloat, stock: StockInfo) -> (
        u: CGFloat, v: CGFloat, Nu: CGFloat, Nv: CGFloat
    ) {
        if stock.profile == .round {
            let r = (stock.od ?? max(stock.odX ?? 50, stock.odY ?? 50)) / 2.0
            let rad = angleDeg * .pi / 180.0
            return (r * cos(rad), r * sin(rad), cos(rad), sin(rad))
        } else {
            let W = stock.odX ?? stock.od ?? 50.0
            let H = stock.odY ?? stock.od ?? 50.0
            let R = min(W, H) * 0.1
            let w = W - 2 * R
            let h = H - 2 * R
            let rad = angleDeg * .pi / 180.0
            let cosPhi = cos(rad)
            let sinPhi = sin(rad)
            var bestT: CGFloat = .greatestFiniteMagnitude
            var bestU: CGFloat = 0
            var bestV: CGFloat = 0
            var bestNu: CGFloat = 0
            var bestNv: CGFloat = 0

            if cosPhi > 1e-6 {
                let t = (W / 2) / cosPhi
                if abs(t * sinPhi) <= h / 2 {
                    bestT = t
                    bestU = W / 2
                    bestV = t * sinPhi
                    bestNu = 1
                    bestNv = 0
                }
            }
            if cosPhi < -1e-6 {
                let t = (-W / 2) / cosPhi
                if abs(t * sinPhi) <= h / 2 && t < bestT {
                    bestT = t
                    bestU = -W / 2
                    bestV = t * sinPhi
                    bestNu = -1
                    bestNv = 0
                }
            }
            if sinPhi > 1e-6 {
                let t = (H / 2) / sinPhi
                if abs(t * cosPhi) <= w / 2 && t < bestT {
                    bestT = t
                    bestU = t * cosPhi
                    bestV = H / 2
                    bestNu = 0
                    bestNv = 1
                }
            }
            if sinPhi < -1e-6 {
                let t = (-H / 2) / sinPhi
                if abs(t * cosPhi) <= w / 2 && t < bestT {
                    bestT = t
                    bestU = t * cosPhi
                    bestV = -H / 2
                    bestNu = 0
                    bestNv = -1
                }
            }

            let centers: [(CGFloat, CGFloat)] = [
                (w / 2, h / 2), (-w / 2, h / 2), (-w / 2, -h / 2),
                (w / 2, -h / 2),
            ]
            for (cx, cy) in centers {
                let b = -2 * (cx * cosPhi + cy * sinPhi)
                let c = cx * cx + cy * cy - R * R
                let disc = b * b - 4 * c
                if disc >= 0 {
                    for t in [(-b - sqrt(disc)) / 2, (-b + sqrt(disc)) / 2] {
                        if t > 1e-6 && t < bestT {
                            let u = t * cosPhi
                            let v = t * sinPhi
                            if ((cx > 0) ? (u >= cx - 1e-4) : (u <= cx + 1e-4))
                                && ((cy > 0)
                                    ? (v >= cy - 1e-4) : (v <= cy + 1e-4))
                            {
                                bestT = t
                                bestU = u
                                bestV = v
                                let len = sqrt(pow(u - cx, 2) + pow(v - cy, 2))
                                bestNu = (u - cx) / len
                                bestNv = (v - cy) / len
                            }
                        }
                    }
                }
            }
            return bestT == .greatestFiniteMagnitude
                ? (0, H / 2, 0, 1) : (bestU, bestV, bestNu, bestNv)
        }
    }

    private func convertToMachine(pt: ToolpathPoint, stock: StockInfo)
        -> MachinePoint
    {
        let profile = getProfilePoint(angleDeg: pt.a, stock: stock)
        let thetaRad = atan2(profile.Nu, profile.Nv)
        let Ym = profile.u * cos(thetaRad) - profile.v * sin(thetaRad)
        let Zm = profile.u * sin(thetaRad) + profile.v * cos(thetaRad)
        let baselineZ =
            (stock.profile == .round)
            ? (stock.od ?? max(stock.odX ?? 50, stock.odY ?? 50)) / 2.0
            : (stock.odY ?? stock.od ?? 50.0) / 2.0
        let isCorner =
            stock.profile == .round
            ? false : !(abs(profile.Nu) > 0.999 || abs(profile.Nv) > 0.999)
        return MachinePoint(
            Xm: pt.x,
            Ym: Ym,
            Zm: Zm - baselineZ,
            Am: thetaRad * 180.0 / .pi,
            matX: pt.x,
            matU: profile.u,
            matV: profile.v,
            isCorner: isCorner
        )
    }

    private func fmt(_ val: CGFloat) -> String { String(format: "%.3f", val) }
    private func fmtU(_ val: CGFloat) -> String {
        settings.units == .inches
            ? String(format: "%.4f", val / 25.4) : String(format: "%.3f", val)
    }
    private func fmtF(_ val: CGFloat, segment: TrajectorySegment? = nil)
        -> String
    {
        var rate = val
        if settings.units == .inches {
            if settings.useSimCNC, let seg = segment, seg.dMachine > 1e-9 {
                rate =
                    val
                    * sqrt(
                        pow(seg.dXm / 25.4, 2) + pow(seg.dYm / 25.4, 2)
                            + pow(seg.dZm / 25.4, 2) + pow(seg.dAm, 2)
                    ) / seg.dMachine
            } else {
                rate = val / 25.4
            }
        }
        return String(format: "%.3f", rate)
    }

    private var unitLabel: String { settings.units == .inches ? "in" : "mm" }
    private var unitModeWord: String {
        settings.units == .inches ? "G20" : "G21"
    }
    private var unitModeComment: String {
        settings.units == .inches ? "inch mode" : "metric mode"
    }
    private func sortFeatures(_ features: [SurfaceFeature]) -> [SurfaceFeature]
    {
        return features.sorted { a, b in
            func priority(_ t: SurfaceFeatureType) -> Int {
                switch t {
                case .endCut: return 0
                case .hole, .cutout, .notch: return 1
                case .startCut: return 2
                }
            }
            return priority(a.type) != priority(b.type)
                ? priority(a.type) < priority(b.type) : a.xCenter > b.xCenter
        }
    }

    private func generateHeader(stock: StockInfo) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy, HH:mm"
        var header = [
            "%", "(PROGRAM NAME: cylinder)",
            "(GENERATED: \(formatter.string(from: Date())))",
            "(STOCK: \(stock.profile.rawValue))",
        ]
        header.append(
            stock.profile == .round
                ? "(OD: \(fmtU(stock.od ?? 0))\(unitLabel))"
                : "(OD: \(fmtU(stock.odX ?? 0))\(unitLabel) x \(fmtU(stock.odY ?? 0))\(unitLabel))"
        )
        header.append("(LENGTH: \(fmtU(stock.length))\(unitLabel))")
        return header
    }

    private func generateStartupSequence(
        totalLength: CGFloat,
        stock: StockInfo,
        packMode: Bool = false,
        count: Int = 1
    ) -> [String] {
        let safeZ =
            settings.enableDynamicSafeZ
            ? getDynamicSafeZ(stock: stock) : settings.safeHeight
        return [
            "\(unitModeWord) ; \(unitModeComment)",
            "G90 ; absolute positioning", "G40 ; cancel cutter comp",
            "G49 ; cancel tool length offset",
            "G92 X\(fmtU(totalLength)) Y0 Z0 A0 ; set current position", "",
            "G0 Z\(fmtU(safeZ)) ; move to safe height", "M5 ; torch off", "",
            packMode
                ? "; === Cutting Pattern (R-to-L, \(count) piece\(count == 1 ? "" : "s")) ==="
                : "; === Cutting Pattern ===",
        ]
    }

    private func generateEndSequence(stock: StockInfo?) -> [String] {
        let safeZ =
            (settings.enableDynamicSafeZ && stock != nil)
            ? getDynamicSafeZ(stock: stock!) : settings.safeHeight
        return [
            "; === Program End ===", "M5", "G0 Z\(fmtU(safeZ))", "G0 X0 Y0 A0",
            "M30", "%",
        ]
    }
}
