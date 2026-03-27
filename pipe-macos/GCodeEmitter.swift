import Foundation

// MARK: - GCode Emitter

/// Serializes machine points and velocity-profiled segments into G-code strings.
///
/// Handles all controller-specific output: SimCNC variable syntax, THC state machine,
/// M3/M5 torch control, G0/G1 motion blocks, and program structure (header/startup/end).
struct GCodeEmitter {
    let settings: GCodeSettings

    // MARK: - Feature Emission

    func emitFeature(
        toolpathFeature: ToolpathFeature,
        stock: StockInfo,
        packStartX: CGFloat,
        rollOffset: CGFloat
    ) -> [String] {
        let machinePoints = toolpathFeature.machinePoints
        let segments = toolpathFeature.segments
        let plannedFeature = toolpathFeature.source
        let feature = plannedFeature.source
        let isInternal = plannedFeature.plannedPath.isInternal

        guard !machinePoints.isEmpty else { return [] }

        var lines: [String] = []
        let typeStr = feature.type.rawValue.capitalized
        let directionStr = isInternal ? "CW (Physical CCW)" : "CCW (Physical CW)"
        lines.append("; --- \(typeStr)  X=\(fmt(feature.xCenter + packStartX))mm  A=\(fmt(feature.aCenterDeg + rollOffset))° ---")
        lines.append("; TCP ADLS Active | Swirl Comp: \(directionStr) | Tangential OB | Comp: Offline (\(settings.enableKerfComp ? "Enabled" : "Disabled"))")

        let pierceMp = machinePoints[0]
        let dynamicSafeZ = settings.enableDynamicSafeZ
            ? getDynamicSafeZ(stock: stock)
            : (pierceMp.Zm + settings.safeHeight)

        lines.append("G0 Z\(fmtU(dynamicSafeZ))  ; retract to asymmetric safe Z envelope")
        lines.append("G0 X\(fmtU(pierceMp.Xm)) Y\(fmtU(pierceMp.Ym)) A\(fmt(pierceMp.Am)) ; rapid to pierce location")
        lines.append("G0 Z\(fmtU(pierceMp.Zm + settings.pierceHeight)) ; lower to pierce height")
        lines.append("M3 S1                         ; torch on")

        var currentTHCState = true
        if settings.enableDynamicTHC {
            if pierceMp.isCorner {
                lines.append("#50 = #4061                  ; THC OFF (Corner Lock)")
                lines.append("#4061 = 100                  ; THC OFF (Corner Lock)")
                currentTHCState = false
            } else {
                lines.append("#4061 = #50                  ; THC ON (Flat Segment)")
            }
        }

        // Build a lookup from arc-start index → ArcHint so the loop can
        // collapse qualifying polyline spans into a single G02/G03.
        var arcByStart: [Int: ArcHint] = [:]
        for hint in toolpathFeature.arcHints {
            arcByStart[hint.startMachineIndex] = hint
        }

        var i = 1
        while i < machinePoints.count {
            let curr = machinePoints[i]
            let seg  = segments[i - 1]

            if settings.enableDynamicTHC {
                if curr.isCorner && currentTHCState {
                    lines.append("#50 = #4061")
                    lines.append("#4061 = 100; currentTHCState = false")
                    currentTHCState = false
                } else if !curr.isCorner && !currentTHCState {
                    lines.append("#4061 = #50; currentTHCState = true")
                    currentTHCState = true
                }
            }

            if let hint = arcByStart[i] {
                            let endMP = machinePoints[hint.endMachineIndex]
                            let arcFeed = hint.startMachineIndex < segments.count
                                ? segments[hint.startMachineIndex].finalF
                                : settings.feedRate
                            let gWord = hint.isCCW ? "G3" : "G2"
                            
                            // BUG FIX: Calculate absolute radius to replace I/J offsets.
                            // This eliminates the strict geometry fault in SimCNC caused by G-Code formatting truncation.
                            // Works universally for XY arcs (k=0) and YZ arcs (i=0).
                            let radius = sqrt(hint.iOffset * hint.iOffset + hint.jOffset * hint.jOffset + hint.kOffset * hint.kOffset)
                            
                            lines.append("\(hint.plane.rawValue)                ; select arc plane")
                            lines.append(
                                "\(gWord) X\(fmtU(endMP.Xm)) Y\(fmtU(endMP.Ym))"
                                + " Z\(fmtU(endMP.Zm + settings.cutHeight))"
                                + " R\(fmtU(radius))"
                                + " A\(fmt(endMP.Am)) F\(fmtF(arcFeed))"
                            )
                            lines.append("G17                ; restore XY plane")
                            i = hint.endMachineIndex + 1
                            continue
                        }

            lines.append("G1 X\(fmtU(curr.Xm)) Y\(fmtU(curr.Ym)) Z\(fmtU(curr.Zm + settings.cutHeight)) A\(fmt(curr.Am)) F\(fmtF(seg.finalF, segment: seg))")
            i += 1
        }
        lines.append("M5; G0 Z\(fmtU(dynamicSafeZ))")

        return lines
    }

