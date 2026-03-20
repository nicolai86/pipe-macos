import Foundation
import SceneKit

// MARK: - GCode Generation Settings
struct GCodeSettings {
    // Feed rates
    var feedRate: CGFloat = 1000.0       // mm/min - cutting feed
    var rapidRate: CGFloat = 3000.0      // mm/min - rapid travel
    
    // Heights
    var safeHeight: CGFloat = 25.0       // mm - safe travel height (adjusted based on OD)
    var cutHeight: CGFloat = 1.5         // mm - LEGACY: used for explicit Z paths if needed
    
    // Kerf compensation
    var kerfWidth: CGFloat = 2.0         // mm - typical plasma kerf
    var enableKerfComp: Bool = true
    
    // Lead-in & Relief Settings
    var leadInDistance: CGFloat = 5.0    // mm - distance to pierce in the scrap zone
    var overburnDegrees: CGFloat = 10.0  // degrees - rotation past 360 to sever the final tab
    
    // SimCNC-specific settings
    var useSimCNC: Bool = true           // Use SimCNC automatic pierce sequence (M3 S1)
    var useLinearLeadIn: Bool = true     // true = straight line, false = arc
}

// MARK: - Toolpath Point
struct ToolpathPoint {
    var x: CGFloat
    var a: CGFloat
}

// MARK: - GCode Generator
class GCodeGenerator {
    var settings = GCodeSettings()
    
