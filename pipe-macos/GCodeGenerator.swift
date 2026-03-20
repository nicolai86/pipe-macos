import Foundation
import SceneKit

// MARK: - GCode Generation Settings (per KB Section 7-9)

struct GCodeSettings {
    // Feed rates
    var feedRate: CGFloat = 1000.0       // mm/min - cutting feed
    var rapidRate: CGFloat = 3000.0      // mm/min - rapid travel
    
    // Heights (KB Section 7-8)
    // NOTE: For SimCNC, pierce height, pierce delay, and cut height are configured
    // in SimCNC plasma settings, NOT in G-code. M3 S1 handles everything.
    var safeHeight: CGFloat = 25.0       // mm - safe travel height (adjusted based on OD)
    var cutHeight: CGFloat = 1.5         // mm - LEGACY: used for Z calculation in explicit Z paths
    
    // Kerf compensation (KB Section 9)
    var kerfWidth: CGFloat = 2.0         // mm - typical plasma kerf
    var enableKerfComp: Bool = true
    // --- NEW: Lead-in & Relief Settings ---
    var leadInDistance: CGFloat = 5.0    // mm - distance to pierce in the scrap zone
    var overburnDegrees: CGFloat = 10.0  // degrees - rotation past 360 to sever the final tab
    
    // SimCNC-specific settings
    var useSimCNC: Bool = true           // Use SimCNC automatic pierce sequence
    
    var useLinearLeadIn: Bool = true     // true = straight line, false = arc (requires G2/G3 mapping)
}

// MARK: - Toolpath Point

struct ToolpathPoint {
    var x: CGFloat
    var y: CGFloat
    var z: CGFloat
    var a: CGFloat       // A axis in degrees
    var isRapid: Bool
    var torchOn: Bool
    var comment: String?
    
    init(x: CGFloat = 0, y: CGFloat = 0, z: CGFloat = 0, a: CGFloat = 0, 
         isRapid: Bool = false, torchOn: Bool = false, comment: String? = nil) {
        self.x = x
        self.y = y
        self.z = z
        self.a = a
        self.isRapid = isRapid
        self.torchOn = torchOn
        self.comment = comment
    }
}

// MARK: - GCode Generator

/// Generates SimCNC compatible GCode for XYZ-A rotary plasma cutting per KB Section 7
class GCodeGenerator {
    
    private var settings: GCodeSettings
    
    init(settings: GCodeSettings = GCodeSettings()) {
        self.settings = settings
    }
    
    /// Calculates a lead-in pierce point by unwrapping the rotary axis,
    /// calculating a normal vector into the scrap, and re-wrapping.
    private func calculatePiercePoint(
        startPoint: (x: CGFloat, a: CGFloat),
        nextPoint: (x: CGFloat, a: CGFloat),
        radius: CGFloat,
        isInternalFeature: Bool
    ) -> (x: CGFloat, a: CGFloat) {
        
        // 1. Convert A degrees to physical Y arc length (mm)
        let y1 = startPoint.a * .pi / 180.0 * radius
        let y2 = nextPoint.a * .pi / 180.0 * radius
        
        // 2. Calculate the direction vector of the first cut segment
        let dx = nextPoint.x - startPoint.x
        let dy = y2 - y1
        
        // Normalize the direction vector
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0.001 else { return startPoint }
        
        let dirX = dx / length
        let dirY = dy / length
        
        // 3. Calculate the normal vector (perpendicular to cut direction)
        // Left for internal scrap (holes), Right for external scrap (perimeters)
        let normalX = isInternalFeature ? -dirY : dirY
        let normalY = isInternalFeature ? dirX : -dirX
        
        // 4. Apply the lead-in distance along the normal vector
        let pierceX = startPoint.x + (normalX * settings.leadInDistance)
        let pierceY = y1 + (normalY * settings.leadInDistance)
        
        // 5. Convert the physical Y pierce point back to A degrees
        let pierceA = pierceY / radius * 180.0 / .pi
        
        return (x: pierceX, a: pierceA)
    }
    
