import Foundation

// MARK: - Planned Path

/// The result of 2D toolpath planning for a single feature.
/// Contains the fully-prepared surface-space path (pierce-reordered,
/// chirality-correct, kerf-offset, overburn + lead-in applied).
struct PlannedPath {
    let points: [ToolpathPoint]
    /// Whether this feature is an internal cut (hole/cutout/notch).
    /// Forwarded to the emitter for the THC/direction comment only.
    let isInternal: Bool
}

// MARK: - Toolpath Planner

/// Transforms a raw SurfaceFeature into a planned 2D surface-space toolpath.
///
/// All operations work in (X, A) surface coordinates.
/// No machine kinematics are applied at this stage.
struct ToolpathPlanner {
    let settings: GCodeSettings

    // MARK: - Public API

    func plan(
        feature: SurfaceFeature,
        stock: StockInfo,
        packStartX: CGFloat,
        rollOffset: CGFloat,
        previousMachineAm: CGFloat
    ) -> PlannedPath {
        guard let localPath = feature.path, localPath.count > 1 else {
            return PlannedPath(points: [], isInternal: false)
        }

        // 1. Apply pack + roll offsets
        let packPath = localPath.map {
            ToolpathPoint(x: $0.x + packStartX, a: $0.a + rollOffset)
        }

        // 2. Shift entire path so pierce point is continuous with previous feature
        let rawPierceA = packPath[0].a
        let shift = round((previousMachineAm - rawPierceA) / 360.0) * 360.0
        var adjPath = packPath.map { ToolpathPoint(x: $0.x, a: $0.a + shift) }

        let OD: CGFloat = stock.profile == .round
            ? (stock.od ?? 50.0)
            : max(stock.odX ?? 50.0, stock.odY ?? 50.0)
        let k = (.pi * OD) / 360.0

        // 3. Build geodesic encode/decode for kerf offset
        // For round stock: s = A·k exactly (exact for cylinders).
        // For HSS: s(A) is piecewise nonlinear — geodesic gives a correct offset.
        let encodeA: (CGFloat) -> CGFloat
        let decodeS: (CGFloat) -> CGFloat
        if stock.profile != .round,
           let oX = stock.odX, let oY = stock.odY,
           let cr = stock.cornerRadius {
            let geo = HSSGeodesicProfile(odX: oX, odY: oY, cornerRadius: cr)
            encodeA = { geo.encode($0) }
            decodeS = { geo.decode($0) }
        } else {
            encodeA = { $0 * k }
            decodeS = { $0 / k }
        }

        let isInternal = feature.type == .hole || feature.type == .cutout || feature.type == .notch

        // 4. Pierce point selection + A-continuity wrap
        if isInternal && adjPath.count > 2 {
            adjPath = selectPiercePointInternal(path: adjPath, k: k)
        } else if (feature.type == .startCut || feature.type == .endCut) && adjPath.count > 1 {
            adjPath = selectPiercePointSever(path: adjPath, featureType: feature.type)
        }

        // 5. Chirality enforcement (plasma swirl direction)
        var finalPath = adjPath
        var signedArea: CGFloat = 0
        for i in 0..<finalPath.count - 1 {
            signedArea += (finalPath[i].x * (finalPath[i + 1].a * k)
                         - finalPath[i + 1].x * (finalPath[i].a * k))
        }

        var isScrapLeft = false
        if isInternal {
            if signedArea > 0 { finalPath.reverse() }
        } else {
            if feature.type == .startCut {
                if finalPath.last!.a < finalPath.first!.a { finalPath.reverse() }
                isScrapLeft = true
            } else if feature.type == .endCut {
                if finalPath.last!.a > finalPath.first!.a { finalPath.reverse() }
            }
        }

        // 6. Kerf offset
        if settings.enableKerfComp {
            let kerfRadius = isScrapLeft
                ? (settings.kerfWidth / 2.0)
                : -(settings.kerfWidth / 2.0)
            finalPath = applyOfflineKerfOffset(
                to: finalPath,
                radius: kerfRadius,
                isClosed: isInternal,
                encode: encodeA,
                decode: decodeS
            )
        }

        // 7. Overburn extension
        if finalPath.count > 2 {
            let overburnDist = settings.overburnDegrees * k
            let pLast = finalPath.last!
            let pPrev = finalPath[finalPath.count - 2]
            let dx = pLast.x - pPrev.x
            let da_mm = (pLast.a - pPrev.a) * k
            let len = sqrt(dx * dx + da_mm * da_mm)
            if len > 0.001 {
                finalPath.append(ToolpathPoint(
                    x: pLast.x + (dx / len) * overburnDist,
                    a: ((pLast.a * k) + (da_mm / len) * overburnDist) / k
                ))
            }
        }

        // 8. Lead-in geometry
        let leadInPoints = buildLeadIn(
            path: finalPath, k: k,
            isInternal: isInternal, isScrapLeft: isScrapLeft,
            featureType: feature.type
        )
        finalPath.insert(contentsOf: leadInPoints, at: 0)

        return PlannedPath(points: finalPath, isInternal: isInternal)
    }

