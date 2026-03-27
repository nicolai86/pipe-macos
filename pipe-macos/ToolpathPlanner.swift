import Foundation

// MARK: - Planned Path

/// The result of 2D toolpath planning for a single feature.
/// `leadInPoints` is the approach geometry only; `cutPoints` is the actual
/// kerf-offset, overburn-extended cut path.  They are stored separately so
/// the UI can render them in distinct colours without re-parsing the G-code.
struct PlannedPath {
    /// Approach geometry — torch path from pierce position to cut-line entry.
    /// Empty when lead-in `strategy == .none`.
    let leadInPoints: [ToolpathPoint]
    /// The actual cut path (kerf-offset, chirality-correct, closed at exit).
    let cutPoints: [ToolpathPoint]
    /// Exit geometry — torch path past the nominal exit/closure point (overburn).
    /// Empty when lead-out `strategy == .none`.
    let leadOutPoints: [ToolpathPoint]
    /// Whether this feature is an internal cut (hole/cutout/notch).
    /// Forwarded to the emitter for the THC/direction comment only.
    let isInternal: Bool

    /// Combined path for the emitter and kinematics engine: lead-in → cut → lead-out.
    var points: [ToolpathPoint] { leadInPoints + cutPoints + leadOutPoints }
}

/// A feature that has been through the 2D planning stage.
struct PlannedFeature {
    let source: GeometricFeature
    let plannedPath: PlannedPath
}

// MARK: - Toolpath Planner

/// Transforms a raw GeometricFeature into a planned 2D surface-space toolpath.
///
/// All operations work in (X, A) surface coordinates.
/// No machine kinematics are applied at this stage.
struct ToolpathPlanner {
    let settings: GCodeSettings

    // MARK: - Public API

