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

        // Shift path to pack space and apply roll offset
        let packPath = localPath.map { ToolpathPoint(x: $0.x + packStartX, a: $0.a + rollOffset) }

        // Shift everything by the nearest multiple of 360° to minimise A-axis travel
        let rawPierceA = packPath[0].a
        let shift = round((currentA - rawPierceA) / 360.0) * 360.0
        let adjPath = packPath.map { ToolpathPoint(x: $0.x, a: $0.a + shift) }

        // Apply exact mathematical overburn directly to the Toolpath points
        var finalPath = adjPath
        var finalA = adjPath.last!.a
        if feature.type == .startCut || feature.type == .endCut {
            finalA = finalA + settings.overburnDegrees
            finalPath.append(ToolpathPoint(x: adjPath.last!.x, a: finalA))
        } else if (feature.type == .hole || feature.type == .cutout) && adjPath.count > 1 {
            let dir: CGFloat = (adjPath[1].a - adjPath[0].a) >= 0 ? 1 : -1
            finalA = finalA + dir * settings.overburnDegrees
            finalPath.append(ToolpathPoint(x: adjPath.last!.x, a: finalA))
        }

        // --- Kinematic Mapping (Tool Center Point) ---
        var machinePoints: [MachinePoint] = []
        var prevAm: CGFloat? = nil

        for pt in finalPath {
            var mp = convertToMachine(pt: pt, stock: stock)
            
            // Continuous A-axis unwrapping (prevents violent 360 degree whips)
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

        // Calculate Pierce Point dynamically based on feature type
        var piercePt2D = ToolpathPoint(x: adjPath[0].x, a: adjPath[0].a)
        if feature.type == .startCut {
            piercePt2D.x -= settings.leadInDistance
        } else if feature.type == .endCut {
            piercePt2D.x += settings.leadInDistance
        } else if feature.type == .hole || feature.type == .cutout {
            piercePt2D = ToolpathPoint(x: feature.xCenter + packStartX, a: feature.aCenterDeg + rollOffset + shift)
        } else if feature.type == .notch {
            piercePt2D.x = feature.xCenter < stock.length / 2 ? packStartX - settings.leadInDistance : packEndX + settings.leadInDistance
        }

        var pierceMp = convertToMachine(pt: piercePt2D, stock: stock)
        while pierceMp.Am - machinePoints[0].Am > 180.0 { pierceMp.Am -= 360.0 }
        while pierceMp.Am - machinePoints[0].Am < -180.0 { pierceMp.Am += 360.0 }

        // --- G-Code Output Generation ---
        var lines: [String] = []
        lines.append("; --- \(feature.type.rawValue.capitalized)  X=\(fmt(feature.xCenter + packStartX))mm  A=\(fmt(feature.aCenterDeg + rollOffset))° ---")
        lines.append("; Offline TCP Engaged: Y/Z interpolated, G94 Velocity Profiled")
        
        // 1. Rapid to pierce coordinates & safe height
        lines.append("G0 X\(fmt(pierceMp.Xm)) Y\(fmt(pierceMp.Ym)) A\(fmt(pierceMp.Am))")
        lines.append("G0 Z\(fmt(pierceMp.Zm + settings.safeHeight))")
        lines.append("M3 S1                         ; torch on")
        lines.append("G1 Z\(fmt(pierceMp.Zm + settings.cutHeight)) F\(fmt(settings.feedRate * 0.5)) ; plunge to cut height")

        // 2. Lead-in move to first point (with G94 velocity)
        let pt0 = machinePoints[0]
        let pt0_dS = sqrt(pow(pt0.matX - pierceMp.matX, 2) + pow(pt0.matU - pierceMp.matU, 2) + pow(pt0.matV - pierceMp.matV, 2))
        let pt0_dt = pt0_dS / settings.feedRate
        let pt0_dM = sqrt(pow(pt0.Xm - pierceMp.Xm, 2) + pow(pt0.Ym - pierceMp.Ym, 2) + pow(pt0.Zm - pierceMp.Zm, 2) + pow(pt0.Am - pierceMp.Am, 2))
        var pt0_F = settings.feedRate
        if pt0_dt > 1e-6 { pt0_F = min(pt0_dM / pt0_dt, settings.rapidRate) }
        lines.append("G1 X\(fmt(pt0.Xm)) Y\(fmt(pt0.Ym)) Z\(fmt(pt0.Zm + settings.cutHeight)) A\(fmt(pt0.Am)) F\(fmt(pt0_F))")

        // 3. Main Contour Execution with SimCNC Feedrate spoofing
        for i in 1..<machinePoints.count {
            let prev = machinePoints[i-1]
            let curr = machinePoints[i]

            // Calculate true surface distance moved (Material Space)
            let dx = curr.matX - prev.matX
            let du = curr.matU - prev.matU
            let dv = curr.matV - prev.matV
            let dS = sqrt(dx*dx + du*du + dv*dv)

            // Calculate required execution time to maintain cut chart speed
            let dt = dS / settings.feedRate

            // Calculate physical 4-axis machine distance SimCNC thinks it is moving
            let dXm = curr.Xm - prev.Xm
            let dYm = curr.Ym - prev.Ym
            let dZm = curr.Zm - prev.Zm
            let dAm = curr.Am - prev.Am
            let dMachine = sqrt(dXm*dXm + dYm*dYm + dZm*dZm + dAm*dAm)

            // Spoof G94 Feedrate
            var fG94 = settings.feedRate
            if dt > 1e-6 {
                fG94 = min(dMachine / dt, settings.rapidRate) // Clamp max velocity to prevent corner aliasing spikes
            }

            lines.append("G1 X\(fmt(curr.Xm)) Y\(fmt(curr.Ym)) Z\(fmt(curr.Zm + settings.cutHeight)) A\(fmt(curr.Am)) F\(fmt(fG94))")
        }

        lines.append("M5                            ; torch off")
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
            
            // Failsafe (should never trigger unless bad math)
            if bestT == .greatestFiniteMagnitude { return (0, H/2, 0, 1) }
            
            return (bestU, bestV, bestNu, bestNv)
        }
    }

    private func convertToMachine(pt: ToolpathPoint, stock: StockInfo) -> MachinePoint {
        let profile = getProfilePoint(angleDeg: pt.a, stock: stock)
        
        // Theta is the A-axis rotation required to point the surface normal straight UP (+Z)
        let thetaRad = atan2(profile.Nu, profile.Nv)

        // Machine Kinematics Calculation
        let Ym = profile.u * cos(thetaRad) - profile.v * sin(thetaRad)
        let Zm = profile.u * sin(thetaRad) + profile.v * cos(thetaRad)
        let machineA = thetaRad * 180.0 / .pi

        // Offset Zm so Z=0 perfectly aligns with the top surface of the unrotated stock.
        // This preserves standard machine zeroing workflows.
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