    // MARK: - Pierce Point Selection

    private func selectPiercePointInternal(path: [ToolpathPoint], k: CGFloat) -> [ToolpathPoint] {
        var maxLen: CGFloat = -1
        var bestIdx = 0
        for i in 0..<path.count - 1 {
            let dx = path[i + 1].x - path[i].x
            let da_mm = (path[i + 1].a - path[i].a) * k
            let len = sqrt(dx * dx + da_mm * da_mm)
            if len > maxLen { maxLen = len; bestIdx = i }
        }
        let midPt = ToolpathPoint(
            x: (path[bestIdx].x + path[bestIdx + 1].x) / 2.0,
            a: (path[bestIdx].a + path[bestIdx + 1].a) / 2.0
        )
        var newPath: [ToolpathPoint] = [midPt]
        newPath.append(contentsOf: path[(bestIdx + 1)..<(path.count - 1)])
        newPath.append(contentsOf: path[0...bestIdx])
        newPath.append(midPt)

        var continuousPath = [newPath[0]]
        for i in 1..<newPath.count {
            var currA = newPath[i].a
            let prevA = continuousPath.last!.a
            while currA - prevA > 180.0  { currA -= 360.0 }
            while currA - prevA < -180.0 { currA += 360.0 }
            continuousPath.append(ToolpathPoint(x: newPath[i].x, a: currA))
        }
        return continuousPath
    }

    private func selectPiercePointSever(
        path: [ToolpathPoint],
        featureType: SurfaceFeatureType
    ) -> [ToolpathPoint] {
        var bestIdx = 0
        var minDiff = CGFloat.greatestFiniteMagnitude
        for (i, pt) in path.enumerated() {
            let modA = abs(pt.a.truncatingRemainder(dividingBy: 90.0))
            let diff = min(modA, 90.0 - modA)
            if diff < minDiff { minDiff = diff; bestIdx = i }
        }
        guard bestIdx > 0 else { return path }
        var corePath = path
        if abs(corePath.last!.a - (corePath.first!.a + 360.0)) < 1.0 {
            corePath.removeLast()
        }
        let reordered = Array(corePath[bestIdx...]) + Array(corePath[..<bestIdx])
        var newPath: [ToolpathPoint] = [reordered[0]]
        for i in 1..<reordered.count {
            var current_A = reordered[i].a
            let prev_A = newPath.last!.a
            while current_A - prev_A > 180.0  { current_A -= 360.0 }
            while current_A - prev_A < -180.0 { current_A += 360.0 }
            newPath.append(ToolpathPoint(x: reordered[i].x, a: current_A))
        }
        let firstPt = newPath.first!
        var closeA = firstPt.a
        let lastA = newPath.last!.a
        while closeA - lastA > 180.0  { closeA -= 360.0 }
        while closeA - lastA < -180.0 { closeA += 360.0 }
        newPath.append(ToolpathPoint(x: firstPt.x, a: closeA))
        return newPath
    }

    // MARK: - Lead-In

