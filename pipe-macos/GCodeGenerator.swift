import Foundation
import SceneKit

// MARK: - Pack Entry
struct PackEntry {
    let shape: SelectedShape
    let packStartX: CGFloat
    var rollOffset: CGFloat = 0.0 // Degrees to shift A axis to align with top dead center
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
            gcode.append(contentsOf: generateFeatureToolpath(
                feature: feature, stock: stock,
                packStartX: 0.0, packEndX: stock.length, rollOffset: rollOffset
            ))
            gcode.append("")
        }
        
        gcode.append(contentsOf: generateEndSequence())
        return gcode.joined(separator: "\n")
    }
    
    // MARK: - Pack Generation
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
            ""
        ]
        
        // Pass the total pack length to the startup sequence
        lines.append(contentsOf: generateStartupSequence(totalLength: totalLength, packMode: true, count: entries.count))

        // Process pieces Right-to-Left (highest X first)
        let ordered = entries.sorted { $0.packStartX > $1.packStartX }
        for (pieceIdx, entry) in ordered.enumerated() {
            guard let stock = entry.shape.stockInfo else { continue }
            lines += [
                "",
                "; ┌── Piece \(pieceIdx + 1)/\(ordered.count)  "
                    + "X=\(String(format: "%.1f", entry.packStartX))–\(String(format: "%.1f", entry.packEndX))mm  "
                    + "L=\(String(format: "%.1f", stock.length))mm  "
                    + "\(stock.features.count) feature\(stock.features.count == 1 ? "" : "s") ──",
            ]

            // Within each piece, process features Right-to-Left
            let sortedFeatures = sortFeatures(stock.features)
            for feature in sortedFeatures {
                lines += generateFeatureToolpath(
                    feature: feature, stock: stock,
                    packStartX: entry.packStartX, packEndX: entry.packEndX, rollOffset: entry.rollOffset
                )
                lines.append("")
            }
        }

        lines.append(contentsOf: generateEndSequence())
        return lines.joined(separator: "\n")
    }

    // MARK: - Core Feature Toolpath
    private func generateFeatureToolpath(
        feature: SurfaceFeature, stock: StockInfo,
        packStartX: CGFloat, packEndX: CGFloat, rollOffset: CGFloat
    ) -> [String] {
        guard let localPath = feature.path, localPath.count > 1 else { return [] }

        let effRadius = (stock.od ?? max(stock.odX ?? 50, stock.odY ?? 50)) / 2.0
        let isClosed = (feature.type == .startCut || feature.type == .endCut || feature.type == .hole || feature.type == .cutout)

        // 1. Apply roll offset and return to top dead center (A=0)
        var shiftedPath = localPath.map { ToolpathPoint(x: $0.x, a: $0.a + rollOffset) }
        
        if isClosed {
            shiftedPath = optimizePathStart(path: shiftedPath, targetA: 0.0)
        } else {
            shiftedPath = unwrapPathNear(path: shiftedPath, targetA: 0.0)
        }

        let packPath = shiftedPath.map { ToolpathPoint(x: $0.x + packStartX, a: $0.a) }
        let firstPt = packPath[0]

        // 2. Scrap-safe lead-ins
        let pierceX: CGFloat
        let pierceA: CGFloat

        switch feature.type {
        case .startCut:
            // Piercing from the left (chuck side gap)
            pierceX = packStartX - settings.leadInDistance
            pierceA = firstPt.a
        case .endCut:
            // Piercing from the right (free end gap)
            pierceX = packEndX + settings.leadInDistance
            pierceA = firstPt.a
        case .hole, .cutout:
            // Center of pocket
            pierceX = feature.xCenter + packStartX
            pierceA = feature.aCenterDeg + rollOffset
        case .notch:
            if feature.xCenter < stock.length / 2.0 {
                pierceX = packStartX - settings.leadInDistance
            } else {
                pierceX = packEndX + settings.leadInDistance
            }
            pierceA = firstPt.a
        }

        var lines: [String] = [
            "; --- \(feature.type.rawValue.capitalized)  packX=\(String(format: "%.1f", feature.xCenter + packStartX))mm ---",
            "G0 Z\(String(format: "%.1f", settings.safeHeight))",
            "G0 X\(String(format: "%.3f", pierceX)) A\(String(format: "%.3f", pierceA))",
            "M3 S1                         ; torch on",
            "G1 X\(String(format: "%.3f", firstPt.x)) A\(String(format: "%.3f", firstPt.a)) F\(settings.feedRate)",
        ]

        // Trace boundary
        for pt in packPath {
            lines.append("G1 X\(String(format: "%.3f", pt.x)) A\(String(format: "%.3f", pt.a))")
        }

        // 3. Interpolated Overburn tab
        if isClosed && packPath.count > 2 {
            lines.append("; Overburn tab (\(settings.overburnDegrees) deg)")
            var travel: CGFloat = 0
            
            for i in 1..<packPath.count {
                let pt1 = packPath[i-1]
                let pt2 = packPath[i]
                let segA = abs(pt2.a - pt1.a)
                
                if travel + segA >= settings.overburnDegrees {
                    // Interpolate the exact cut point
                    let needed = settings.overburnDegrees - travel
                    let ratio = needed / segA
                    let overburnX = pt1.x + (pt2.x - pt1.x) * ratio
                    let overburnA = pt1.a + (pt2.a - pt1.a) * ratio
                    
                    let totalSweep = packPath.last!.a - packPath.first!.a
                    var finalA = overburnA
                    if abs(totalSweep) > 350.0 {
                        finalA += totalSweep > 0 ? 360.0 : -360.0
                    }
                    
                    lines.append("G1 X\(String(format: "%.3f", overburnX)) A\(String(format: "%.3f", finalA))")
                    break
                } else {
                    // Consume the whole segment
                    let totalSweep = packPath.last!.a - packPath.first!.a
                    var finalA = pt2.a
                    if abs(totalSweep) > 350.0 {
                        finalA += totalSweep > 0 ? 360.0 : -360.0
                    }
                    lines.append("G1 X\(String(format: "%.3f", pt2.x)) A\(String(format: "%.3f", finalA))")
                    travel += segA
                }
            }
        }

        lines.append("M5                            ; torch off")
        return lines
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