    func generate(for shape: SelectedShape, stockInfo: StockInfo? = nil) -> String {
        var gcode: [String] = []
        var warnings: [String] = []
        
        // Header
        gcode.append("%")
        gcode.append("O0001 (PROGRAM NAME: \(shape.shapeType))")
        gcode.append("(GENERATED: \(Date().formatted()))")
        gcode.append("(STOCK: \(stockInfo?.profile.rawValue.uppercased() ?? "UNKNOWN"))")
        if let stock = stockInfo {
            if let od = stock.od {
                gcode.append("(OD: \(String(format: "%.1f", od))mm) ; round tube")
            } else if let odX = stock.odX, let odY = stock.odY {
                gcode.append("(DIMENSIONS: \(String(format: "%.1f", odX))mm × \(String(format: "%.1f", odY))mm) ; rectangular/square tube")
            }
            gcode.append("(LENGTH: \(String(format: "%.1f", stock.length))mm)")
            
            // Diagnostic info for debugging detection
            gcode.append("(END CUTS: start=\(stock.startEndCut?.type.rawValue ?? "none"), end=\(stock.endEndCut?.type.rawValue ?? "none"))")
            
            // Feature detection diagnostics
            if !stock.features.isEmpty {
                gcode.append("(FEATURES DETECTED: \(stock.features.count))")
                for feature in stock.features {
                    gcode.append("(  - \(feature.type.rawValue) at X=\(String(format: "%.1f", feature.xCenter))mm, A=\(String(format: "%.0f", feature.aCenterDeg))°)")
                }
            } else {
                gcode.append("(FEATURES: none detected)")
            }
        } else {
            // No stock info - explain why
            if shape.node != nil {
                gcode.append("; Stock info disabled - sub-shape selected")
                gcode.append("; Use 'Generate GCode for Stock' button for full analysis")
            } else {
                gcode.append("; Stock classification failed")
            }
        }
        
        // Validate features (KB Section 12)
        if let stock = stockInfo {
            for feature in stock.features {
                let (isValid, errors) = feature.validate(stockInfo: stock)
                if !isValid {
                    for error in errors {
                        warnings.append("Feature \(feature.id): \(error)")
                        gcode.append("(WARNING: Feature \(feature.id) - \(error))")
                    }
                }
                if feature.confidence < 0.8 {
                    warnings.append("Feature \(feature.id) confidence < 80% - verify manually")
                    gcode.append("(WARNING: Feature \(feature.id) confidence \(String(format: "%.0f", feature.confidence * 100))% - verify)")
                }
            }
        }
        
        gcode.append("")
        
        // Safety block and preamble (KB Section 7)
        gcode.append("G21           ; metric mode")
        gcode.append("G90           ; absolute positioning")
        gcode.append("G40           ; cancel cutter comp")
        gcode.append("G49           ; cancel tool length offset")
        gcode.append("G92 X0 Y0 Z0 A0  ; set current position as origin")
        gcode.append("")
        
        // Move to safe height
        let safeZ = computeSafeHeight(stockInfo: stockInfo)
        gcode.append("G0 Z\(String(format: "%.1f", safeZ))        ; move to safe height")
        gcode.append("M5            ; torch off (ensure)")
        gcode.append("")
        
        // Generate toolpath based on shape type and stock info
        gcode.append("; === Cutting Pattern ===")
        
        if let stock = stockInfo {
            gcode.append(contentsOf: generateStockCutting(stock: stock))
        } else {
            // Fallback to legacy shape-based generation
            switch shape.shapeType {
            case "cylinder":
                gcode.append(contentsOf: generateCylinderCut(shape: shape))
            case "box":
                gcode.append(contentsOf: generateBoxCut(shape: shape))
            default:
                gcode.append("; Unsupported shape for plasma cutting")
                gcode.append("; Only cylinders and boxes are supported")
            }
        }
        
        // Shutdown
        gcode.append("")
        gcode.append("; === Program End ===")
        gcode.append("M5            ; torch off (redundant safety)")
        gcode.append("G0 Z\(String(format: "%.1f", safeZ))  ; retract")
        gcode.append("G0 X0 A0      ; return to home")
        gcode.append("M30           ; end of program")
        gcode.append("%")
        
        // Final validation summary (KB Section 12)
        if !warnings.isEmpty {
            print("G-code generation completed with \(warnings.count) warning(s):")
            for warning in warnings {
                print("  ⚠️  \(warning)")
            }
        }
        
        return gcode.joined(separator: "\n")
    }

    /// Resolves the physical Y and Z offset of the tube surface at any given A rotation angle.
    /// Resolves the physical Y and Z offset of the tube surface at any given A rotation angle.
    private func getSurfacePoint(stock: StockInfo, angleDeg: CGFloat) -> (y: CGFloat, z: CGFloat) {
        let rad = angleDeg * .pi / 180.0
        let sinA = sin(rad)
        let cosA = cos(rad)

        if stock.profile == .round {
            let radius = (stock.od ?? 50) / 2
            return (radius * sinA, radius * cosA)
        } else {
            // For square/rectangular stock, we trace the flat perimeter of the rectangle
            let width = stock.odX ?? 50
            let height = stock.odY ?? 50

            var r = CGFloat.greatestFiniteMagnitude
            if abs(sinA) > 0.0001 {
                r = min(r, (width / 2) / abs(sinA))
            }
            if abs(cosA) > 0.0001 {
                r = min(r, (height / 2) / abs(cosA))
            }
            return (r * sinA, r * cosA)
        }
    }
    
    // MARK: - Safe Height Calculation (KB Section 7)
    

    private func computeSafeHeight(stockInfo: StockInfo?) -> CGFloat {
        guard let stock = stockInfo else {
            return settings.safeHeight
        }
        
        // Safe Z = max surface height + clearance
        // For round tube: max height = OD/2 (at A=0)
        let maxSurfaceHeight: CGFloat
        switch stock.profile {
        case .round:
            maxSurfaceHeight = (stock.od ?? 0) / 2
        case .rectangular, .square:
            maxSurfaceHeight = max(stock.odX ?? 0, stock.odY ?? 0) / 2
        case .unknown:
            maxSurfaceHeight = 25
        }
        
        return maxSurfaceHeight + settings.cutHeight + 10  // 10mm clearance
    }
    
    // MARK: - Stock-Based GCode Generation (per KB Section 2-7)
    
