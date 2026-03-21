import Foundation
import SceneKit

// MARK: - Pack Entry
struct PackEntry {
    let shape: SelectedShape
    /// X coordinate of the piece's low-X end in pack space (mm).
    let packStartX: CGFloat
    /// Degrees to add to all A angles so that A=0 aligns with the roll-corrected "up" face.
    let rollOffset: CGFloat
    /// X coordinate of the piece's high-X end in pack space (mm).
    var packEndX: CGFloat { packStartX + (shape.stockInfo?.length ?? 0) }
}

// MARK: - GCode Generation Settings
struct GCodeSettings {
    var feedRate: CGFloat = 1000.0
    var rapidRate: CGFloat = 3000.0
    var safeHeight: CGFloat = 25.0
    var cutHeight: CGFloat = 1.5
    var kerfWidth: CGFloat = 2.0
    var enableKerfComp: Bool = true
    var leadInDistance: CGFloat = 5.0
    var overburnDegrees: CGFloat = 10.0  // Exact degrees to overburn
    var useSimCNC: Bool = true
}

// MARK: - GCode Generator
class GCodeGenerator {
    var settings = GCodeSettings()
    
    // MARK: - Single Part Generation
    func generateGCode(for stock: StockInfo, rollOffset: CGFloat = 0.0) -> String {
        var gcode: [String] = []
        gcode.append(contentsOf: generateHeader(stock: stock))
        
        // Pass the total length to the startup sequence so it sets G92 correctly
        gcode.append(contentsOf: generateStartupSequence(totalLength: stock.length))
        
        // Features are sorted Right-to-Left (Outermost to Chuck)
        let sortedFeatures = sortFeatures(stock.features)
        for feature in sortedFeatures {
            gcode.append(contentsOf: generateUniversalToolpath(feature: feature, stock: stock, rollOffset: rollOffset))
            gcode.append("")
        }
        
        gcode.append(contentsOf: generateEndSequence())
        return gcode.joined(separator: "\n")
    }
    
    /// Replaces all legacy hardcoded shapes. Traces the OCCT B-Rep directly.
    private func generateUniversalToolpath(feature: SurfaceFeature, stock: StockInfo, rollOffset: CGFloat = 0) -> [String] {
        var gcode: [String] = []
        guard let rawPath = feature.path, rawPath.count > 1 else { return gcode }

        // Apply roll offset so A=0 aligns with the physical "up" face
        let path = rawPath.map { ToolpathPoint(x: $0.x, a: $0.a + rollOffset) }

        let effRadius = (stock.od ?? max(stock.odX ?? 50, stock.odY ?? 50)) / 2.0
        let isInternal = (feature.type == .hole || feature.type == .cutout)

        let firstPt = path[0]
        let secondPt = path[1]

        let dx = secondPt.x - firstPt.x
        let da_mm = (secondPt.a - firstPt.a) * .pi / 180.0 * effRadius
        let len = sqrt(dx*dx + da_mm*da_mm)

        var pierceX = firstPt.x - settings.leadInDistance
        var pierceA = firstPt.a

        if len > 0.001 {
            let dirX = dx / len
            let dirA = da_mm / len
            let normX = isInternal ? -dirA : dirA
            let normA_mm = isInternal ? dirX : -dirX
            pierceX = firstPt.x + normX * settings.leadInDistance
            pierceA = firstPt.a + (normA_mm / effRadius * 180.0 / .pi)
        }

        gcode.append("; --- Feature: \(feature.type.rawValue.capitalized) ---")
        gcode.append("; Center: X=\(String(format: "%.1f", feature.xCenter)), A=\(String(format: "%.1f", feature.aCenterDeg + rollOffset))")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        gcode.append("G0 X\(String(format: "%.3f", pierceX)) A\(String(format: "%.3f", pierceA))")
        gcode.append("M3 S1                         ; torch on")
        gcode.append("G1 X\(String(format: "%.3f", firstPt.x)) A\(String(format: "%.3f", firstPt.a)) F\(settings.feedRate)")

        for pt in path {
            gcode.append("G1 X\(String(format: "%.3f", pt.x)) A\(String(format: "%.3f", pt.a))")
        }

        // Overburn: just overburnDegrees past the closing point — not multiple path points
        if feature.type == .startCut || feature.type == .endCut {
            let lastPt = path.last!
            gcode.append("; Overburn \(String(format: "%.0f", settings.overburnDegrees))°")
            gcode.append("G1 X\(String(format: "%.3f", lastPt.x)) A\(String(format: "%.3f", lastPt.a + settings.overburnDegrees))")
        } else if (feature.type == .hole || feature.type == .cutout) && path.count > 1 {
            let dir: CGFloat = (path[1].a - path[0].a) >= 0 ? 1 : -1
            let lastPt = path.last!
            gcode.append("; Overburn tab")
            gcode.append("G1 X\(String(format: "%.3f", lastPt.x)) A\(String(format: "%.3f", lastPt.a + dir * settings.overburnDegrees))")
        }

        gcode.append("M5                            ; torch off")
        return gcode
    }