    private func buildLeadIn(
        path: [ToolpathPoint],
        k: CGFloat,
        isInternal: Bool,
        isScrapLeft: Bool,
        featureType: SurfaceFeatureType
    ) -> [ToolpathPoint] {
        let p0 = path[0]
        let p1 = path.count > 1 ? path[1] : ToolpathPoint(x: p0.x + 1, a: p0.a)
        let dx = p1.x - p0.x
        let da_mm = (p1.a - p0.a) * k
        let gamma = atan2(da_mm, dx)
        let leadR = settings.leadInAngleDistance
        let leadTheta = settings.leadInAngle * .pi / 180.0
        let leadL = settings.leadInDistance
        let sideMultiplier: CGFloat = isScrapLeft ? 1.0 : -1.0
        var points: [ToolpathPoint] = []

        if featureType == .startCut || featureType == .endCut {
            // Purely rotational lead-in for sever cuts — moving in X would waste stock
            let leadAngleDeg = (leadL + leadR) / k
            let entryA = p0.a - sideMultiplier * leadAngleDeg
            let steps = 5
            for i in 0..<steps {
                let t = CGFloat(i) / CGFloat(steps)
                points.append(ToolpathPoint(x: p0.x, a: entryA + sideMultiplier * leadAngleDeg * t))
            }
        } else if leadTheta > 0.01 && leadR > 0.01 {
            let Cx = p0.x + leadR * cos(gamma + sideMultiplier * .pi / 2.0)
            let Cy = (p0.a * k) + leadR * sin(gamma + sideMultiplier * .pi / 2.0)
            let startAngle = (gamma - sideMultiplier * .pi / 2.0) - sideMultiplier * leadTheta
            let arcSteps = max(4, Int(leadTheta * 180 / .pi / 15))
            for i in 0..<arcSteps {
                let t = startAngle + sideMultiplier * (leadTheta * CGFloat(i) / CGFloat(arcSteps))
                points.append(ToolpathPoint(
                    x: Cx + leadR * cos(t),
                    a: (Cy + leadR * sin(t)) / k
                ))
            }
            let firstArcPt = points.first ?? p0
            let entryTangent = gamma - sideMultiplier * leadTheta
            points.insert(ToolpathPoint(
                x: firstArcPt.x - leadL * cos(entryTangent),
                a: ((firstArcPt.a * k) - leadL * sin(entryTangent)) / k
            ), at: 0)
        } else {
            points.append(ToolpathPoint(
                x: p0.x - leadL * cos(gamma),
                a: ((p0.a * k) - leadL * sin(gamma)) / k
            ))
        }
        return points
    }

    // MARK: - HSS Geodesic Arc-Length Profile

    /// Maps between angular coordinate A (degrees) and geodesic arc-length s (mm)
    /// along the outer perimeter of a rectangular HSS cross-section.
    ///
    /// Giving the kerf-offset algorithm a geodesic working plane means each millimetre
    /// of s is exactly 1 mm of surface distance, so a 2D perpendicular offset in (X, s)
    /// space equals a true geodesic kerf offset on the tube surface.
    private struct HSSGeodesicProfile {
        private struct Sample { let a: CGFloat; let s: CGFloat }
        private let table: [Sample]
        let perimeter: CGFloat

        init(odX: CGFloat, odY: CGFloat, cornerRadius: CGFloat) {
            let R  = max(cornerRadius, 0.1)
            let hw = odX / 2.0 - R
            let hh = odY / 2.0 - R
            var raw: [(a: CGFloat, s: CGFloat)] = []
            var cumS: CGFloat = 0

            let nFlat = 30   // samples per flat segment
            let nArc  = 15   // samples per 90° fillet arc

            func sa(u: CGFloat, v: CGFloat) -> CGFloat {
                var a = CGFloat(atan2(Double(v), Double(u)) * 180.0 / .pi)
                if a < 0 { a += 360 }
                return a
            }
            func flatSeg(u0: CGFloat, v0: CGFloat, u1: CGFloat, v1: CGFloat) {
                let len = sqrt((u1-u0)*(u1-u0) + (v1-v0)*(v1-v0))
                guard len > 1e-6 else { return }
                for i in 0..<nFlat {
                    let t = CGFloat(i) / CGFloat(nFlat)
                    raw.append((sa(u: u0 + t*(u1-u0), v: v0 + t*(v1-v0)), cumS + len * t))
                }
                cumS += len
            }
            func arcSeg(cx: CGFloat, cy: CGFloat, phi0: CGFloat, phi1: CGFloat) {
                let arcLen = R * abs(phi1 - phi0) * .pi / 180.0
                guard arcLen > 1e-6 else { return }
                for i in 0..<nArc {
                    let t  = CGFloat(i) / CGFloat(nArc)
                    let ph = phi0 + t * (phi1 - phi0)
                    let u  = cx + R * CGFloat(cos(Double(ph) * .pi / 180.0))
                    let v  = cy + R * CGFloat(sin(Double(ph) * .pi / 180.0))
                    raw.append((sa(u: u, v: v), cumS + arcLen * t))
                }
                cumS += arcLen
            }

            // Trace CCW from A = 0° (midpoint of right face = uAxis direction)
            flatSeg(u0: odX/2,  v0:  0,      u1: odX/2,  v1:  hh)
            arcSeg (cx: hw,     cy:  hh,     phi0:  0,   phi1:  90)
            flatSeg(u0: hw,     v0:  odY/2,  u1: -hw,    v1:  odY/2)
            arcSeg (cx: -hw,    cy:  hh,     phi0: 90,   phi1: 180)
            flatSeg(u0: -odX/2, v0:  hh,     u1: -odX/2, v1: -hh)
            arcSeg (cx: -hw,    cy: -hh,     phi0: 180,  phi1: 270)
            flatSeg(u0: -hw,    v0: -odY/2,  u1:  hw,    v1: -odY/2)
            arcSeg (cx: hw,     cy: -hh,     phi0: 270,  phi1: 360)
            flatSeg(u0: odX/2,  v0: -hh,     u1:  odX/2, v1:  0)

            perimeter = cumS
            table = raw.sorted { $0.a < $1.a }.map { Sample(a: $0.a, s: $0.s) }
        }

