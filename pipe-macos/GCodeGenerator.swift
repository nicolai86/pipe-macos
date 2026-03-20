import Foundation
import SceneKit

// MARK: - GCode Generation Settings
struct GCodeSettings {
    // Feed rates
    var feedRate: CGFloat = 1000.0       // mm/min - cutting feed
    var rapidRate: CGFloat = 3000.0      // mm/min - rapid travel
    
    // Heights
    var safeHeight: CGFloat = 25.0       // mm - safe travel height
    var cutHeight: CGFloat = 1.5         // mm - LEGACY
    
    // Kerf compensation (Delegated to Controller or handled via CAM later)
    var kerfWidth: CGFloat = 2.0
    var enableKerfComp: Bool = true
    
    // Lead-in & Relief Settings
    var leadInDistance: CGFloat = 5.0    // mm - distance to pierce in the scrap zone
    var overburnDegrees: CGFloat = 10.0  // degrees - rotation past 360 to sever the final tab
    
    // SimCNC-specific settings
    var useSimCNC: Bool = true           // Use SimCNC automatic pierce sequence (M3 S1)
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
        let sortedFeatures = stock.features.sorted { a, b in
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
                return pA < pB
            } else {
                return a.xCenter < b.xCenter
            }
        }
        
        // 4. Trace the exact contours provided by OpenCASCADE
        for feature in sortedFeatures {
            gcode.append(contentsOf: generateUniversalToolpath(feature: feature, stock: stock))
            gcode.append("") // Spacer between features
        }
        
        // 5. Program End
        gcode.append("; === Program End ===")
        gcode.append("M5              ; torch off (redundant safety)")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))  ; retract to safe height")
        gcode.append("G0 X0 A0        ; return to home")
        gcode.append("M30             ; end of program")
        gcode.append("%")
        
        return gcode.joined(separator: "\n")
    }
    
    // MARK: - Universal Path Generator
    
    /// Replaces all legacy hardcoded shapes. Traces the OCCT B-Rep directly.
    private func generateUniversalToolpath(feature: SurfaceFeature, stock: StockInfo) -> [String] {
        var gcode: [String] = []
        guard let path = feature.path, path.count > 1 else { return gcode }
        
        // Calculate effective radius to convert A-axis degrees to physical mm for lead-in vector math
        let effRadius = (stock.od ?? max(stock.odX ?? 50, stock.odY ?? 50)) / 2.0
        
        // Determine inside/outside piercing strategy
        let isInternal = (feature.type == .hole || feature.type == .cutout)
        
        let firstPt = path[0]
        let secondPt = path[1]
        
        // Calculate pierce lead-in vector perpendicular to the first cut segment
        let dx = secondPt.x - firstPt.x
        let da_mm = (secondPt.a - firstPt.a) * .pi / 180.0 * effRadius
        let len = sqrt(dx*dx + da_mm*da_mm)
        
        var pierceX = firstPt.x - settings.leadInDistance
        var pierceA = firstPt.a
        
        if len > 0.001 {
            let dirX = dx / len
            let dirA = da_mm / len
            
            // Rotate 90 degrees to point into the scrap material
            let normX = isInternal ? -dirA : dirA
            let normA_mm = isInternal ? dirX : -dirX
            
            pierceX = firstPt.x + normX * settings.leadInDistance
            pierceA = firstPt.a + (normA_mm / effRadius * 180.0 / .pi)
        }
        
        gcode.append("; --- Feature: \(feature.type.rawValue.capitalized) ---")
        gcode.append("; Center: X=\(String(format: "%.1f", feature.xCenter)), A=\(String(format: "%.1f", feature.aCenterDeg))")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        
        // Move to pierce point
        gcode.append("G0 X\(String(format: "%.3f", pierceX)) A\(String(format: "%.3f", pierceA))")
        gcode.append("M3 S1                         ; torch on")
        
        // Lead-in
        gcode.append("G1 X\(String(format: "%.3f", firstPt.x)) A\(String(format: "%.3f", firstPt.a)) F\(settings.feedRate)")
        
        // Trace the exact CAD boundary
        for pt in path {
            gcode.append("G1 X\(String(format: "%.3f", pt.x)) A\(String(format: "%.3f", pt.a))")
        }
        
        // Overburn to completely sever the part (skip for open-edge notches)
        if feature.type == .startCut || feature.type == .endCut || feature.type == .hole || feature.type == .cutout {
            if path.count > 5 {
                gcode.append("; Overburn tab")
                let overburnCount = min(5, path.count - 1)
                
                for i in 1...overburnCount {
                    var overburnA = path[i].a
                    
                    // If it's a full 360 rotation (Start/End cuts), continue rotating the A axis
                    // forward rather than violently rewinding the chuck 360 degrees.
                    if feature.type == .startCut || feature.type == .endCut {
                        overburnA += 360.0
                    }
                    
                    gcode.append("G1 X\(String(format: "%.3f", path[i].x)) A\(String(format: "%.3f", overburnA))")
                }
            }
        }
        
        gcode.append("M5                            ; torch off")
        return gcode
    }
    
    // MARK: - Header Generator
    
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