    private func generateStockCutting(stock: StockInfo) -> [String] {
        var gcode: [String] = []
        
        // Determine effective radius for round vs square/rectangular tubes
        let effectiveRadius: CGFloat
        switch stock.profile {
        case .round:
            effectiveRadius = (stock.od ?? 50) / 2
        case .square, .rectangular:
            // For rectangular tubes, use diagonal as effective "radius" for positioning
            // This is the distance from center to corner
            let width = stock.odX ?? 50
            let height = stock.odY ?? 50
            effectiveRadius = sqrt(width * width + height * height) / 2
        case .unknown:
            effectiveRadius = 25  // Default fallback
        }
        
        // Check for miter cuts at ends
        let hasStartMiter = stock.startEndCut?.type == .miter || stock.startEndCut?.type == .compoundMiter
        let hasEndMiter = stock.endEndCut?.type == .miter || stock.endEndCut?.type == .compoundMiter
        
        // Cut start end if mitered
        if hasStartMiter, let miter = stock.startEndCut {
            gcode.append("; === Cut Start End (Miter: \(String(format: "%.1f", miter.miterAngleDeg))°) ===")
            gcode.append(contentsOf: generateMiterCut(
                stock: stock,
                miterAngle: miter.miterAngleDeg,
                miterDirection: miter.miterDirectionDeg,
                xAtCenterline: miter.xAtCenterline,
                isStartEnd: true
            ))
            gcode.append("")
        } else if stock.startEndCut?.type == .square {
            // Square end - cut straight across
            gcode.append("; === Cut Start End (Square) ===")
            gcode.append(contentsOf: generateStraightCut(
                radius: effectiveRadius,
                xPosition: stock.startEndCut?.xAtCenterline ?? 0, isStartEnd: true
            ))
            gcode.append("")
        }
        
        // Cut end end if mitered
        if hasEndMiter, let miter = stock.endEndCut {
            gcode.append("; === Cut End End (Miter: \(String(format: "%.1f", miter.miterAngleDeg))°) ===")
            gcode.append(contentsOf: generateMiterCut(
                stock: stock,
                miterAngle: miter.miterAngleDeg,
                miterDirection: miter.miterDirectionDeg,
                xAtCenterline: miter.xAtCenterline,
                isStartEnd: false
            ))
            gcode.append("")
        } else if stock.endEndCut?.type == .square {
            // Square end - cut straight across
            gcode.append("; === Cut End End (Square) ===")
            gcode.append(contentsOf: generateStraightCut(
                radius: effectiveRadius,
                xPosition: stock.endEndCut?.xAtCenterline ?? stock.length, isStartEnd: false
            ))
            gcode.append("")
        }
        
        // Cut detected features (holes, notches, copes)
        if !stock.features.isEmpty {
            gcode.append("; === Cut Features ===")
            for feature in stock.features {
                gcode.append("; Feature \(feature.id): \(feature.type.rawValue) - \(feature.shape.rawValue)")
                gcode.append(contentsOf: generateFeatureCut(feature: feature, stock: stock))
                gcode.append("")
            }
        }
        
        return gcode
    }
    
    // MARK: - Straight Cut (KB Section 7)
    