        /// Converts angle A (degrees, may be unwrapped outside [0°,360°)) to geodesic arc-length (mm).
        func encode(_ a: CGFloat) -> CGFloat {
            let revs = (a / 360.0).rounded(.down)
            return arcLengthFolded(a - revs * 360.0) + revs * perimeter
        }

        /// Converts geodesic arc-length (mm, may be unwrapped) to angle A (degrees).
        func decode(_ s: CGFloat) -> CGFloat {
            let revs = (s / perimeter).rounded(.down)
            return angleFolded(s - revs * perimeter) + revs * 360.0
        }

        private func arcLengthFolded(_ aN: CGFloat) -> CGFloat {
            guard table.count > 1 else { return aN * perimeter / 360.0 }
            var lo = 0, hi = table.count
            while lo < hi { let m = (lo+hi)/2; if table[m].a < aN { lo = m+1 } else { hi = m } }
            guard lo > 0 else { return table[0].s }
            guard lo < table.count else { return table.last!.s }
            let l = table[lo-1], r = table[lo]
            return l.s + (aN - l.a) / (r.a - l.a) * (r.s - l.s)
        }

        private func angleFolded(_ sN: CGFloat) -> CGFloat {
            guard table.count > 1 else { return sN * 360.0 / perimeter }
            var lo = 0, hi = table.count
            while lo < hi { let m = (lo+hi)/2; if table[m].s < sN { lo = m+1 } else { hi = m } }
            guard lo > 0 else { return table[0].a }
            guard lo < table.count else { return table.last!.a }
            let l = table[lo-1], r = table[lo]
            return l.a + (sN - l.s) / (r.s - l.s) * (r.a - l.a)
        }
    }

    // MARK: - Offline 2D Polyline Kerf Offset

    private func applyOfflineKerfOffset(
        to path: [ToolpathPoint],
        radius: CGFloat,
        isClosed: Bool,
        encode: (CGFloat) -> CGFloat,
        decode: (CGFloat) -> CGFloat
    ) -> [ToolpathPoint] {
        guard path.count > 1, radius != 0 else { return path }
        let pts: [(x: CGFloat, y: CGFloat)] = path.map { ($0.x, encode($0.a)) }
        var offsetPts: [(x: CGFloat, y: CGFloat)] = []

        for i in 0..<pts.count {
            let prevIdx = (i == 0) ? (isClosed ? pts.count - 2 : 0) : i - 1
            let nextIdx = (i == pts.count - 1) ? (isClosed ? 1 : pts.count - 1) : i + 1
            let pPrev = pts[prevIdx]
            let pCurr = pts[i]
            let pNext = pts[nextIdx]

            var vInX = pCurr.x - pPrev.x
            var vInY = pCurr.y - pPrev.y
            let lenIn = sqrt(vInX * vInX + vInY * vInY)
            if lenIn > 1e-6 { vInX /= lenIn; vInY /= lenIn }

            var vOutX = pNext.x - pCurr.x
            var vOutY = pNext.y - pCurr.y
            let lenOut = sqrt(vOutX * vOutX + vOutY * vOutY)
            if lenOut > 1e-6 { vOutX /= lenOut; vOutY /= lenOut }

            if !isClosed {
                if i == 0                  { vInX = vOutX; vInY = vOutY }
                else if i == pts.count - 1 { vOutX = vInX; vOutY = vInY }
            }

            let nInX = -vInY;  let nInY  = vInX
            let nOutX = -vOutY; let nOutY = vOutX
            let p1x = pCurr.x + radius * nInX;  let p1y = pCurr.y + radius * nInY
            let p2x = pCurr.x + radius * nOutX; let p2y = pCurr.y + radius * nOutY
            let cross = vInX * vOutY - vInY * vOutX

            if abs(cross) < 1e-6 {
                offsetPts.append((p1x, p1y))
            } else {
                let dx = p2x - p1x; let dy = p2y - p1y
                let t = (dx * vOutY - dy * vOutX) / cross
                offsetPts.append((p1x + t * vInX, p1y + t * vInY))
            }
        }
        if isClosed { offsetPts[offsetPts.count - 1] = offsetPts[0] }
        return offsetPts.map { ToolpathPoint(x: $0.x, a: decode($0.y)) }
    }
}