    func plan(
        feature: GeometricFeature,
        stock: StockInfo,
        packStartX: CGFloat,
        rollOffset: CGFloat,
        previousMachineAm: CGFloat
    ) -> PlannedFeature {
        let localPath = feature.rawPath
        guard localPath.count > 1 else {
            return PlannedFeature(source: feature, plannedPath: PlannedPath(leadInPoints: [], cutPoints: [], leadOutPoints: [], isInternal: false))
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

        // 7. Lead-in geometry
        let leadInConfig = settings.resolveLeadInConfig(for: feature)
        let (leadInPoints, cutPath) = buildLeadIn(
            path: finalPath, k: k,
            config: leadInConfig,
            isScrapLeft: isScrapLeft,
            featureType: feature.type
        )

        // 8. Lead-out geometry (overburn)
        let leadOutConfig = settings.resolveLeadOutConfig(for: feature)
        let leadOutPoints = buildLeadOut(
            path: cutPath, k: k,
            config: leadOutConfig,
            isScrapLeft: isScrapLeft
        )

        return PlannedFeature(source: feature, plannedPath: PlannedPath(
            leadInPoints: leadInPoints,
            cutPoints: cutPath,
            leadOutPoints: leadOutPoints,
            isInternal: isInternal
        ))
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
        // Distinguish straight sever cuts (all X ≈ equal) from saddle/cope cuts (X varies with A).
        // For straight cuts, pick the point on a flat face (nearest 90° multiple) so the torch
        // pierces a flat surface — same behaviour as before.
        // For saddle cuts, the "nearest 90°" heuristic often picks the shallowest point of the
        // saddle (minimal scrap), causing the lead-in to extend off the tube end into air.
        // Instead, pick the point with the most scrap material behind it so the lead-in is
        // always within the stock bounds:
        //   startCut: scrap is at X < cut(A) → pick the A where cut(A) is maximum (deepest)
        //   endCut:   scrap is at X > cut(A) → pick the A where cut(A) is minimum (deepest)
        let xValues = path.map { $0.x }
        let xRange = (xValues.max() ?? 0) - (xValues.min() ?? 0)

        var bestIdx = 0
        if xRange < 5.0 {
            // Straight sever: find the point nearest to any 90° face
            var minDiff = CGFloat.greatestFiniteMagnitude
            for (i, pt) in path.enumerated() {
                let modA = abs(pt.a.truncatingRemainder(dividingBy: 90.0))
                let diff = min(modA, 90.0 - modA)
                if diff < minDiff { minDiff = diff; bestIdx = i }
            }
        } else {
            // Saddle/cope sever: pick deepest-scrap pierce point
            if featureType == .startCut {
                var maxX = -CGFloat.greatestFiniteMagnitude
                for (i, pt) in path.enumerated() {
                    if pt.x > maxX { maxX = pt.x; bestIdx = i }
                }
            } else {
                var minX = CGFloat.greatestFiniteMagnitude
                for (i, pt) in path.enumerated() {
                    if pt.x < minX { minX = pt.x; bestIdx = i }
                }
            }
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

    // MARK: - Lead-Out

    /// Builds exit geometry (overburn) past the cut path's last point.
    ///
    /// - Returns: `leadOutPoints` to be appended after `cutPath` in the combined path.
    ///   Empty for `.none` strategy.
    private func buildLeadOut(
        path: [ToolpathPoint],
        k: CGFloat,
        config: LeadOutConfig,
        isScrapLeft: Bool
    ) -> [ToolpathPoint] {
        guard path.count >= 2 else { return [] }
        switch config.strategy {
        case .linear:
            return buildLinearLeadOut(path: path, k: k, config: config, isScrapLeft: isScrapLeft)
        case .rotationalArc:
            return buildRotationalArcLeadOut(path: path, k: k, config: config, isScrapLeft: isScrapLeft)
        case .none:
            return []
        }
    }

    /// Extends the cut path in the exit-tangent direction by `extensionMm`, with
    /// an optional angular deflection `extensionAngleDeg` from that tangent.
    private func buildLinearLeadOut(
        path: [ToolpathPoint],
        k: CGFloat,
        config: LeadOutConfig,
        isScrapLeft: Bool
    ) -> [ToolpathPoint] {
        let pLast = path[path.count - 1]
        let pPrev = path[path.count - 2]
        let dx = pLast.x - pPrev.x
        let da_mm = (pLast.a - pPrev.a) * k
        let len = sqrt(dx * dx + da_mm * da_mm)
        guard len > 1e-4 else { return [] }

        let gamma = atan2(da_mm, dx)
        let angleDelta = CGFloat(config.extensionAngleDeg) * .pi / 180.0
        let exitAngle = gamma + angleDelta
        let dist = CGFloat(config.extensionMm)

        return [ToolpathPoint(
            x: pLast.x + dist * cos(exitAngle),
            a: ((pLast.a * k) + dist * sin(exitAngle)) / k
        )]
    }

    /// A-axis-only sweep past the cut exit: torch rotates without moving X.
    /// Mirrors `buildRotationalArcLeadIn` — used for sever cuts so no X witness
    /// mark is left on the cut face during torch ramp-down.
    private func buildRotationalArcLeadOut(
        path: [ToolpathPoint],
        k: CGFloat,
        config: LeadOutConfig,
        isScrapLeft: Bool
    ) -> [ToolpathPoint] {
        let pLast = path.last!
        let sideMultiplier: CGFloat = isScrapLeft ? 1.0 : -1.0
        let sweepDeg = CGFloat(config.rotationalSweepMm) / k
        let steps = 5
        var pts: [ToolpathPoint] = []
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            pts.append(ToolpathPoint(x: pLast.x, a: pLast.a + sideMultiplier * sweepDeg * t))
        }
        return pts
    }

    // MARK: - Lead-In

    /// Builds approach geometry for a feature and returns it split from the cut path.
    ///
    /// - Returns: `(leadIn, cutPath)` where `leadIn` is the torch approach sequence
    ///   and `cutPath` is the (possibly reordered) cut path.  For `.none` strategy,
    ///   `leadIn` is empty and `cutPath` == `path`.
    private func buildLeadIn(
        path: [ToolpathPoint],
        k: CGFloat,
        config: LeadInConfig,
        isScrapLeft: Bool,
        featureType: SurfaceFeatureType
    ) -> (leadIn: [ToolpathPoint], cutPath: [ToolpathPoint]) {
        switch config.strategy {
        case .rotationalArc:
            return buildRotationalArcLeadIn(path: path, k: k, config: config, isScrapLeft: isScrapLeft)
        case .tangentArc:
            return buildTangentArcLeadIn(path: path, k: k, config: config, isScrapLeft: isScrapLeft, featureType: featureType)
        case .linear:
            return buildLinearLeadIn(path: path, k: k, config: config, isScrapLeft: isScrapLeft, featureType: featureType)
        case .centerPierce:
            return buildCenterPierceLeadIn(path: path, config: config)
        case .spiral:
            return buildSpiralLeadIn(path: path, k: k, config: config)
        case .none:
            return ([], path)
        }
    }

    /// A-axis-only sweep: torch rotates to entry position without moving X.
    /// Used for sever cuts so no witness mark is left on the cut face.
    private func buildRotationalArcLeadIn(
        path: [ToolpathPoint],
        k: CGFloat,
        config: LeadInConfig,
        isScrapLeft: Bool
    ) -> (leadIn: [ToolpathPoint], cutPath: [ToolpathPoint]) {
        let p0 = path[0]
        let sideMultiplier: CGFloat = isScrapLeft ? 1.0 : -1.0
        let leadAngleDeg = CGFloat(config.rotationalSweepMm) / k
        let entryA = p0.a - sideMultiplier * leadAngleDeg
        let steps = 5
        var leadIn: [ToolpathPoint] = []
        for i in 0..<steps {
            let t = CGFloat(i) / CGFloat(steps)
            leadIn.append(ToolpathPoint(x: p0.x, a: entryA + sideMultiplier * leadAngleDeg * t))
        }
        return (leadIn, path)
    }

    /// Circular arc tangent to the cut path at the pierce point.
    /// Prepended with a straight approach segment of `approachLength` mm.
    /// For sever cuts the entry tangent is always axial (from the scrap side) so the approach
    /// is independent of the potentially-unreliable rawPath tangent.
    private func buildTangentArcLeadIn(
        path: [ToolpathPoint],
        k: CGFloat,
        config: LeadInConfig,
        isScrapLeft: Bool,
        featureType: SurfaceFeatureType
    ) -> (leadIn: [ToolpathPoint], cutPath: [ToolpathPoint]) {
        let p0 = path[0]
        let p1 = path.count > 1 ? path[1] : ToolpathPoint(x: p0.x + 1, a: p0.a)

        // For sever cuts, use a fixed axial approach tangent (gamma = 0 for startCut,
        // gamma = π for endCut) so the arc entry is always from the scrap side.
        let gamma: CGFloat
        if featureType == .startCut {
            gamma = 0.0          // approaching in +X direction (from scrap left of pierce)
        } else if featureType == .endCut {
            gamma = CGFloat.pi   // approaching in -X direction (from scrap right of pierce)
        } else {
            let dx = p1.x - p0.x
            let da_mm = (p1.a - p0.a) * k
            gamma = atan2(da_mm, dx)
        }
        let leadR    = CGFloat(config.arcRadius)
        let leadTheta = CGFloat(config.arcAngleDeg) * .pi / 180.0
        let leadL    = CGFloat(config.approachLength)
        let sideMultiplier: CGFloat = isScrapLeft ? 1.0 : -1.0

        guard leadTheta > 0.01 && leadR > 0.01 else {
            return buildLinearLeadIn(path: path, k: k, config: config, isScrapLeft: isScrapLeft, featureType: featureType)
        }

        let Cx = p0.x + leadR * cos(gamma + sideMultiplier * .pi / 2.0)
        let Cy = (p0.a * k) + leadR * sin(gamma + sideMultiplier * .pi / 2.0)
        let startAngle = (gamma - sideMultiplier * .pi / 2.0) - sideMultiplier * leadTheta
        let arcSteps = max(4, Int(leadTheta * 180 / .pi / 15))
        var arcPts: [ToolpathPoint] = []
        for i in 0..<arcSteps {
            let t = startAngle + sideMultiplier * (leadTheta * CGFloat(i) / CGFloat(arcSteps))
            arcPts.append(ToolpathPoint(
                x: Cx + leadR * cos(t),
                a: (Cy + leadR * sin(t)) / k
            ))
        }
        let firstArcPt = arcPts.first ?? p0
        let entryTangent = gamma - sideMultiplier * leadTheta
        let straightPt = ToolpathPoint(
            x: firstArcPt.x - leadL * cos(entryTangent),
            a: ((firstArcPt.a * k) - leadL * sin(entryTangent)) / k
        )
        return ([straightPt] + arcPts, path)
    }

    /// Straight approach line to the cut-path pierce point.
    ///
    /// For sever cuts (startCut/endCut) the approach is always computed on the CLEAN STOCK
    /// SURFACE — a pure axial (X-direction) traverse from the scrap side.  This makes the
    /// lead-in independent of the rawPath tangent, which can be unreliable for complex
    /// saddle/cope profiles where the feature detection may produce garbled point ordering.
    ///
    /// For internal features (holes, notches, cutouts) the approach uses the path tangent
    /// at the pierce point, rotated by `linearAngleDeg`.
    private func buildLinearLeadIn(
        path: [ToolpathPoint],
        k: CGFloat,
        config: LeadInConfig,
        isScrapLeft: Bool,
        featureType: SurfaceFeatureType
    ) -> (leadIn: [ToolpathPoint], cutPath: [ToolpathPoint]) {
        let p0 = path[0]
        let leadL = CGFloat(config.linearLength)

        // Sever cuts: approach along the perfect stock surface, axially from the scrap side.
        // startCut → scrap is at X < pierce → approach from X - leadL
        // endCut   → scrap is at X > pierce → approach from X + leadL
        if featureType == .startCut || featureType == .endCut {
            let xDir: CGFloat = featureType == .startCut ? -1.0 : 1.0
            let pt = ToolpathPoint(x: p0.x + xDir * leadL, a: p0.a)
            return ([pt], path)
        }

        // Internal features: tangent-based approach with optional angular deflection.
        let p1 = path.count > 1 ? path[1] : ToolpathPoint(x: p0.x + 1, a: p0.a)
        let dx = p1.x - p0.x
        let da_mm = (p1.a - p0.a) * k
        let gamma = atan2(da_mm, dx)
        let angleDelta = CGFloat(config.linearAngleDeg) * .pi / 180.0
        let sideMultiplier: CGFloat = isScrapLeft ? 1.0 : -1.0
        let approachAngle = gamma - sideMultiplier * angleDelta
        let pt = ToolpathPoint(
            x: p0.x - leadL * cos(approachAngle),
            a: ((p0.a * k) - leadL * sin(approachAngle)) / k
        )
        return ([pt], path)
    }

    /// Pierce at the feature centroid, then run a straight line to the cut-path start.
    /// The pierce mark lands safely inside the scrap area, away from the kerf edge.
    private func buildCenterPierceLeadIn(
        path: [ToolpathPoint],
        config: LeadInConfig
    ) -> (leadIn: [ToolpathPoint], cutPath: [ToolpathPoint]) {
        guard path.count >= 2 else { return ([], path) }
        let cx = path.map(\.x).reduce(0, +) / CGFloat(path.count)
        let ca = path.map(\.a).reduce(0, +) / CGFloat(path.count)
        let steps = max(2, config.centerPierceSteps)
        let p0 = path[0]
        var leadIn: [ToolpathPoint] = []
        for i in 0..<steps {
            let t = CGFloat(i) / CGFloat(steps)
            leadIn.append(ToolpathPoint(x: cx + t * (p0.x - cx), a: ca + t * (p0.a - ca)))
        }
        return (leadIn, path)
    }

    /// Archimedean spiral from the feature centroid outward to the cut-path start.
    /// Produces a smoother velocity ramp-up than a straight center-pierce approach.
    private func buildSpiralLeadIn(
        path: [ToolpathPoint],
        k: CGFloat,
        config: LeadInConfig
    ) -> (leadIn: [ToolpathPoint], cutPath: [ToolpathPoint]) {
        guard path.count >= 2 else { return ([], path) }
        let cx = path.map(\.x).reduce(0, +) / CGFloat(path.count)
        let ca = path.map(\.a).reduce(0, +) / CGFloat(path.count)
        let p0 = path[0]
        let dx = p0.x - cx
        let da_mm = (p0.a - ca) * k
        let rMax = sqrt(dx * dx + da_mm * da_mm)
        guard rMax > 1e-3 else { return buildCenterPierceLeadIn(path: path, config: config) }

        let totalAngle = CGFloat(config.spiralTurns) * 2.0 * .pi
        let steps = max(8, config.spiralSteps)
        var leadIn: [ToolpathPoint] = []
        for i in 0..<steps {
            let t = CGFloat(i) / CGFloat(steps)
            let r = rMax * t
            let theta = totalAngle * t
            leadIn.append(ToolpathPoint(
                x: cx + r * cos(theta),
                a: ca + (r * sin(theta)) / k
            ))
        }
        return (leadIn, path)
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