    // MARK: - Pack G-code Generation

    /// Generate a single G-code program for all pieces in the pack, cut right-to-left.
    /// A-axis is continuous across pieces — no reset between pieces.
    /// Lead-ins are placed in scrap zones only — never in remaining workpiece material.
    func generatePackGCode(entries: [PackEntry]) -> String {
        guard !entries.isEmpty, let refStock = entries[0].shape.stockInfo else {
            return "; Empty pack — no G-code generated"
        }

        let totalLength = entries.max(by: { $0.packEndX < $1.packEndX })?.packEndX ?? 0
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy, HH:mm"

        var lines: [String] = [
            "%",
            "(PACK G-CODE  —  \(entries.count) PIECE\(entries.count == 1 ? "" : "S"))",
            "(GENERATED: \(formatter.string(from: Date())))",
            refStock.profile == .round
                ? "(STOCK: \(refStock.profile.rawValue)  OD \(String(format: "%.1f", refStock.od ?? 0))mm)"
                : "(STOCK: \(refStock.profile.rawValue)  \(String(format: "%.1f", refStock.odX ?? 0))×\(String(format: "%.1f", refStock.odY ?? 0))mm)",
            "(TOTAL STOCK LENGTH: \(String(format: "%.1f", totalLength))mm)",
            "",
            "G21             ; metric mode",
            "G90             ; absolute positioning",
            "G40             ; cancel cutter comp",
            "G49             ; cancel tool length offset",
            "G92 X\(String(format: "%.3f", totalLength)) Y0 Z0 A0 ; set current position as right-most free end",
            "",
            "G0 Z\(String(format: "%.1f", settings.safeHeight))     ; move to safe height",
            "M5              ; torch off (ensure)",
            "",
            "; === Cutting Pattern (free-end to chuck, \(entries.count) piece\(entries.count == 1 ? "" : "s")) ===",
        ]

        // Process pieces right-to-left (highest packStartX first = longest piece first)
        let ordered = entries.sorted { $0.packStartX > $1.packStartX }

        // Thread currentA across ALL features in the program to minimise A-axis travel
        var currentA: CGFloat = 0

        for (pieceIdx, entry) in ordered.enumerated() {
            guard let stock = entry.shape.stockInfo else { continue }
            lines += [
                "",
                "; ┌── Piece \(pieceIdx + 1)/\(ordered.count)  "
                    + "X=\(String(format: "%.1f", entry.packStartX))–\(String(format: "%.1f", entry.packEndX))mm  "
                    + "L=\(String(format: "%.1f", stock.length))mm  "
                    + "\(stock.features.count) feature\(stock.features.count == 1 ? "" : "s") ──",
            ]

            // Cut order per piece: trim far end first, then holes/cutouts, sever from remaining
            // stock last — keeps the piece supported until all features are done.
            let sortedFeatures = stock.features.sorted { a, b in
                func priority(_ t: SurfaceFeatureType) -> Int {
                    switch t {
                    case .endCut:                return 0  // far end (free-end side) — trim first
                    case .hole, .cutout, .notch: return 1  // interior features
                    case .startCut:              return 2  // chuck-end sever — last, so piece doesn't drop early
                    }
                }
                let pA = priority(a.type), pB = priority(b.type)
                return pA != pB ? pA < pB : a.xCenter > b.xCenter  // same priority → higher X first
            }

            for feature in sortedFeatures {
                let (toolpath, finalA) = generatePackFeatureToolpath(
                    feature: feature, stock: stock,
                    packStartX: entry.packStartX, packEndX: entry.packEndX,
                    rollOffset: entry.rollOffset, currentA: currentA
                )
                lines += toolpath
                lines.append("")
                currentA = finalA
            }
        }

        lines += [
            "; === Program End ===",
            "M5              ; torch off (redundant safety)",
            "G0 Z\(String(format: "%.1f", settings.safeHeight))  ; retract to safe height",
            "G0 X0 A0        ; return to home",
            "M30             ; end of program",
            "%",
        ]
        return lines.joined(separator: "\n")
    }