    private func generateStraightCut(radius: CGFloat, xPosition: CGFloat, isStartEnd: Bool) -> [String] {
        var gcode: [String] = []
        
        let kerfOffset: CGFloat = settings.enableKerfComp ? settings.kerfWidth / 2 : 0
        let startX = xPosition + (isStartEnd ? kerfOffset : -kerfOffset)
        
        let scrapDirection: CGFloat = isStartEnd ? -1.0 : 1.0
        let pierceX = startX + (scrapDirection * settings.leadInDistance)
        
        gcode.append("; --- Pierce & Relief Cut ---")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        gcode.append("G0 X\(String(format: "%.3f", pierceX)) A0.000")
        gcode.append("M3 S1                         ; torch on")
        
        gcode.append("G1 X\(String(format: "%.3f", startX)) A0.000 F\(settings.feedRate)")
        
        gcode.append("; --- Main Perimeter Cut ---")
        let numPoints = 72
        for i in 1...numPoints {
            let angle = CGFloat(i) * (360.0 / CGFloat(numPoints))
            gcode.append("G1 X\(String(format: "%.3f", startX)) A\(String(format: "%.3f", angle))")
        }
        
        gcode.append("; --- Overburn (Sever Tab) ---")
        let overburnSteps = Int(CGFloat(numPoints) * (settings.overburnDegrees / 360.0))
        for i in 1...overburnSteps {
            let rotaryAngle = 360.0 + CGFloat(i) * (360.0 / CGFloat(numPoints))
            gcode.append("G1 X\(String(format: "%.3f", startX)) A\(String(format: "%.3f", rotaryAngle))")
        }
        
        gcode.append("M5                           ; torch off")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))  ; retract")
        
        return gcode
    }
    
    // MARK: - Miter Cut (KB Section 3 & 7)
    
    private func generateMiterCut(stock: StockInfo, miterAngle: CGFloat, miterDirection: CGFloat,
                                      xAtCenterline: CGFloat, isStartEnd: Bool) -> [String] {
        var gcode: [String] = []
        
        let tanAngle = tan(miterAngle * .pi / 180.0)
        let dirRad = miterDirection * .pi / 180.0
        
        let numPoints = stock.profile == .round ? 72 : 144
        
        // 1. Calculate the true start point at A = 0
        let startPoint = getSurfacePoint(stock: stock, angleDeg: 0)
        var startX = xAtCenterline + startPoint.y * tan(dirRad) + startPoint.z * tanAngle
        
        // Apply Directional Kerf Compensation
        let kerfOffset: CGFloat = settings.enableKerfComp ? settings.kerfWidth / 2 : 0
        startX += isStartEnd ? kerfOffset : -kerfOffset
        
        // 2. Calculate the Scrap Pierce Point
        // Scrap is towards -X for the start cut, and +X for the end cut
        let scrapDirection: CGFloat = isStartEnd ? -1.0 : 1.0
        let pierceX = startX + (scrapDirection * settings.leadInDistance)
        
        gcode.append("; --- Pierce & Relief Cut ---")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        gcode.append("G0 X\(String(format: "%.3f", pierceX)) A0.000")
        gcode.append("M3 S1                         ; torch on")
        
        // Linear move from scrap pierce into the cut path (Acts as Relief + Lead-in)
        gcode.append("G1 X\(String(format: "%.3f", startX)) A0.000 F\(settings.feedRate)")
        
        // 3. Main 360-Degree Perimeter Cut
        gcode.append("; --- Main Perimeter Cut ---")
        for i in 1...numPoints { // Note: Start at 1, we are already at 0
            let angle = CGFloat(i) * (360.0 / CGFloat(numPoints))
            let point = getSurfacePoint(stock: stock, angleDeg: angle)
            
            var x = xAtCenterline + point.y * tan(dirRad) + point.z * tanAngle
            x += isStartEnd ? kerfOffset : -kerfOffset
            
            gcode.append("G1 X\(String(format: "%.3f", x)) A\(String(format: "%.3f", angle))")
        }
        
        // 4. Overburn (Lead-out) to sever the tab
        gcode.append("; --- Overburn (Sever Tab) ---")
        let overburnSteps = Int(CGFloat(numPoints) * (settings.overburnDegrees / 360.0))
        for i in 1...overburnSteps {
            // A-axis continues to climb past 360 (e.g., 365, 370)
            let rotaryAngle = 360.0 + CGFloat(i) * (360.0 / CGFloat(numPoints))
            // Physical geometry wraps back around to calculate X
            let physicalAngle = CGFloat(i) * (360.0 / CGFloat(numPoints))
            
            let point = getSurfacePoint(stock: stock, angleDeg: physicalAngle)
            var x = xAtCenterline + point.y * tan(dirRad) + point.z * tanAngle
            x += isStartEnd ? kerfOffset : -kerfOffset
            
            gcode.append("G1 X\(String(format: "%.3f", x)) A\(String(format: "%.3f", rotaryAngle))")
        }
        
        gcode.append("M5                           ; torch off")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))  ; retract")
        
        return gcode
    }
    
    // MARK: - Feature Cutting (KB Section 4 & 7)

    private func generateFeatureCut(feature: SurfaceFeature, stock: StockInfo) -> [String] {
        switch feature.type {
        case .hole:
            return generateHoleCut(feature: feature, stock: stock)
        case .notch:
            return generateNotchCut(feature: feature, stock: stock)
        case .cope:
            return generateCopeCut(feature: feature, stock: stock)
        case .scallop:
            return generateScallopCut(feature: feature, stock: stock)
        case .cutout:
            return generateHoleCut(feature: feature, stock: stock)  // Treat cutout as hole
        }
    }
    
    private func generateHoleCut(feature: SurfaceFeature, stock: StockInfo) -> [String] {
        var gcode: [String] = []
        
        let radius = (stock.od ?? 50) / 2
        let holeDiameter = feature.dimensions["diameter"] ?? 20.0
        let holeRadius = holeDiameter / 2
        
        // PHYSICS FIX: For internal features, we SUBTRACT kerf so the hole doesn't end up oversized
        let effectiveRadius = holeRadius - (settings.enableKerfComp ? settings.kerfWidth / 2 : 0)
        let numPoints = 36
        
        // Pre-calculate t=0 and t=1 to determine the exact trajectory of the first segment
        let t0: CGFloat = 0
        let t1: CGFloat = (2 * .pi) / CGFloat(numPoints)
        
        let startX = feature.xCenter + effectiveRadius * cos(t0)
        let startA_rad = (effectiveRadius / radius) * sin(t0)
        let startA = feature.aCenterDeg + (startA_rad * 180 / .pi)
        
        let nextX = feature.xCenter + effectiveRadius * cos(t1)
        let nextA_rad = (effectiveRadius / radius) * sin(t1)
        let nextA = feature.aCenterDeg + (nextA_rad * 180 / .pi)
        
        // Calculate the dynamic pierce point pointing into the scrap (center of the hole)
        let pierce = calculatePiercePoint(
            startPoint: (x: startX, a: startA),
            nextPoint: (x: nextX, a: nextA),
            radius: radius,
            isInternalFeature: true
        )
        
        gcode.append("; --- Hole Feature (X=\(String(format: "%.1f", feature.xCenter)), A=\(String(format: "%.1f", feature.aCenterDeg))) ---")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        
        // Move to calculated pierce point in the scrap
        gcode.append("G0 X\(String(format: "%.3f", pierce.x)) A\(String(format: "%.3f", pierce.a))")
        
        // Pierce
        gcode.append("M3 S1                         ; torch on")
        
        // Linear lead-in to the actual start point
        gcode.append("G1 X\(String(format: "%.3f", startX)) A\(String(format: "%.3f", startA)) F\(settings.feedRate) ; Lead-in")
        
        // Cut hole ellipse
        for i in 1...numPoints {
            let t = CGFloat(i) * (2 * .pi / CGFloat(numPoints))
            let x = feature.xCenter + effectiveRadius * cos(t)
            let aOffsetRad = (effectiveRadius / radius) * sin(t)
            let a = feature.aCenterDeg + (aOffsetRad * 180 / .pi)
            
            gcode.append("G1 X\(String(format: "%.3f", x)) A\(String(format: "%.3f", a))")
        }
        
        // Overburn (Lead-out) along the same path for a few degrees to sever the tab
        let overburnSteps = 2
        for i in 1...overburnSteps {
            let t = CGFloat(i) * (2 * .pi / CGFloat(numPoints))
            let x = feature.xCenter + effectiveRadius * cos(t)
            let aOffsetRad = (effectiveRadius / radius) * sin(t)
            let a = feature.aCenterDeg + (aOffsetRad * 180 / .pi)
            
            gcode.append("G1 X\(String(format: "%.3f", x)) A\(String(format: "%.3f", a)) ; Overburn")
        }
        
        gcode.append("M5                           ; torch off")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        
        return gcode
    }
    
    private func generateNotchCut(feature: SurfaceFeature, stock: StockInfo) -> [String] {
        var gcode: [String] = []
        
        let radius = (stock.od ?? 50) / 2
        let notchDepth = feature.dimensions["depth"] ?? 10.0
        let notchAngle = feature.dimensions["angle"] ?? 30.0  // angular width in degrees
        
        // Internal kerf subtraction
        let kerfOffset = settings.enableKerfComp ? settings.kerfWidth / 2 : 0
        let startX = feature.xCenter - notchDepth / 2 + kerfOffset
        let startA = feature.aCenterDeg - notchAngle / 2 + (kerfOffset / radius * 180.0 / .pi)
        let endX = startX + notchDepth - (kerfOffset * 2)
        let endA = startA + notchAngle - ((kerfOffset * 2) / radius * 180.0 / .pi)
        
        // Calculate lead-in based on the first vertical cut (Top edge going right)
        let nextX = startX + (notchDepth * 0.1) // Next point is slightly further down X
        let pierce = calculatePiercePoint(
            startPoint: (x: startX, a: startA),
            nextPoint: (x: nextX, a: startA),
            radius: radius,
            isInternalFeature: true
        )
        
        gcode.append("; --- Notch Feature ---")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        
        // Pierce in the scrap
        gcode.append("G0 X\(String(format: "%.3f", pierce.x)) A\(String(format: "%.3f", pierce.a))")
        gcode.append("M3 S1                         ; torch on")
        
        // Lead-in to the corner
        gcode.append("G1 X\(String(format: "%.3f", startX)) A\(String(format: "%.3f", startA)) F\(settings.feedRate)")
        
        let numPoints = 10
        
        // Top edge (Moving along X)
        for i in 1...numPoints {
            let x = startX + CGFloat(i) * (endX - startX) / CGFloat(numPoints)
            gcode.append("G1 X\(String(format: "%.3f", x)) A\(String(format: "%.3f", startA))")
        }
        
        // Right edge (Moving along A)
        for i in 1...numPoints {
            let a = startA + CGFloat(i) * (endA - startA) / CGFloat(numPoints)
            gcode.append("G1 X\(String(format: "%.3f", endX)) A\(String(format: "%.3f", a))")
        }
        
        // Bottom edge (Moving back along X)
        for i in 1...numPoints {
            let x = endX - CGFloat(i) * (endX - startX) / CGFloat(numPoints)
            gcode.append("G1 X\(String(format: "%.3f", x)) A\(String(format: "%.3f", endA))")
        }
        
        // Left edge (Moving back along A)
        for i in 1...numPoints {
            let a = endA - CGFloat(i) * (endA - startA) / CGFloat(numPoints)
            gcode.append("G1 X\(String(format: "%.3f", startX)) A\(String(format: "%.3f", a))")
        }
        
        // Slight overburn back into the top edge
        gcode.append("G1 X\(String(format: "%.3f", startX + 2.0)) A\(String(format: "%.3f", startA)) ; Overburn")
        
        gcode.append("M5")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        
        return gcode
    }
    
    private func generateCopeCut(feature: SurfaceFeature, stock: StockInfo) -> [String] {
        var gcode: [String] = []
        
        let radiusA = (stock.od ?? 50) / 2  // Branch tube radius
        let radiusB = feature.dimensions["intersectingRadius"] ?? 25.0  // Header tube radius
        let intersectAngle = feature.dimensions["intersectAngle"] ?? 90.0  // degrees
        
        gcode.append("; Cope cut for T-joint (R_branch=\(String(format: "%.1f", radiusA)), R_header=\(String(format: "%.1f", radiusB)))")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        
        // Cope profile formula (KB Section 6):
        // X_cope(θ) = X0 ± sqrt(R_B² - (R_A * sin(θ))²) / sin(φ)
        let sinPhi = sin(intersectAngle * .pi / 180.0)
        let numPoints = 72
        
        let startX = feature.xCenter + radiusB / sinPhi
        gcode.append("G0 X\(String(format: "%.3f", startX)) A0")
        
        // Pierce - SimCNC M3 handles everything
        gcode.append("M3 S1                         ; torch on - SimCNC handles IHS, pierce, plunge")
        
        for i in 0...numPoints {
            let theta = CGFloat(i) * (2 * .pi / CGFloat(numPoints))
            
            // Cope formula
            let sinTheta = sin(theta)
            let insideSqrt = max(radiusB * radiusB - (radiusA * sinTheta) * (radiusA * sinTheta), 0)
            let x = feature.xCenter + sqrt(insideSqrt) / sinPhi
            
            let a = theta * 180 / .pi
            
            if i == 0 {
                gcode.append("G1 X\(String(format: "%.3f", x)) A\(String(format: "%.3f", a)) F\(settings.feedRate)")
            } else {
                gcode.append("G1 X\(String(format: "%.3f", x)) A\(String(format: "%.3f", a))")
            }
        }
        
        gcode.append("M5")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        
        return gcode
    }
    
    private func generateScallopCut(feature: SurfaceFeature, stock: StockInfo) -> [String] {
        // Scallop is a small weld relief - treat as small circular feature
        return generateHoleCut(feature: feature, stock: stock)
    }
    
    // MARK: - Legacy Shape-Based Generation (for backward compatibility)
    
    private func generateCylinderCut(shape: SelectedShape) -> [String] {
        var gcode: [String] = []
        
        guard let node = shape.node,
              let geometry = node.geometry else {
            gcode.append("; Error: No geometry found")
            return gcode
        }
        
        let vertices = extractVertices(from: geometry)
        guard !vertices.isEmpty else {
            gcode.append("; Error: Could not extract vertices")
            return gcode
        }
        
        let cylinderInfo = analyzeCylinder(vertices: vertices)
        let radius = cylinderInfo.diameter / 2.0
        
        gcode.append("; === Round Tube Cutting Pattern ===")
        gcode.append("; Diameter: \(String(format: "%.2f", cylinderInfo.diameter)) mm")
        gcode.append("; Length: \(String(format: "%.2f", cylinderInfo.length)) mm")
        gcode.append("")
        
        // Detect cutouts
        let cutouts = detectCutouts(vertices: vertices, radius: radius, length: cylinderInfo.length, axis: cylinderInfo.axis)
        gcode.append("; Found \(cutouts.count) cutout(s)")
        gcode.append("")
        
        // Cut ends
        let halfLength = cylinderInfo.length / 2.0
        
        gcode.append("; === Cut End 1 ===")
        if cylinderInfo.hasMiter {
            gcode.append("; MITER DETECTED: \(String(format: "%.1f", cylinderInfo.miterAngle))° angle")
        } else {
            gcode.append("; STRAIGHT END (A-axis rotation only)")
        }
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        gcode.append("G0 X\(String(format: "%.3f", -halfLength)) A0")
        gcode.append("M3 S1                         ; torch on - SimCNC handles IHS, pierce, plunge")
        
        if cylinderInfo.hasMiter {
            gcode.append(contentsOf: generateMiterPathLegacy(radius: radius, miterAngle: cylinderInfo.miterAngle))
        } else {
            gcode.append(contentsOf: generateCirclePathLegacy(radius: radius))
        }
        
        gcode.append("M5")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        gcode.append("")
        
        gcode.append("; === Cut End 2 ===")
        if cylinderInfo.hasMiter {
            gcode.append("; MITER DETECTED: \(String(format: "%.1f", cylinderInfo.miterAngle))° angle")
        } else {
            gcode.append("; STRAIGHT END (A-axis rotation only)")
        }
        gcode.append("G0 X\(String(format: "%.3f", halfLength)) A0")
        gcode.append("M3 S1                         ; torch on - SimCNC handles IHS, pierce, plunge")
        
        if cylinderInfo.hasMiter {
            gcode.append(contentsOf: generateMiterPathLegacy(radius: radius, miterAngle: cylinderInfo.miterAngle, reverse: true))
        } else {
            gcode.append(contentsOf: generateCirclePathLegacy(radius: radius))
        }
        
        gcode.append("M5")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        
        // Cut detected cutouts
        if !cutouts.isEmpty {
            gcode.append("")
            gcode.append("; === Cut Cutouts ===")
            for (index, cutout) in cutouts.enumerated() {
                gcode.append("; Cutout \(index + 1)")
                gcode.append(contentsOf: generateCutoutPathLegacy(cutout: cutout))
            }
        }
        
        return gcode
    }
    
    private func generateCirclePathLegacy(radius: CGFloat) -> [String] {
        var gcode: [String] = []
        let numPoints = 72
        
        for i in 0...numPoints {
            let angle = CGFloat(i) * (360.0 / CGFloat(numPoints))
            let aRad = angle * .pi / 180.0
            let z = radius * cos(aRad) + settings.cutHeight
            
            if i == 0 {
                gcode.append("G1 A\(String(format: "%.3f", angle)) Z\(String(format: "%.3f", z)) F\(settings.feedRate)")
            } else {
                gcode.append("G1 A\(String(format: "%.3f", angle)) Z\(String(format: "%.3f", z))")
            }
        }
        
        return gcode
    }
    
    private func generateMiterPathLegacy(radius: CGFloat, miterAngle: CGFloat, reverse: Bool = false) -> [String] {
        var gcode: [String] = []
        let numPoints = 72
        let tanAngle = tan(miterAngle * .pi / 180.0)
        
        for i in 0...numPoints {
            let angle = CGFloat(i) * (360.0 / CGFloat(numPoints))
            let rad = angle * .pi / 180.0
            
            let sign: CGFloat = reverse ? -1 : 1
            let xOffset = sign * radius * tanAngle * cos(rad)
            let cutX = -radius + xOffset
            let z = radius * cos(rad) + settings.cutHeight
            
            if i == 0 {
                gcode.append("G1 X\(String(format: "%.3f", cutX)) A\(String(format: "%.3f", angle)) Z\(String(format: "%.3f", z)) F\(settings.feedRate)")
            } else {
                gcode.append("G1 X\(String(format: "%.3f", cutX)) A\(String(format: "%.3f", angle)) Z\(String(format: "%.3f", z))")
            }
        }
        
        return gcode
    }
    
    private func generateBoxCut(shape: SelectedShape) -> [String] {
        var gcode: [String] = []
        
        guard let dims = shape.dimensions as? BoxDimensions else {
            gcode.append("; Error: Invalid box dimensions")
            return gcode
        }
        
        let width = dims.width
        let height = dims.height
        let depth = dims.depth
        
        gcode.append("; === Rectangular Tube Cutting Pattern ===")
        gcode.append("; Width: \(String(format: "%.2f", width)) mm")
        gcode.append("; Height: \(String(format: "%.2f", height)) mm")
        gcode.append("; Depth: \(String(format: "%.2f", depth)) mm")
        gcode.append("")
        
        let tubeLength = Swift.max(width, Swift.max(height, depth))
        let halfLength = tubeLength / 2.0
        
        gcode.append("; === Cut End 1 ===")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        gcode.append("G0 X\(String(format: "%.3f", -halfLength)) A0")
        gcode.append("M3 S1                         ; torch on - SimCNC handles IHS, pierce, plunge")
        
        // Generate rectangular tube path
        gcode.append(contentsOf: generateBoxPathLegacy(width: width, depth: depth))
        
        gcode.append("M5")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        gcode.append("")
        
        gcode.append("; === Cut End 2 ===")
        gcode.append("G0 X\(String(format: "%.3f", halfLength)) A0")
        gcode.append("M3 S1                         ; torch on - SimCNC handles IHS, pierce, plunge")
        
        gcode.append(contentsOf: generateBoxPathLegacy(width: width, depth: depth, reverse: true))
        
        gcode.append("M5")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        
        return gcode
    }
    
    private func generateBoxPathLegacy(width: CGFloat, depth: CGFloat, reverse: Bool = false) -> [String] {
        var gcode: [String] = []
        let numPoints = 144
        
        for i in 0...numPoints {
            let angle = CGFloat(i) * (360.0 / CGFloat(numPoints))
            let rad = angle * .pi / 180.0
            
            // Simplified rectangular tube: constant X, Z follows surface
            let cutX = reverse ? depth / 2 : -depth / 2
            let z = depth / 2 * abs(cos(rad)) + width / 2 * abs(sin(rad)) + settings.cutHeight
            
            if i == 0 {
                gcode.append("G1 X\(String(format: "%.3f", cutX)) A\(String(format: "%.3f", angle)) Z\(String(format: "%.3f", z)) F\(settings.feedRate)")
            } else {
                gcode.append("G1 X\(String(format: "%.3f", cutX)) A\(String(format: "%.3f", angle)) Z\(String(format: "%.3f", z))")
            }
        }
        
        return gcode
    }
    
    private func generateCutoutPathLegacy(cutout: Cutout) -> [String] {
        var gcode: [String] = []
        
        let startX = cutout.centerPosition - cutout.width / 2.0
        let startAngle = cutout.centerAngle - cutout.height / 2.0
        
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        gcode.append("G0 X\(String(format: "%.3f", startX)) A\(String(format: "%.1f", startAngle))")
        gcode.append("M3 S1                         ; torch on - SimCNC handles IHS, pierce, plunge")
        
        // Cut rectangular outline
        let numPoints = 20
        
        // Top edge
        for i in 0...numPoints {
            let x = startX + CGFloat(i) * cutout.width / CGFloat(numPoints)
            if i == 0 {
                gcode.append("G1 X\(String(format: "%.3f", x)) A\(String(format: "%.1f", startAngle)) F\(settings.feedRate)")
            } else {
                gcode.append("G1 X\(String(format: "%.3f", x))")
            }
        }
        
        // Right edge
        for i in 0...numPoints {
            let angle = startAngle + CGFloat(i) * cutout.height / CGFloat(numPoints)
            gcode.append("G1 X\(String(format: "%.3f", startX + cutout.width)) A\(String(format: "%.3f", angle))")
        }
        
        // Bottom edge
        for i in 0...numPoints {
            let x = startX + cutout.width - CGFloat(i) * cutout.width / CGFloat(numPoints)
            gcode.append("G1 X\(String(format: "%.3f", x)) A\(String(format: "%.1f", startAngle + cutout.height))")
        }
        
        // Left edge
        for i in 0...numPoints {
            let angle = startAngle + cutout.height - CGFloat(i) * cutout.height / CGFloat(numPoints)
            gcode.append("G1 X\(String(format: "%.3f", startX)) A\(String(format: "%.3f", angle))")
        }
        
        gcode.append("M5")
        gcode.append("G0 Z\(String(format: "%.1f", settings.safeHeight))")
        
        return gcode
    }
    
    // MARK: - Utility Functions
    
    private func extractVertices(from geometry: SCNGeometry) -> [SCNVector3] {
        guard let vertexSource = geometry.sources.first else { return [] }
        
        var vertices: [SCNVector3] = []
        let data = vertexSource.data
        let floatCount = data.count / MemoryLayout<Float>.size
        let vertexCount = floatCount / 3
        
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            let floatPtr = baseAddress.assumingMemoryBound(to: Float.self)
            
            for i in 0..<vertexCount {
                let x = CGFloat(floatPtr[i * 3])
                let y = CGFloat(floatPtr[i * 3 + 1])
                let z = CGFloat(floatPtr[i * 3 + 2])
                vertices.append(SCNVector3(x, y, z))
            }
        }
        
        return vertices
    }
    
    private func analyzeCylinder(vertices: [SCNVector3]) -> (diameter: CGFloat, length: CGFloat, axis: SCNVector3, hasMiter: Bool, miterAngle: CGFloat, miterAxis: SCNVector3) {
        guard vertices.count > 10 else {
            return (0, 0, SCNVector3(0, 0, 1), false, 0, SCNVector3(0, 0, 1))
        }
        
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        var minZ = CGFloat.greatestFiniteMagnitude, maxZ = -CGFloat.greatestFiniteMagnitude
        
        for v in vertices {
            minX = min(minX, v.x); maxX = max(maxX, v.x)
            minY = min(minY, v.y); maxY = max(maxY, v.y)
            minZ = min(minZ, v.z); maxZ = max(maxZ, v.z)
        }
        
        let size = SCNVector3(maxX - minX, maxY - minY, maxZ - minZ)
        let maxDim = Swift.max(size.x, Swift.max(size.y, size.z))
        
        var axis = SCNVector3(0, 0, 1)
        var length = size.z
        var diameter: CGFloat
        
        if size.x == maxDim {
            axis = SCNVector3(1, 0, 0)
            length = size.x
            diameter = Swift.max(size.y, size.z)
        } else if size.y == maxDim {
            axis = SCNVector3(0, 1, 0)
            length = size.y
            diameter = Swift.max(size.x, size.z)
        } else {
            diameter = Swift.max(size.x, size.y)
        }
        
        // Detect miter
        let endThreshold = diameter * 0.3
        var end1Vertices: [SCNVector3] = []
        var end2Vertices: [SCNVector3] = []
        
        for v in vertices {
            let projection: CGFloat
            switch axis.x {
            case 1: projection = v.x
            case -1: projection = -v.x
            default:
                switch axis.y {
                case 1: projection = v.y
                case -1: projection = -v.y
                default: projection = v.z
                }
            }
            
            let minProj: CGFloat
            let maxProj: CGFloat
            switch axis.x {
            case 1: minProj = minX; maxProj = maxX
            case -1: minProj = -maxX; maxProj = -minX
            default:
                switch axis.y {
                case 1: minProj = minY; maxProj = maxY
                case -1: minProj = -maxY; maxProj = -minY
                default: minProj = minZ; maxProj = maxZ
                }
            }
            
            if projection < minProj + endThreshold {
                end1Vertices.append(v)
            }
            if projection > maxProj - endThreshold {
                end2Vertices.append(v)
            }
        }
        
        func getEndVariation(_ verts: [SCNVector3], axis: SCNVector3) -> CGFloat {
            guard !verts.isEmpty else { return 0 }
            var projections: [CGFloat] = []
            for v in verts {
                let proj = v.x * axis.x + v.y * axis.y + v.z * axis.z
                projections.append(proj)
            }
            guard !projections.isEmpty else { return 0 }
            return projections.max()! - projections.min()!
        }
        
        let end1Variation = getEndVariation(end1Vertices, axis: axis)
        let end2Variation = getEndVariation(end2Vertices, axis: axis)
        let miterThreshold = diameter * 0.50
        
        var hasMiter = false
        var miterAngle: CGFloat = 0
        var miterAxis = SCNVector3(0, 0, 1)
        
        if end1Variation > miterThreshold || end2Variation > miterThreshold {
            hasMiter = true
            let maxVariation = Swift.max(end1Variation, end2Variation)
            miterAngle = atan(maxVariation / diameter) * 180.0 / .pi
            
            if axis.z == 1 || axis.z == -1 {
                miterAxis = SCNVector3(1, 0, 0)
            } else if axis.y == 1 || axis.y == -1 {
                miterAxis = SCNVector3(1, 0, 0)
            } else {
                miterAxis = SCNVector3(0, 1, 0)
            }
        }
        
        return (diameter, length, axis, hasMiter, miterAngle, miterAxis)
    }
    
    struct Cutout {
        var centerPosition: CGFloat
        var centerAngle: CGFloat
        var width: CGFloat
        var height: CGFloat
        var depth: CGFloat
        var vertices: [SCNVector3]
    }
    
    private func detectCutouts(vertices: [SCNVector3], radius: CGFloat, length: CGFloat, axis: SCNVector3) -> [Cutout] {
        guard !vertices.isEmpty else { return [] }
        
        let expectedRadius = radius
        let cutoutThreshold: CGFloat = radius * 0.10
        
        var cutoutVertices: [(vertex: SCNVector3, axialPos: CGFloat, angle: CGFloat, depth: CGFloat)] = []
        
        for v in vertices {
            let axialPos: CGFloat
            let radialDist: CGFloat
            let angle: CGFloat
            
            if axis.x == 1 || axis.x == -1 {
                axialPos = v.x
                radialDist = sqrt(v.y * v.y + v.z * v.z)
                angle = atan2(v.z, v.y) * 180.0 / .pi
            } else if axis.y == 1 || axis.y == -1 {
                axialPos = v.y
                radialDist = sqrt(v.x * v.x + v.z * v.z)
                angle = atan2(v.z, v.x) * 180.0 / .pi
            } else {
                axialPos = v.z
                radialDist = sqrt(v.x * v.x + v.y * v.y)
                angle = atan2(v.y, v.x) * 180.0 / .pi
            }
            
            let inwardDepth = expectedRadius - radialDist
            if inwardDepth > cutoutThreshold {
                cutoutVertices.append((v, axialPos, angle, inwardDepth))
            }
        }
        
        guard !cutoutVertices.isEmpty else { return [] }
        
        var cutouts: [Cutout] = []
        let axialBucketSize: CGFloat = 3.0
        let angleBucketSize: CGFloat = 10.0
        
        var groupedVertices: [[(vertex: SCNVector3, axialPos: CGFloat, angle: CGFloat, depth: CGFloat)]] = []
        
        for cv in cutoutVertices {
            var assignedToGroup = -1
            
            for (groupIdx, group) in groupedVertices.enumerated() {
                for gv in group {
                    let axialDist = abs(cv.axialPos - gv.axialPos)
                    let angleDist = min(abs(cv.angle - gv.angle), 360 - abs(cv.angle - gv.angle))
                    
                    if axialDist < axialBucketSize * 2 && angleDist < angleBucketSize * 2 {
                        assignedToGroup = groupIdx
                        break
                    }
                }
                if assignedToGroup >= 0 { break }
            }
            
            if assignedToGroup >= 0 {
                groupedVertices[assignedToGroup].append(cv)
            } else {
                groupedVertices.append([cv])
            }
        }
        
        for group in groupedVertices {
            guard group.count >= 3 else { continue }
            
            var minAxial = CGFloat.greatestFiniteMagnitude
            var maxAxial = -CGFloat.greatestFiniteMagnitude
            var minAngle = CGFloat.greatestFiniteMagnitude
            var maxAngle = -CGFloat.greatestFiniteMagnitude
            var maxDepth: CGFloat = 0
            
            for cv in group {
                minAxial = min(minAxial, cv.axialPos)
                maxAxial = max(maxAxial, cv.axialPos)
                minAngle = min(minAngle, cv.angle)
                maxAngle = max(maxAngle, cv.angle)
                maxDepth = max(maxDepth, cv.depth)
            }
            
            var centerAngle: CGFloat
            if maxAngle - minAngle > 180 {
                if minAngle < 0 {
                    centerAngle = (maxAngle + (minAngle + 360)) / 2.0
                    if centerAngle > 180 { centerAngle -= 360 }
                } else {
                    centerAngle = ((maxAngle - 360) + minAngle) / 2.0
                    if centerAngle < -180 { centerAngle += 360 }
                }
            } else {
                centerAngle = (minAngle + maxAngle) / 2.0
            }
            
            let centerPosition = (minAxial + maxAxial) / 2.0
            let width = maxAxial - minAxial
            let height = maxAngle - minAngle
            
            let cutout = Cutout(
                centerPosition: centerPosition,
                centerAngle: centerAngle,
                width: max(width, 5),
                height: max(height, 20),
                depth: maxDepth,
                vertices: group.map { $0.vertex }
            )
            
            cutouts.append(cutout)
        }
        
        return cutouts
    }
}
