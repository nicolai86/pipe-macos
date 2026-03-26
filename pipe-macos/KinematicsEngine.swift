import Foundation

// MARK: - Kinematics Engine

/// Transforms a 2D surface-space toolpath (X, A) into 4-axis machine coordinates (Xm, Ym, Zm, Am).
///
/// Applies three passes in sequence:
///   1. TCP conversion — maps each surface point through the cross-section profile to machine XYZ
///   2. ADLS singularity damping — smooths A-axis velocity blowup at HSS corners
///   3. Nonlinear error compensation — recursively subdivides segments where G01 interpolation
///      deviates from the true rotary path beyond the configured tolerance
struct KinematicsEngine {
    let settings: GCodeSettings

    // MARK: - Public API

    /// Converts a planned surface-space path to machine coordinates.
    ///
    /// - Parameter initialMachineAm: When non-nil, the first machine point's Am is wrapped
    ///   relative to this value (used in pack mode to maintain inter-feature continuity).
    ///   Pass `nil` in single-piece mode — the 2D shift in `ToolpathPlanner` handles continuity.
    func convert(
        plannedFeature: PlannedFeature,
        stock: StockInfo,
        initialMachineAm: CGFloat?
    ) -> [MachinePoint] {
        let path = plannedFeature.plannedPath
        guard !path.points.isEmpty else { return [] }

        let rawPoints = tcpConvert(path: path, stock: stock, initialMachineAm: initialMachineAm)
        let dampedPoints = applyADLS(rawPoints: rawPoints, stock: stock)
        return applyNonlinearCompensation(dampedPoints: dampedPoints, stock: stock)
    }

    // MARK: - TCP Conversion

    private func tcpConvert(
        path: PlannedPath,
        stock: StockInfo,
        initialMachineAm: CGFloat?
    ) -> [MachinePoint] {
        var result: [MachinePoint] = []
        result.reserveCapacity(path.points.count)
        var prevAm: CGFloat? = initialMachineAm
        for pt in path.points {
            var mp = convertToMachine(pt: pt, stock: stock)
            if let prev = prevAm {
                while mp.Am - prev > 180.0  { mp.Am -= 360.0 }
                while mp.Am - prev < -180.0 { mp.Am += 360.0 }
            }
            prevAm = mp.Am
            result.append(mp)
        }
        return result
    }

    private func getProfilePoint(
        angleDeg: CGFloat,
        stock: StockInfo
    ) -> (u: CGFloat, v: CGFloat, Nu: CGFloat, Nv: CGFloat) {
        if stock.profile == .round {
            let r = (stock.od ?? max(stock.odX ?? 50, stock.odY ?? 50)) / 2.0
            let rad = angleDeg * .pi / 180.0
            return (r * cos(rad), r * sin(rad), cos(rad), sin(rad))
        }

        let W = stock.odX ?? stock.od ?? 50.0
        let H = stock.odY ?? stock.od ?? 50.0
        let R = stock.cornerRadius ?? (min(W, H) * 0.1)
        let w = W - 2 * R
        let h = H - 2 * R
        let rad = angleDeg * .pi / 180.0
        let cosPhi = cos(rad)
        let sinPhi = sin(rad)
        var bestT: CGFloat = .greatestFiniteMagnitude
        var bestU: CGFloat = 0, bestV: CGFloat = 0
        var bestNu: CGFloat = 0, bestNv: CGFloat = 0

        if cosPhi > 1e-6 {
            let t = (W / 2) / cosPhi
            if abs(t * sinPhi) <= h / 2 {
                bestT = t; bestU = W / 2; bestV = t * sinPhi; bestNu = 1; bestNv = 0
            }
        }
        if cosPhi < -1e-6 {
            let t = (-W / 2) / cosPhi
            if abs(t * sinPhi) <= h / 2 && t < bestT {
                bestT = t; bestU = -W / 2; bestV = t * sinPhi; bestNu = -1; bestNv = 0
            }
        }
        if sinPhi > 1e-6 {
            let t = (H / 2) / sinPhi
            if abs(t * cosPhi) <= w / 2 && t < bestT {
                bestT = t; bestU = t * cosPhi; bestV = H / 2; bestNu = 0; bestNv = 1
            }
        }
        if sinPhi < -1e-6 {
            let t = (-H / 2) / sinPhi
            if abs(t * cosPhi) <= w / 2 && t < bestT {
                bestT = t; bestU = t * cosPhi; bestV = -H / 2; bestNu = 0; bestNv = -1
            }
        }

        let centers: [(CGFloat, CGFloat)] = [
            (w / 2, h / 2), (-w / 2, h / 2), (-w / 2, -h / 2), (w / 2, -h / 2)
        ]
        for (cx, cy) in centers {
            let b = -2 * (cx * cosPhi + cy * sinPhi)
            let c = cx * cx + cy * cy - R * R
            let disc = b * b - 4 * c
            if disc >= 0 {
                for t in [(-b - sqrt(disc)) / 2, (-b + sqrt(disc)) / 2] {
                    if t > 1e-6 && t < bestT {
                        let u = t * cosPhi; let v = t * sinPhi
                        if ((cx > 0) ? (u >= cx - 1e-4) : (u <= cx + 1e-4))
                            && ((cy > 0) ? (v >= cy - 1e-4) : (v <= cy + 1e-4)) {
                            bestT = t; bestU = u; bestV = v
                            let len = sqrt(pow(u - cx, 2) + pow(v - cy, 2))
                            bestNu = (u - cx) / len; bestNv = (v - cy) / len
                        }
                    }
                }
            }
        }
        return bestT == .greatestFiniteMagnitude ? (0, H / 2, 0, 1) : (bestU, bestV, bestNu, bestNv)
    }