    /// Main entry point for generating the G-code program
    func generateGCode(for stock: StockInfo) -> String {
        var gcode: [String] = []
        
        // 1. Program Header
        gcode.append(contentsOf: generateHeader(stock: stock))
        
        // 2. Safe Startup Sequence
        gcode.append("G21             ; metric mode")
        gcode.append("G90             ; absolute positioning")
        gcode.append("G40             ; cancel cutter comp")
        gcode.append("G49             ; cancel tool length offset")
        gcode.append("G92 X0 Y0 Z0 A0 ; set current position as origin")
        gcode.append("")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))     ; move to safe height")
        gcode.append("M5              ; torch off (ensure)")
        gcode.append("")
        gcode.append("; === Cutting Pattern ===")
        
        // 3. Main Feature Loop (Data-Driven & Operation-Ordered)
        // Order: Start Cut -> Internal Features (sorted by X) -> End Cut
        let sortedFeatures = stock.features.sorted { a, b in
            
            // Helper function to assign machining priority
            func priority(for type: SurfaceFeatureType) -> Int {
                switch type {
                case .startCut: return 0
                case .hole, .cutout, .notch: return 1
                case .endCut: return 2
                }
            }
            
            let pA = priority(for: a.type)
            let pB = priority(for: b.type)
            
            if pA != pB {
                return pA < pB // Sort by operational priority first
            } else {
                return a.xCenter < b.xCenter // If same priority, sort by X position to minimize travel
            }
        }
        
        for feature in sortedFeatures {
            switch feature.type {
            case .startCut:
                gcode.append(contentsOf: generateStartCut(feature: feature, stock: stock))
            case .endCut:
                gcode.append(contentsOf: generateEndCut(feature: feature, stock: stock))
            case .notch:
                gcode.append(contentsOf: generateNotchCut(feature: feature, stock: stock))
            case .hole, .cutout:
                // Fallback to notch logic for basic cutouts right now,
                // or you can build dedicated generateHoleCut() later!
                gcode.append(contentsOf: generateNotchCut(feature: feature, stock: stock))
            }
            gcode.append("") // Spacer between features
        }
        
        // 4. Program End
        gcode.append("; === Program End ===")
        gcode.append("M5              ; torch off (redundant safety)")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))  ; retract to safe height")
        gcode.append("G0 X0 A0        ; return to home")
        gcode.append("M30             ; end of program")
        gcode.append("%")
        
        return gcode.joined(separator: "\n")
    }
    
    // MARK: - Feature Generators
    
    private func generateStartCut(feature: SurfaceFeature, stock: StockInfo) -> [String] {
        var gcode: [String] = []
        let path = feature.path
        guard !path.isEmpty else { return [] }
        
        let firstPoint = path.first!
        let startScrapX = firstPoint.x - settings.leadInDistance
        
        gcode.append("; --- Feature: Start Profile (Miter/Square) ---")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        
        // Pierce in the scrap
        gcode.append("G0 X\(String(format: "%.3f", startScrapX)) A\(String(format: "%.3f", firstPoint.a))")
        gcode.append("M3 S1                         ; torch on")
        
        // Lead-in to the first point
        gcode.append("G1 X\(String(format: "%.3f", firstPoint.x)) A\(String(format: "%.3f", firstPoint.a)) F\(settings.feedRate)")
        
        // Trace the exact profile (handles saddles, miters, and square cuts natively)
        for point in path {
            gcode.append("G1 X\(String(format: "%.3f", point.x)) A\(String(format: "%.3f", point.a))")
        }
        
        // Overburn to sever (repeat the first few degrees of the contour)
        if path.count > 5 {
            gcode.append("; Overburn tab")
            for i in 1...min(5, path.count - 1) {
                let overburnA = path[i].a + 360.0
                gcode.append("G1 X\(String(format: "%.3f", path[i].x)) A\(String(format: "%.3f", overburnA))")
            }
        }
        
        gcode.append("M5                            ; torch off")
        return gcode
    }
    
    private func generateEndCut(feature: SurfaceFeature, stock: StockInfo) -> [String] {
        var gcode: [String] = []
        let path = feature.path
        guard !path.isEmpty else { return [] }
        
        let firstPoint = path.first!
        let endScrapX = firstPoint.x + settings.leadInDistance
        
        gcode.append("; --- Feature: End Profile (Miter/Square) ---")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        
        // Pierce in the scrap
        gcode.append("G0 X\(String(format: "%.3f", endScrapX)) A\(String(format: "%.3f", firstPoint.a))")
        gcode.append("M3 S1                         ; torch on")
        
        // Lead-in to the first point
        gcode.append("G1 X\(String(format: "%.3f", firstPoint.x)) A\(String(format: "%.3f", firstPoint.a)) F\(settings.feedRate)")
        
        // Trace the exact profile
        for point in path {
            gcode.append("G1 X\(String(format: "%.3f", point.x)) A\(String(format: "%.3f", point.a))")
        }
        
        // Overburn to sever
        if path.count > 5 {
            gcode.append("; Overburn tab")
            for i in 1...min(5, path.count - 1) {
                let overburnA = path[i].a + 360.0
                gcode.append("G1 X\(String(format: "%.3f", path[i].x)) A\(String(format: "%.3f", overburnA))")
            }
        }
        
        gcode.append("M5                            ; torch off")
        return gcode
    }
    
    private func generateNotchCut(feature: SurfaceFeature, stock: StockInfo) -> [String] {
        var gcode: [String] = []
        let radius = (stock.od ?? 50) / 2
        
        // Pull dimensions from the newly updated detection logic
        let notchLengthX = feature.dimensions["width"] ?? 20.0
        let notchAngleA = feature.dimensions["angle"] ?? 30.0
        
        // Internal kerf subtraction
        let kerfOffset = settings.enableKerfComp ? settings.kerfWidth / 2 : 0
        let startX = feature.xCenter - notchLengthX / 2 + kerfOffset
        let startA = feature.aCenterDeg - notchAngleA / 2 + (kerfOffset / radius * 180.0 / .pi)
        let endX = startX + notchLengthX - (kerfOffset * 2)
        let endA = startA + notchAngleA - ((kerfOffset * 2) / radius * 180.0 / .pi)
        
        // Calculate lead-in based on the first vertical cut (Top edge going right)
        let nextX = startX + (notchLengthX * 0.1)
        let pierce = calculatePiercePoint(
            startPoint: (x: startX, a: startA),
            nextPoint: (x: nextX, a: startA),
            radius: radius,
            isInternalFeature: true
        )
        
        gcode.append("; --- Feature: \(feature.type.rawValue.capitalized) at X=\(String(format: "%.1f", feature.xCenter)) ---")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        
        // Pierce in the scrap
        gcode.append("G0 X\(String(format: "%.3f", pierce.x)) A\(String(format: "%.3f", pierce.a))")
        gcode.append("M3 S1                         ; torch on")
        
        // Lead-in to the corner
        gcode.append("G1 X\(String(format: "%.3f", startX)) A\(String(format: "%.3f", startA)) F\(settings.feedRate)")
        
        // To prevent faceted cuts on low-res controllers, we can break lines into points
        let numPoints = 10
        
        // 1. Top edge (Moving along X)
        for i in 1...numPoints {
            let x = startX + CGFloat(i) * (endX - startX) / CGFloat(numPoints)
            gcode.append("G1 X\(String(format: "%.3f", x)) A\(String(format: "%.3f", startA))")
        }
        
        // 2. Right edge (Moving along A)
        for i in 1...numPoints {
            let a = startA + CGFloat(i) * (endA - startA) / CGFloat(numPoints)
            gcode.append("G1 X\(String(format: "%.3f", endX)) A\(String(format: "%.3f", a))")
        }
        
        // 3. Bottom edge (Moving back along X)
        for i in 1...numPoints {
            let x = endX - CGFloat(i) * (endX - startX) / CGFloat(numPoints)
            gcode.append("G1 X\(String(format: "%.3f", x)) A\(String(format: "%.3f", endA))")
        }
        
        // 4. Left edge (Moving back along A)
        for i in 1...numPoints {
            let a = endA - CGFloat(i) * (endA - startA) / CGFloat(numPoints)
            gcode.append("G1 X\(String(format: "%.3f", startX)) A\(String(format: "%.3f", a))")
        }
        
        // Slight overburn back into the top edge to sever
        gcode.append("G1 X\(String(format: "%.3f", startX + 2.0)) A\(String(format: "%.3f", startA)) ; Overburn")
        
        gcode.append("M5                            ; torch off")
        return gcode
    }
    
    // MARK: - Helpers
    
    private func calculatePiercePoint(startPoint: (x: CGFloat, a: CGFloat), nextPoint: (x: CGFloat, a: CGFloat), radius: CGFloat, isInternalFeature: Bool) -> (x: CGFloat, a: CGFloat) {
        // Simple linear lead-in calculation perpendicular to the first cut direction
        let dx = nextPoint.x - startPoint.x
        let da = (nextPoint.a - startPoint.a) * .pi / 180.0 * radius
        
        let length = sqrt(dx * dx + da * da)
        guard length > 0 else {
            // Fallback if points are identical
            return (x: startPoint.x - settings.leadInDistance, a: startPoint.a)
        }
        
        // Normalize direction vector
        let dirX = dx / length
        let dirA = da / length
        
        // Calculate perpendicular normal (pointing into the scrap)
        // For internal features, we want the normal to point "inside" the cutout
        let normalX = isInternalFeature ? -dirA : dirA
        let normalA = isInternalFeature ? dirX : -dirX
        
        let pierceX = startPoint.x + normalX * settings.leadInDistance
        
        // Convert the arc length back to degrees for the A-axis
        let pierceA = startPoint.a + (normalA * settings.leadInDistance / radius * 180.0 / .pi)
        
        return (x: pierceX, a: pierceA)
    }
    
    private func generateHeader(stock: StockInfo) -> [String] {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy, HH:mm"
        
        var header = [
            "%",
            "O0001 (PROGRAM NAME: cylinder)",
            "(GENERATED: \(formatter.string(from: Date())))",
            "(STOCK: \(stock.profile.rawValue))",
            "(OD: \(String(format: "%.1f", stock.od ?? 0))mm)",
            "(LENGTH: \(String(format: "%.1f", stock.length))mm)"
        ]
        
        if stock.features.isEmpty {
            header.append("(FEATURES: none detected)")
        } else {
            header.append("(FEATURES DETECTED: \(stock.features.count))")
            for feature in stock.features {
                header.append("(  - \(feature.type.rawValue.capitalized) at X=\(String(format: "%.1f", feature.xCenter))mm, A=\(String(format: "%.0f", feature.aCenterDeg))°)")
            }
        }
        header.append("")
        return header
    }
}