    // MARK: - Pack Feature Toolpath

    /// Returns (toolpath lines, finalA) where finalA is the A position after this feature
    /// (including overburn), so the next feature can minimise A-axis travel.
    private func generatePackFeatureToolpath(
        feature: SurfaceFeature,
        stock: StockInfo,
        packStartX: CGFloat,
        packEndX: CGFloat,
        rollOffset: CGFloat,
        currentA: CGFloat
    ) -> ([String], CGFloat) {
        guard let localPath = feature.path, localPath.count > 1 else { return ([], currentA) }

        let effRadius = (stock.od ?? max(stock.odX ?? 50, stock.odY ?? 50)) / 2.0

        // Shift path to pack space and apply roll offset
        let packPath = localPath.map { ToolpathPoint(x: $0.x + packStartX, a: $0.a + rollOffset) }
        let firstPt  = packPath[0]

        // Raw pierce point (before A-axis shift)
        let rawPierceA: CGFloat
        let pierceX: CGFloat

        switch feature.type {
        case .startCut:
            pierceX    = packStartX - settings.leadInDistance
            rawPierceA = firstPt.a
        case .endCut:
            pierceX    = packEndX + settings.leadInDistance
            rawPierceA = firstPt.a
        case .hole, .cutout:
            // Pierce at centroid — always inside the removed pocket (hull-safe)
            pierceX    = feature.xCenter + packStartX
            rawPierceA = feature.aCenterDeg + rollOffset
        case .notch:
            pierceX    = feature.xCenter < stock.length / 2 ? packStartX - settings.leadInDistance
                                                              : packEndX  + settings.leadInDistance
            rawPierceA = firstPt.a
        }

        // Shift everything by the nearest multiple of 360° to minimise A-axis travel
        let shift  = round((currentA - rawPierceA) / 360.0) * 360.0
        let pierceA = rawPierceA + shift
        let adjPath = packPath.map { ToolpathPoint(x: $0.x, a: $0.a + shift) }

        let packXLabel = String(format: "%.1f", feature.xCenter + packStartX)
        let aLabel     = String(format: "%.1f", feature.aCenterDeg + rollOffset)

        var lines: [String] = [
            "; --- \(feature.type.rawValue.capitalized)  packX=\(packXLabel)mm  A=\(aLabel)° ---",
            "G0 Z\(String(format: "%.1f", settings.safeHeight))",
            "G0 X\(String(format: "%.3f", pierceX)) A\(String(format: "%.3f", pierceA))",
            "M3 S1                         ; torch on",
            "G1 X\(String(format: "%.3f", adjPath[0].x)) A\(String(format: "%.3f", adjPath[0].a)) F\(settings.feedRate)",
        ]

        for pt in adjPath {
            lines.append("G1 X\(String(format: "%.3f", pt.x)) A\(String(format: "%.3f", pt.a))")
        }

        // Overburn: exactly overburnDegrees past the closing point
        var finalA = adjPath.last!.a
        if feature.type == .startCut || feature.type == .endCut {
            let overburnA = finalA + settings.overburnDegrees
            lines.append("; Overburn \(String(format: "%.0f", settings.overburnDegrees))°")
            lines.append("G1 X\(String(format: "%.3f", adjPath.last!.x)) A\(String(format: "%.3f", overburnA))")
            finalA = overburnA
        } else if (feature.type == .hole || feature.type == .cutout) && adjPath.count > 1 {
            let dir: CGFloat = (adjPath[1].a - adjPath[0].a) >= 0 ? 1 : -1
            let overburnA = finalA + dir * settings.overburnDegrees
            lines.append("; Overburn tab")
            lines.append("G1 X\(String(format: "%.3f", adjPath.last!.x)) A\(String(format: "%.3f", overburnA))")
            finalA = overburnA
        }

        lines.append("M5                            ; torch off")
        return (lines, finalA)
    }

    // MARK: - Path Optimization Helpers