    private func convertToMachine(pt: ToolpathPoint, stock: StockInfo) -> MachinePoint {
        let profile = getProfilePoint(angleDeg: pt.a, stock: stock)
        let thetaRad = atan2(profile.Nu, profile.Nv)
        let Ym = profile.u * cos(thetaRad) - profile.v * sin(thetaRad)
        let Zm = profile.u * sin(thetaRad) + profile.v * cos(thetaRad)
        let baselineZ: CGFloat = stock.profile == .round
            ? (stock.od ?? max(stock.odX ?? 50, stock.odY ?? 50)) / 2.0
            : (stock.odY ?? stock.od ?? 50.0) / 2.0
        let isCorner = stock.profile != .round
            && !(abs(profile.Nu) > 0.999 || abs(profile.Nv) > 0.999)
        return MachinePoint(
            Xm: pt.x, Ym: Ym, Zm: Zm - baselineZ, Am: thetaRad * 180.0 / .pi,
            matX: pt.x, matU: profile.u, matV: profile.v,
            isCorner: isCorner
        )
    }

    // MARK: - ADLS Singularity Damping

    /// WHY: On rectangular stock, the kinematic Jacobian becomes singular at corners
    /// (radius of rotation → 0), causing required A-axis angular velocity to approach
    /// infinity to maintain constant surface speed. ADLS dynamically damps these
    /// velocity blow-ups by scaling the A-axis increment using a manipulability metric.
    private func applyADLS(rawPoints: [MachinePoint], stock: StockInfo) -> [MachinePoint] {
        guard !rawPoints.isEmpty else { return [] }
        var result: [MachinePoint] = []
        result.reserveCapacity(rawPoints.count)
        result.append(rawPoints[0])

        let baselineZ: CGFloat = stock.profile == .round
            ? (stock.od ?? 50.0) / 2.0
            : (stock.odY ?? stock.od ?? 50.0) / 2.0

        for i in 1..<rawPoints.count {
            let prevDamped = result.last!
            let currRaw = rawPoints[i]

            guard settings.enableSingularityDamping else {
                result.append(currRaw); continue
            }

            let dx = currRaw.matX - prevDamped.matX
            let du = currRaw.matU - prevDamped.matU
            let dv = currRaw.matV - prevDamped.matV
            let ds_cartesian = sqrt(dx * dx + du * du + dv * dv)
            let target_dA = currRaw.Am - prevDamped.Am

            // Manipulability: ratio of surface travel to angular change.
            // High on flat faces (no damping needed), low at corners (damp heavily).
            let m = abs(target_dA) > 1e-6
                ? ds_cartesian / abs(target_dA)
                : settings.dampingThreshold

            let lambda: CGFloat
            if m < settings.dampingThreshold {
                let ratio = m / settings.dampingThreshold
                lambda = settings.singularityDampingFactor * (1.0 - pow(ratio, 2))
            } else {
                lambda = 0.0
            }

            let denominator = (ds_cartesian * ds_cartesian) + pow(lambda, 2)
            let dampingRatio = denominator > 1e-9
                ? (ds_cartesian * ds_cartesian) / denominator : 1.0
            let newAm = prevDamped.Am + (target_dA * dampingRatio)

            let thetaRad = newAm * .pi / 180.0
            let newYm = currRaw.matU * cos(thetaRad) - currRaw.matV * sin(thetaRad)
            let newZm = currRaw.matU * sin(thetaRad) + currRaw.matV * cos(thetaRad)

            var dampedPt = currRaw
            dampedPt.Am = newAm
            dampedPt.Ym = newYm
            dampedPt.Zm = newZm - baselineZ
            result.append(dampedPt)
        }
        return result
    }

    // MARK: - Nonlinear Error Compensation

    /// WHY: Linear G01 interpolation of simultaneous X, Y, Z, A motion traces a complex
    /// curve (not a straight line) due to the A-axis rotation. This recursive midpoint
    /// subdivision checks whether the true rotary midpoint deviates from linear interpolation
    /// beyond the configured tolerance, inserting extra waypoints where needed.
    private func applyNonlinearCompensation(dampedPoints: [MachinePoint], stock: StockInfo) -> [MachinePoint] {
        guard !dampedPoints.isEmpty else { return [] }
        var result: [MachinePoint] = []
        result.reserveCapacity(dampedPoints.count)
        result.append(dampedPoints[0])
        for i in 1..<dampedPoints.count {
            appendWithCompensation(into: &result, sMp: result.last!, eMp: dampedPoints[i], stock: stock)
        }
        return result
    }

    private func appendWithCompensation(
        into output: inout [MachinePoint],
        sMp: MachinePoint,
        eMp: MachinePoint,
        stock: StockInfo,
        depth: Int = 0
    ) {
        if settings.enableNonlinearErrorCompensation && depth < 10 {
            let midU = (sMp.matU + eMp.matU) / 2.0
            let midV = (sMp.matV + eMp.matV) / 2.0
            let midAm = (sMp.Am + eMp.Am) / 2.0
            let thetaRad = midAm * .pi / 180.0
            let trueMidYm = midU * cos(thetaRad) - midV * sin(thetaRad)
            let baselineZ: CGFloat = stock.profile == .round
                ? (stock.od ?? 50.0) / 2.0
                : (stock.odY ?? stock.od ?? 50.0) / 2.0
            let trueMidZm = (midU * sin(thetaRad) + midV * cos(thetaRad)) - baselineZ
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
                appendWithCompensation(into: &output, sMp: sMp,    eMp: midPt, stock: stock, depth: depth + 1)
                appendWithCompensation(into: &output, sMp: midPt, eMp: eMp,    stock: stock, depth: depth + 1)
                return
            }
        }
        output.append(eMp)
    }
}