    // MARK: - Program Structure

    func emitHeader(stock: StockInfo) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy, HH:mm"
        var header = [
            "%", "(PROGRAM NAME: cylinder)",
            "(GENERATED: \(formatter.string(from: Date())))",
            "(STOCK: \(stock.profile.rawValue))",
        ]
        header.append(stock.profile == .round
            ? "(OD: \(fmtU(stock.od ?? 0))\(unitLabel))"
            : "(OD: \(fmtU(stock.odX ?? 0))\(unitLabel) x \(fmtU(stock.odY ?? 0))\(unitLabel))")
        header.append("(LENGTH: \(fmtU(stock.length))\(unitLabel))")
        return header
    }

    func emitStartup(
        totalLength: CGFloat,
        stock: StockInfo,
        packMode: Bool = false,
        count: Int = 1
    ) -> [String] {
        let safeZ = settings.enableDynamicSafeZ ? getDynamicSafeZ(stock: stock) : settings.safeHeight
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

    func emitEnd(stock: StockInfo?) -> [String] {
        let safeZ = (settings.enableDynamicSafeZ && stock != nil)
            ? getDynamicSafeZ(stock: stock!) : settings.safeHeight
        return ["; === Program End ===", "M5", "G0 Z\(fmtU(safeZ))", "G0 X0 Y0 A0", "M30", "%"]
    }

    // MARK: - Geometry Helpers

    /// Computes the asymmetric safe-Z clearance height for rectangular HSS.
    /// WHY: The torch must clear the diagonal corner of the cross-section during rapids.
    /// For round stock the standard safeHeight is always sufficient.
    func getDynamicSafeZ(stock: StockInfo) -> CGFloat {
        if stock.profile == .round { return settings.safeHeight }
        let W = stock.odX ?? stock.od ?? 50.0
        let H = stock.odY ?? stock.od ?? 50.0
        let R = min(W, H) * 0.1
        return settings.safeHeight + (sqrt(pow(W / 2 - R, 2) + pow(H / 2 - R, 2)) + R - H / 2)
    }

    // MARK: - Formatting

    private func fmt(_ val: CGFloat) -> String { String(format: "%.3f", val) }

    private func fmtU(_ val: CGFloat) -> String {
        settings.units == .inches
            ? String(format: "%.4f", val / 25.4)
            : String(format: "%.3f", val)
    }

    private func fmtF(_ val: CGFloat, segment: TrajectorySegment? = nil) -> String {
        var rate = val
        if settings.units == .inches {
            if settings.useSimCNC, let seg = segment, seg.dMachine > 1e-9 {
                rate = val * sqrt(
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
    private var unitModeWord: String { settings.units == .inches ? "G20" : "G21" }
    private var unitModeComment: String { settings.units == .inches ? "inch mode" : "metric mode" }
}
