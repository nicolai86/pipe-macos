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
    var feedRate: CGFloat = 1000.0 // mm/min
    var rapidRate: CGFloat = 3000.0 // mm/min
    var safeHeight: CGFloat = 25.0 // mm
    var pierceHeight: CGFloat = 3.8 // mm — standoff during pierce, from Hypertherm cut charts
    var cutHeight: CGFloat = 3.2 // mm
    
    // Kerf & Comp
    var kerfWidth: CGFloat = 2.0 // mm
    var enableKerfComp: Bool = true
    
    // Advanced Geometric Lead-in
    var leadInDistance: CGFloat = 5.0
    var leadInAngle: CGFloat = 90.0 // Degrees of the sweep arc
    var leadInAngleDistance: CGFloat = 3.0 // Radius of the sweep arc
    
    var overburnDegrees: CGFloat = 10.0  // Exact degrees to overburn
    var useSimCNC: Bool = true
    
    // Per-Axis Motor Acceleration Limits (mm/s^2 and degrees/s^2)
    var maxAccelX: CGFloat = 500.0
    var maxAccelY: CGFloat = 500.0
    var maxAccelZ: CGFloat = 300.0
    var maxAccelA: CGFloat = 1000.0
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
    var finalF: CGFloat = 0.0
}

// MARK: - GCode Generator
class GCodeGenerator {
    var settings = GCodeSettings()
    
    // MARK: - Single Part Generation
    func generateGCode(for stock: StockInfo, rollOffset: CGFloat = 0.0) -> String {
        var gcode: [String] = []
        gcode.append(contentsOf: generateHeader(stock: stock))
        gcode.append(contentsOf: generateStartupSequence(totalLength: stock.length))
        
        let sortedFeatures = sortFeatures(stock.features)
        var currentA: CGFloat = 0
        
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
        
        gcode.append(contentsOf: generateEndSequence())
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

        var lines: [String] = [
            "%",
            "(PACK G-CODE  —  \(entries.count) PIECE\(entries.count == 1 ? "" : "S"))",
            "(GENERATED: \(formatter.string(from: Date())))",
            refStock.profile == .round
                ? "(STOCK: \(refStock.profile.rawValue)  OD \(fmt(refStock.od ?? 0))mm)"
                : "(STOCK: \(refStock.profile.rawValue)  \(fmt(refStock.odX ?? 0))×\(fmt(refStock.odY ?? 0))mm)",
            "(TOTAL STOCK LENGTH: \(fmt(totalLength))mm)",
            "",
            "G21             ; metric mode",
            "G90             ; absolute positioning",
            "G40             ; cancel cutter comp",
            "G49             ; cancel tool length offset",
            "G92 X\(fmt(totalLength)) Y0 Z0 A0 ; set current position as right-most free end",
            "",
            "G0 Z\(fmt(settings.safeHeight))     ; move to safe height",
            "M5              ; torch off (ensure)",
            "",
            "; === Cutting Pattern (free-end to chuck, \(entries.count) piece\(entries.count == 1 ? "" : "s")) ===",
        ]

        let ordered = entries.sorted { $0.packStartX > $1.packStartX }
        var currentA: CGFloat = 0

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

        lines += generateEndSequence()
        return lines.joined(separator: "\n")
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
        var compCode = "G42"

        if isInternal {
            // Internal cut: Force CW in machine space. Scrap is on the Right.
            if signedArea > 0 { finalPath.reverse() }
            isScrapLeft = false
            compCode = "G42"
        } else {
            // Sever Cuts: Force CCW in machine space. Scrap is on the Left.
            if feature.type == .startCut {
                if finalPath.last!.a < finalPath.first!.a { finalPath.reverse() }
                isScrapLeft = true
                compCode = "G41"
            } else if feature.type == .endCut {
                if finalPath.last!.a > finalPath.first!.a { finalPath.reverse() }
                isScrapLeft = true
                compCode = "G41"
            }
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
        
        // ====================================================================
        // --- SOTA: KERF-AWARE LEAD-IN LENGTHENING ---
        // Controller G41/G42 buffer crashes if lead-in <= tool radius.
        // We mathematically clamp the linear portion to be strictly > kerfWidth.
        // ====================================================================
        let safeLeadL = settings.enableKerfComp ? max(settings.leadInDistance, settings.kerfWidth + 0.1) : settings.leadInDistance
        let leadL = safeLeadL
        
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


        // --- Kinematic Mapping (Tool Center Point) ---
        var machinePoints: [MachinePoint] = []
        var prevAm: CGFloat? = nil

        for pt in finalPath {
            var mp = convertToMachine(pt: pt, stock: stock)
            
            if let prev = prevAm {
                while mp.Am - prev > 180.0 { mp.Am -= 360.0 }
                while mp.Am - prev < -180.0 { mp.Am += 360.0 }
            } else if isPackMode {
                while mp.Am - currentA > 180.0 { mp.Am -= 360.0 }
                while mp.Am - currentA < -180.0 { mp.Am += 360.0 }
            }
            
            prevAm = mp.Am
            machinePoints.append(mp)
        }

        // ====================================================================
        // --- SOTA: NON-LINEAR KINEMATIC JACOBIAN VELOCITY PROFILING ---
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

        // 5. Convert Safe Surface Speeds to SimCNC G94 4D Spoofed Feedrates
        for i in 0..<segments.count {
            // Take the average safe surface speed across this segment
            var vSafe = (vFinal[i] + vFinal[i+1]) / 2.0
            if vSafe < 1.0 { vSafe = 1.0 } // Protect against full dead-stops causing div/0

            // Convert to execution time, then back up to SimCNC machine vector feedrate
            let dt = segments[i].dS / vSafe
            let fG94 = dt > 1e-6 ? segments[i].dMachine / dt : settings.rapidRate

            segments[i].finalF = min(fG94, settings.rapidRate)
        }

        // --- G-Code Output Generation ---
        var lines: [String] = []
        let typeStr = feature.type.rawValue.capitalized
        let directionStr = isInternal ? "CW (Physical CCW)" : "CCW (Physical CW)"
        lines.append("; --- \(typeStr)  X=\(fmt(feature.xCenter + packStartX))mm  A=\(fmt(feature.aCenterDeg + rollOffset))° ---")
        lines.append("; TCP Active | Swirl Comp: \(directionStr) | Tangential OB | Comp: \(compCode)")
        
        let pierceMp = machinePoints[0]
        lines.append("G0 X\(fmt(pierceMp.Xm)) Y\(fmt(pierceMp.Ym)) A\(fmt(pierceMp.Am))")
        lines.append("G0 Z\(fmt(pierceMp.Zm + settings.safeHeight))  ; safe height")
        lines.append("G0 Z\(fmt(pierceMp.Zm + settings.pierceHeight)) ; lower to pierce height")
        lines.append("M3 S1                         ; torch on")

        // Executing the Profiled Trajectory + Dynamic G41/G42 Injection
        for i in 1..<machinePoints.count {
            let curr = machinePoints[i]
            let seg = segments[i-1]
            
            var cmdPrefix = "G1 "
            
            // Apply Kerf Comp strictly on the first linear interpolated lead-in move
            if i == 1 && settings.enableKerfComp {
                cmdPrefix = "G1 \(compCode) "
            }
            
            lines.append("\(cmdPrefix)X\(fmt(curr.Xm)) Y\(fmt(curr.Ym)) Z\(fmt(curr.Zm + settings.cutHeight)) A\(fmt(curr.Am)) F\(fmt(seg.finalF))")
        }

        // Torch Off and G40 Cancel
        let g40Cancel = settings.enableKerfComp ? "G40 " : ""
        lines.append("M5 \(g40Cancel)                         ; torch off & cancel kerf comp")
        return (lines, machinePoints.last!.Am)
    }

    // MARK: - Mathematical Core: HSS Kinematic Mapping
    
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
        if stock.profile == .round {
            baselineZ = (stock.od ?? max(stock.odX ?? 50, stock.odY ?? 50)) / 2.0
        } else {
            baselineZ = (stock.odY ?? stock.od ?? 50.0) / 2.0
        }
        let relativeZm = Zm - baselineZ

        return MachinePoint(Xm: pt.x, Ym: Ym, Zm: relativeZm, Am: machineA, matX: pt.x, matU: profile.u, matV: profile.v)
    }