    private func optimizePathStart(path: [ToolpathPoint], targetA: CGFloat) -> [ToolpathPoint] {
        guard path.count > 1 else { return path }
        
        // Wrap to [-180, 180)
        let wrappedPoints = path.dropLast().map { pt -> ToolpathPoint in
            var a = pt.a.truncatingRemainder(dividingBy: 360.0)
            if a < -180.0 { a += 360.0 }
            if a >= 180.0 { a -= 360.0 }
            return ToolpathPoint(x: pt.x, a: a)
        }
        
        var bestIdx = 0
        var minDiff = CGFloat.greatestFiniteMagnitude
        for (i, pt) in wrappedPoints.enumerated() {
            var diff = abs(pt.a - targetA).truncatingRemainder(dividingBy: 360.0)
            if diff > 180.0 { diff = 360.0 - diff }
            if diff < minDiff {
                minDiff = diff
                bestIdx = i
            }
        }
        
        let reordered = Array(wrappedPoints[bestIdx...]) + Array(wrappedPoints[..<bestIdx])
        
        // Re-unwrap
        var unwrapped: [ToolpathPoint] = [reordered[0]]
        for i in 1..<reordered.count {
            var currentA = reordered[i].a
            let prevA = unwrapped.last!.a
            while currentA - prevA > 180.0 { currentA -= 360.0 }
            while currentA - prevA < -180.0 { currentA += 360.0 }
            unwrapped.append(ToolpathPoint(x: reordered[i].x, a: currentA))
        }
        
        // Close the loop
        if let first = unwrapped.first {
            let lastA = unwrapped.last!.a
            var currentA = first.a
            while currentA - lastA > 180.0 { currentA -= 360.0 }
            while currentA - lastA < -180.0 { currentA += 360.0 }
            unwrapped.append(ToolpathPoint(x: first.x, a: currentA))
        }
        
        return unwrapped
    }
    
    private func unwrapPathNear(path: [ToolpathPoint], targetA: CGFloat) -> [ToolpathPoint] {
        guard path.count > 0 else { return path }
        var unwrapped: [ToolpathPoint] = []
        
        var startA = path[0].a.truncatingRemainder(dividingBy: 360.0)
        if startA < -180.0 { startA += 360.0 }
        if startA >= 180.0 { startA -= 360.0 }
        
        while startA - targetA > 180.0 { startA -= 360.0 }
        while startA - targetA < -180.0 { startA += 360.0 }
        
        unwrapped.append(ToolpathPoint(x: path[0].x, a: startA))
        
        for i in 1..<path.count {
            var currentA = path[i].a
            let prevA = unwrapped.last!.a
            while currentA - prevA > 180.0 { currentA -= 360.0 }
            while currentA - prevA < -180.0 { currentA += 360.0 }
            unwrapped.append(ToolpathPoint(x: path[i].x, a: currentA))
        }
        return unwrapped
    }

    // MARK: - Feature Sorting (Right-to-Left / Outside-In)
    private func sortFeatures(_ features: [SurfaceFeature]) -> [SurfaceFeature] {
        return features.sorted { a, b in
            func priority(_ t: SurfaceFeatureType) -> Int {
                switch t {
                case .endCut: return 0                // 1. Far end (trimming / squaring)
                case .hole, .cutout, .notch: return 1 // 2. Middle features
                case .startCut: return 2              // 3. Near end (severing from chuck)
                }
            }
            let pA = priority(a.type), pB = priority(b.type)
            // If priorities match, sort descending by X (highest X to lowest X)
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
            header.append("(OD: \(String(format: "%.1f", stock.od ?? 0))mm)")
        } else {
            header.append("(OD: \(String(format: "%.1f", stock.odX ?? 0))mm x \(String(format: "%.1f", stock.odY ?? 0))mm)")
        }
        
        header.append("(LENGTH: \(String(format: "%.1f", stock.length))mm)")
        return header
    }

    // NEW: Accepts totalLength to set the right-most zero point
    private func generateStartupSequence(totalLength: CGFloat, packMode: Bool = false, count: Int = 1) -> [String] {
        return [
            "G21             ; metric mode",
            "G90             ; absolute positioning",
            "G40             ; cancel cutter comp",
            "G49             ; cancel tool length offset",
            "G92 X\(String(format: "%.3f", totalLength)) Y0 Z0 A0 ; set current position as right-most free end",
            "",
            "G0 Z\(String(format: "%.1f", settings.safeHeight))     ; move to safe height",
            "M5              ; torch off (ensure)",
            "",
            packMode ? "; === Cutting Pattern (right-to-left, \(count) piece\(count == 1 ? "" : "s")) ===" : "; === Cutting Pattern ==="
        ]
    }

    private func generateEndSequence() -> [String] {
        return [
            "; === Program End ===",
            "M5              ; torch off (redundant safety)",
            "G0 Z\(String(format: "%.1f", settings.safeHeight))  ; retract to safe height",
            "G0 X0 A0        ; return to home",
            "M30             ; end of program",
            "%"
        ]
    }
}