    // MARK: - Utilities
    
    private func fmt(_ val: CGFloat) -> String {
        return String(format: "%.3f", val)
    }

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
            header.append("(OD: \(fmt(stock.od ?? 0))mm)")
        } else {
            header.append("(OD: \(fmt(stock.odX ?? 0))mm x \(fmt(stock.odY ?? 0))mm)")
        }
        
        header.append("(LENGTH: \(fmt(stock.length))mm)")
        return header
    }

    private func generateStartupSequence(totalLength: CGFloat, packMode: Bool = false, count: Int = 1) -> [String] {
        return [
            "G21             ; metric mode",
            "G90             ; absolute positioning",
            "G40             ; cancel cutter comp",
            "G49             ; cancel tool length offset",
            "G92 X\(fmt(totalLength)) Y0 Z0 A0 ; set current position as right-most free end",
            "",
            "G0 Z\(fmt(settings.safeHeight))     ; move to safe height",
            "M5              ; torch off (ensure)",
            "",
            packMode ? "; === Cutting Pattern (right-to-left, \(count) piece\(count == 1 ? "" : "s")) ===" : "; === Cutting Pattern ==="
        ]
    }

    private func generateEndSequence() -> [String] {
        return [
            "; === Program End ===",
            "M5              ; torch off (redundant safety)",
            "G0 Z\(fmt(settings.safeHeight))  ; retract to safe height",
            "G0 X0 Y0 A0     ; return to home (TCP centered)",
            "M30             ; end of program",
            "%"
        ]
    }
}
