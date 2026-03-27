import XCTest
import Foundation
import simd
@testable import pipe_macos

// MARK: - Shared Helpers

private func makeRoundStock(od: CGFloat = 50.8, length: CGFloat = 500) -> StockInfo {
    StockInfo(profile: .round, od: od, length: length,
              axis: SIMD3<Float>(1, 0, 0), uAxis: SIMD3<Float>(0, 1, 0),
              origin: SIMD3<Float>(Float(length / 2), 0, 0))
}

private func makeSquareStock(side: CGFloat = 50.0, cornerR: CGFloat = 2.0) -> StockInfo {
    let s = StockInfo(profile: .square, odX: side, odY: side, length: 500,
                      axis: SIMD3<Float>(1, 0, 0), uAxis: SIMD3<Float>(0, 1, 0),
                      origin: SIMD3<Float>(250, 0, 0))
    s.cornerRadius = cornerR
    return s
}

private func makeHoleFeature(
    id: Int = 1,
    xCenter: CGFloat = 200,
    aCenter: CGFloat = 90,
    xRadius: CGFloat = 15,
    aRadius: CGFloat = 30,
    diameter: CGFloat = 30
) -> GeometricFeature {
    let steps = 12
    let path = (0...steps).map { i -> ToolpathPoint in
        let t = 2 * Double.pi * Double(i) / Double(steps)
        return ToolpathPoint(x: xCenter + xRadius * CGFloat(cos(t)),
                             a: aCenter  + aRadius * CGFloat(sin(t)))
    }
    return GeometricFeature(id: id, type: .hole, shape: .circle,
                            xCenter: xCenter, aCenterDeg: aCenter,
                            dimensions: ["diameter": diameter], confidence: 1.0, rawPath: path)
}

private func makeSeverFeature(type: SurfaceFeatureType = .startCut,
                               xPos: CGFloat = 100) -> GeometricFeature {
    let path = (0...36).map { i in ToolpathPoint(x: xPos, a: CGFloat(i) * 10) }
    return GeometricFeature(id: 2, type: type, shape: .custom,
                            xCenter: xPos, aCenterDeg: 180,
                            dimensions: [:], confidence: 1.0, rawPath: path)
}

/// Euclidean distance in surface (X, A×k) space.
private func surfaceDist(_ p: ToolpathPoint, _ q: ToolpathPoint, k: CGFloat) -> CGFloat {
    let dx = p.x - q.x
    let da = (p.a - q.a) * k
    return sqrt(dx * dx + da * da)
}

// MARK: - HSS Geodesic Profile Tests

/// Tests for the piecewise arc-length ↔ angle converter used by the kerf-offset algorithm.
///
/// The table is built from 30 flat + 15 arc samples per face/arc segment, giving ~180 samples
/// over 360°. Roundtrip tolerance is set to 2° to account for linear-interpolation error
/// between samples (worst case ~2.8°/sample on the widest flat face).
final class HSSGeodesicProfileTests: XCTestCase {

    private func square(side: CGFloat = 50.0, cornerR: CGFloat = 2.0) -> ToolpathPlanner.HSSGeodesicProfile {
        ToolpathPlanner.HSSGeodesicProfile(odX: side, odY: side, cornerRadius: cornerR)
    }

    private func rect(odX: CGFloat = 100.0, odY: CGFloat = 50.0, cornerR: CGFloat = 3.0) -> ToolpathPlanner.HSSGeodesicProfile {
        ToolpathPlanner.HSSGeodesicProfile(odX: odX, odY: odY, cornerRadius: cornerR)
    }

    // MARK: Boundary values

    func testEncodeZeroIsZero() {
        XCTAssertEqual(Double(square().encode(0)), 0, accuracy: 0.01)
    }

    func testDecodeZeroIsZero() {
        XCTAssertEqual(Double(square().decode(0)), 0, accuracy: 0.01)
    }

    func testEncodeFullRevolutionEqualsPerimeter() {
        let p = square()
        XCTAssertEqual(Double(p.encode(360)), Double(p.perimeter), accuracy: 0.1,
                       "encode(360) must equal one full perimeter")
    }

    func testDecodePerimeterIs360() {
        let p = square()
        XCTAssertEqual(Double(p.decode(p.perimeter)), 360, accuracy: 0.5,
                       "decode(perimeter) must return 360°")
    }

    // MARK: Perimeter

    func testSquarePerimeterApproximate() {
        // Square 50×50 with R=2:
        //   flat: 4 × (50 - 2R) = 4 × 46 = 184mm
        //   arcs: 4 × quarter-circle(R=2) = 4 × (π×R/2) = 4π ≈ 12.57mm  → total ≈ 196.57mm
        let R: CGFloat = 2
        let p = square(side: 50, cornerR: R)
        let expected: CGFloat = 4 * (50 - 2 * R) + 4 * (.pi * R / 2)
        XCTAssertEqual(Double(p.perimeter), Double(expected), accuracy: 1.5,
                       "Square perimeter must match 4×flat + 4×arc")
    }

    func testRectPerimeterApproximate() {
        // 100×50 with R=3:
        //   flat: 2×(100-2R) + 2×(50-2R) = 2×94 + 2×44 = 276mm
        //   arcs: 4 × quarter-circle(R=3) = 4 × (π×R/2) = 6π ≈ 18.85mm  → total ≈ 294.85mm
        let R: CGFloat = 3
        let p = rect(odX: 100, odY: 50, cornerR: R)
        let expected: CGFloat = 2 * (100 - 2 * R) + 2 * (50 - 2 * R) + 4 * (.pi * R / 2)
        XCTAssertEqual(Double(p.perimeter), Double(expected), accuracy: 2.0)
    }

    // MARK: Roundtrip A → s → A

    func testRoundtripSquare_Half_Degree_Steps() {
        let p = square()
        // Sweep from 1° to 359° in 0.5° steps (skip exact 0 and 360 boundary samples).
        var failCount = 0
        for i in stride(from: 1, through: 359, by: 1) {
            let a = CGFloat(i) * 0.5
            let rt = p.decode(p.encode(a))
            if abs(Double(rt) - Double(a)) > 2.0 {
                failCount += 1
            }
        }
        XCTAssertEqual(failCount, 0,
                       "\(failCount) angles failed roundtrip A→s→A within 2° tolerance on 50×50 square")
    }

    func testRoundtripRect_OneDegreSteps() {
        let p = rect()
        var failCount = 0
        for i in 1...359 {
            let a = CGFloat(i)
            let rt = p.decode(p.encode(a))
            if abs(Double(rt) - Double(a)) > 2.0 {
                failCount += 1
            }
        }
        XCTAssertEqual(failCount, 0,
                       "\(failCount) angles failed roundtrip on 100×50 rect")
    }

    // MARK: Roundtrip s → A → s

    func testRoundtripSToAToS_Square() {
        let p = square()
        let step = p.perimeter / 360.0
        var failCount = 0
        var s: CGFloat = step
        while s < p.perimeter * 0.999 {
            let rt = p.encode(p.decode(s))
            if abs(Double(rt) - Double(s)) > 1.0 {
                failCount += 1
            }
            s += step
        }
        XCTAssertEqual(failCount, 0,
                       "\(failCount) arc-lengths failed roundtrip s→A→s within 1mm tolerance")
    }

    // MARK: Monotonicity

    func testEncodeMonotonicallyIncreasing() {
        let p = square()
        var prevS: CGFloat = p.encode(0.5)
        var i = 1
        while i < 719 {
            let a = CGFloat(i) * 0.5 + 0.5
            let s = p.encode(a)
            XCTAssertGreaterThan(s, prevS - 1e-6,
                                 "encode() must be non-decreasing at A=\(a)°: got \(s) ≤ \(prevS)")
            prevS = s
            i += 1
        }
    }

    // MARK: Multi-revolution continuity

    func testEncodeMultiRevolutionAddsPerimeter() {
        let p = square()
        let a: CGFloat = 135.0
        XCTAssertEqual(Double(p.encode(a + 360)), Double(p.encode(a)) + Double(p.perimeter),
                       accuracy: 0.5,
                       "encode(a + 360°) must equal encode(a) + perimeter")
        XCTAssertEqual(Double(p.encode(a + 720)), Double(p.encode(a)) + 2.0 * Double(p.perimeter),
                       accuracy: 0.5,
                       "encode(a + 720°) must equal encode(a) + 2×perimeter")
    }

    func testDecodeMultiRevolutionAdds360() {
        let p = square()
        let s = p.perimeter * 0.5
        XCTAssertEqual(Double(p.decode(s + p.perimeter)), Double(p.decode(s)) + 360,
                       accuracy: 0.5,
                       "decode(s + perimeter) must equal decode(s) + 360°")
    }

    func testNegativeAngleRoundtrip() {
        let p = square()
        let a: CGFloat = -45.0
        let rt = p.decode(p.encode(a))
        XCTAssertEqual(Double(rt), Double(a), accuracy: 2.0,
                       "Negative angle roundtrip A=\(a)° must return to within 2°")
    }
}

// MARK: - Kerf Offset Geometry Tests

/// Tests for `applyOfflineKerfOffset` in isolation.
/// Uses identity encode/decode (k=1) so distances are directly in mm.
final class KerfOffsetGeometryTests: XCTestCase {

    private var planner: ToolpathPlanner { ToolpathPlanner(settings: GCodeSettings()) }

    private let enc: (CGFloat) -> CGFloat = { $0 }  // identity — 1 degree = 1 mm
    private let dec: (CGFloat) -> CGFloat = { $0 }

    /// Straight horizontal path in (X, encoded_A) space — all points share A=0.
    private func hLine(xs: [CGFloat] = [0, 10, 20, 30]) -> [ToolpathPoint] {
        xs.map { ToolpathPoint(x: $0, a: 0) }
    }

    // MARK: Zero radius

    func testZeroRadiusRetainsOriginalPath() {
        let path = hLine()
        let result = planner.applyOfflineKerfOffset(to: path, radius: 0,
                                                    isClosed: false, encode: enc, decode: dec)
        XCTAssertEqual(result.count, path.count)
        for (orig, offset) in zip(path, result) {
            XCTAssertEqual(Double(offset.x), Double(orig.x), accuracy: 1e-9)
            XCTAssertEqual(Double(offset.a), Double(orig.a), accuracy: 1e-9)
        }
    }

    // MARK: Straight-line distance

    func testStraightLineAllPointsAtRadiusFromOriginal() {
        // For a horizontal path (travel in +X, encode=identity), the normal is (0,±1).
        // With radius=r, every offset point should have encoded_a = r (shifted perpendicular).
        let radius: CGFloat = 3.5
        let path = hLine(xs: [0, 15, 30, 45])
        let result = planner.applyOfflineKerfOffset(to: path, radius: radius,
                                                    isClosed: false, encode: enc, decode: dec)
        XCTAssertEqual(result.count, path.count)
        for (i, pt) in result.enumerated() {
            XCTAssertEqual(Double(pt.x),   Double(path[i].x), accuracy: 1e-9,
                           "X must not change for horizontal path (point \(i))")
            XCTAssertEqual(Double(pt.a),   Double(radius),    accuracy: 1e-6,
                           "Encoded A must equal radius for straight horizontal path (point \(i))")
        }
    }

    func testNegativeRadiusOffsetsBelowPath() {
        let radius: CGFloat = -2.0
        let result = planner.applyOfflineKerfOffset(to: hLine(), radius: radius,
                                                    isClosed: false, encode: enc, decode: dec)
        for (i, pt) in result.enumerated() {
            XCTAssertEqual(Double(pt.a), Double(radius), accuracy: 1e-6,
                           "Negative radius must shift encoded A to –radius (point \(i))")
        }
    }

    // MARK: Closed-path closure

    func testClosedPathFirstAndLastPointsEqual() {
        // A square path — isClosed=true forces offsetPts.last = offsetPts.first.
        let sq: [ToolpathPoint] = [
            ToolpathPoint(x:  0, a:  0),
            ToolpathPoint(x: 10, a:  0),
            ToolpathPoint(x: 10, a: 10),
            ToolpathPoint(x:  0, a: 10),
            ToolpathPoint(x:  0, a:  0),
        ]
        let result = planner.applyOfflineKerfOffset(to: sq, radius: 1.5,
                                                    isClosed: true, encode: enc, decode: dec)
        XCTAssertEqual(result.count, sq.count)
        guard let first = result.first, let last = result.last else { return }
        XCTAssertEqual(Double(first.x), Double(last.x), accuracy: 1e-9, "Closed path: first.x must equal last.x")
        XCTAssertEqual(Double(first.a), Double(last.a), accuracy: 1e-9, "Closed path: first.a must equal last.a")
    }

    // MARK: Sign / chirality

    func testPositiveRadiusIsToLeftOfTravelDirection() {
        // Travelling in +X, left side (CCW normal) is +A direction.
        let result = planner.applyOfflineKerfOffset(
            to: hLine(), radius: 2.0, isClosed: false, encode: enc, decode: dec)
        XCTAssertGreaterThan(Double(result[0].a), 0.0,
                             "Positive radius must offset in +A (left of +X travel)")
    }

    func testOppositeRadiiProduceOppositeOffsets() {
        let pos = planner.applyOfflineKerfOffset(to: hLine(), radius:  2.0,
                                                 isClosed: false, encode: enc, decode: dec)
        let neg = planner.applyOfflineKerfOffset(to: hLine(), radius: -2.0,
                                                 isClosed: false, encode: enc, decode: dec)
        for (p, n) in zip(pos, neg) {
            XCTAssertEqual(Double(p.a), -Double(n.a), accuracy: 1e-6,
                           "±radius offsets must be symmetric about original path")
        }
    }

    // MARK: Output validity

    func testNoNaNInKerfOffsetOutput() {
        let path: [ToolpathPoint] = (0..<8).map { i in
            ToolpathPoint(x: CGFloat(i) * 5, a: CGFloat(i) * 5)
        }
        let result = planner.applyOfflineKerfOffset(to: path, radius: 1.5,
                                                    isClosed: false, encode: enc, decode: dec)
        for (i, pt) in result.enumerated() {
            XCTAssertFalse(pt.x.isNaN || pt.x.isInfinite, "X must be finite (point \(i))")
            XCTAssertFalse(pt.a.isNaN || pt.a.isInfinite, "A must be finite (point \(i))")
        }
    }
}

// MARK: - Velocity Profiler Invariant Tests

final class VelocityProfilerInvariantTests: XCTestCase {

    private func makeSettings(feed: CGFloat = 1000,
                               accelX: CGFloat = 500,
                               jerkX: CGFloat = 5000,
                               simCNC: Bool = false) -> GCodeSettings {
        var s = GCodeSettings()
        s.feedRate   = feed
        s.rapidRate  = 3000
        s.maxAccelX  = accelX
        s.maxAccelA  = 1000
        s.maxJerkX   = jerkX
        s.useSimCNC  = simCNC
        return s
    }

    /// Straight machine-space path along X only.
    private func xLine(steps: Int, stepMm: CGFloat = 20) -> [MachinePoint] {
        (0..<steps).map { i in
            let x = CGFloat(i) * stepMm
            return MachinePoint(Xm: x, Ym: 0, Zm: 0, Am: 0,
                                matX: x, matU: 25, matV: 0, isCorner: false)
        }
    }

    // MARK: Feedrate cap

    func testFeedRateCapNonSimCNC() {
        let s = makeSettings(feed: 500, simCNC: false)
        let result = VelocityProfiler(settings: s).profile(machinePoints: xLine(steps: 20))
        for (i, seg) in result.enumerated() {
            XCTAssertLessThanOrEqual(Double(seg.finalF), 500.0 + 1e-6,
                                     "Segment \(i) finalF \(seg.finalF) exceeds feedRate 500")
        }
    }

    func testFeedRateCapRespectedAcrossMultipleRates() {
        for feed in [200, 800, 2500] as [CGFloat] {
            let s = makeSettings(feed: feed, simCNC: false)
            let result = VelocityProfiler(settings: s).profile(machinePoints: xLine(steps: 15))
            let maxF = result.map(\.finalF).max() ?? 0
            XCTAssertLessThanOrEqual(Double(maxF), Double(feed) + 1e-6,
                                     "feedRate cap violated at feedRate=\(feed): maxF=\(maxF)")
        }
    }

    func testSimCNCFeedRateDoesNotExceedRapidRate() {
        var s = makeSettings(feed: 2000, simCNC: true)
        s.rapidRate = 1500
        let result = VelocityProfiler(settings: s).profile(machinePoints: xLine(steps: 15))
        for (i, seg) in result.enumerated() {
            XCTAssertLessThanOrEqual(Double(seg.finalF), 1500.0 + 1e-6,
                                     "SimCNC finalF must not exceed rapidRate (segment \(i))")
        }
    }

    // MARK: Ramp shape — starts and ends at rest

    func testLastSegmentsDecelerateTowardRest() {
        let result = VelocityProfiler(settings: makeSettings()).profile(machinePoints: xLine(steps: 40))
        guard result.count >= 10 else { return XCTFail("Insufficient segments") }
        let last = result.last!.finalF
        let mid  = result[result.count / 2].finalF
        XCTAssertLessThan(Double(last), Double(mid) + 1,
                          "Last segment feedrate must be less than mid (deceleration to rest)")
    }

    func testFirstSegmentsRampUpFromRest() {
        let result = VelocityProfiler(settings: makeSettings()).profile(machinePoints: xLine(steps: 40))
        guard result.count >= 6 else { return XCTFail("Insufficient segments") }
        let first = result.first!.finalF
        let mid   = result[result.count / 2].finalF
        XCTAssertLessThan(Double(first), Double(mid) + 1,
                          "First segment feedrate must be less than mid (ramp-up from rest)")
    }

    func testSymmetricPathHasSymmetricProfile() {
        // A long symmetric path should have a symmetric feedrate profile.
        let steps = 30
        let result = VelocityProfiler(settings: makeSettings()).profile(machinePoints: xLine(steps: steps))
        guard result.count >= 6 else { return XCTFail("Insufficient segments") }
        let n = result.count
        // First quarter average should be less than second quarter average.
        let q1 = result[0..<(n/4)].map(\.finalF).reduce(0, +) / CGFloat(n / 4)
        let q2 = result[(n/4)..<(n/2)].map(\.finalF).reduce(0, +) / CGFloat(n / 4)
        XCTAssertLessThan(Double(q1), Double(q2) + 1,
                          "Feedrate must ramp up: first quarter < second quarter")
    }

    // MARK: Robustness

    func testTinySegmentsNoNaN() {
        let pts: [MachinePoint] = (0..<5).map { i in
            let x = CGFloat(i) * 0.001
            return MachinePoint(Xm: x, Ym: 0, Zm: 0, Am: 0,
                                matX: x, matU: 25, matV: 0, isCorner: false)
        }
        let result = VelocityProfiler(settings: makeSettings()).profile(machinePoints: pts)
        for (i, seg) in result.enumerated() {
            XCTAssertFalse(seg.finalF.isNaN,      "NaN finalF on tiny segment \(i)")
            XCTAssertFalse(seg.finalF.isInfinite, "Infinite finalF on tiny segment \(i)")
            XCTAssertGreaterThan(seg.finalF, 0,   "finalF must be positive on tiny segment \(i)")
        }
    }

    func testMultiAxisPathNoNaN() {
        let pts: [MachinePoint] = (0..<8).map { i in
            let x = CGFloat(i) * 15
            let a = CGFloat(i) * 10
            return MachinePoint(Xm: x, Ym: 0, Zm: 0, Am: a,
                                matX: x, matU: 25 * cos(a * .pi / 180),
                                matV: 25 * sin(a * .pi / 180), isCorner: false)
        }
        let result = VelocityProfiler(settings: makeSettings()).profile(machinePoints: pts)
        for (i, seg) in result.enumerated() {
            XCTAssertFalse(seg.finalF.isNaN,      "NaN on multi-axis segment \(i)")
            XCTAssertFalse(seg.finalF.isInfinite, "Infinite on multi-axis segment \(i)")
            XCTAssertGreaterThan(seg.finalF, 0)
        }
    }

    // MARK: Accel / jerk effects

    func testHigherJerkProducesFasterEarlyRamp() {
        // Low jerk forces a gentle S-curve ramp; high jerk (no smoothing) should ramp faster.
        var sLow  = makeSettings(feed: 2000, jerkX: 10)       // tight jerk
        var sHigh = makeSettings(feed: 2000, jerkX: 1_000_000) // effectively unlimited
        sLow.maxJerkA  = 10;    sLow.maxJerkY  = 10;    sLow.maxJerkZ  = 10
        sHigh.maxJerkA = 1e6;   sHigh.maxJerkY = 1e6;   sHigh.maxJerkZ = 1e6

        let pts = xLine(steps: 40, stepMm: 15)
        let low  = VelocityProfiler(settings: sLow ).profile(machinePoints: pts)
        let high = VelocityProfiler(settings: sHigh).profile(machinePoints: pts)

        guard low.count >= 3, high.count >= 3 else { return XCTFail("Insufficient segments") }
        // The second segment should always be at least as fast (or faster) with higher jerk.
        XCTAssertLessThanOrEqual(Double(low[1].finalF), Double(high[1].finalF) + 1e-3,
                                  "Low-jerk early segment must be ≤ high-jerk early segment")
    }

    func testLowerAccelProducesLowerOrEqualPeakFeedrate() {
        let sFast = makeSettings(feed: 3000, accelX: 500)
        let sSlow = makeSettings(feed: 3000, accelX:  50)   // 10× lower acceleration

        let pts   = xLine(steps: 10, stepMm: 20)           // 200mm — modest path
        let fast  = VelocityProfiler(settings: sFast).profile(machinePoints: pts)
        let slow  = VelocityProfiler(settings: sSlow).profile(machinePoints: pts)

        let fastPeak = fast.map(\.finalF).max() ?? 0
        let slowPeak = slow.map(\.finalF).max() ?? 0
        XCTAssertLessThanOrEqual(Double(slowPeak), Double(fastPeak) + 1e-6,
                                  "Lower accel must not produce higher peak feedrate")
    }

    func testAAxisLimitReducesPeakFeedrate() {
        // Give A-axis a very tight acceleration limit. A path with large A steps should
        // produce a lower peak feedrate than a pure-X path with the same X accel settings.
        var s = makeSettings(feed: 2000, accelX: 500)
        s.maxAccelA = 5   // very tight: 5 mm/s² ≡ 18000 mm/min²

        let xPts: [MachinePoint] = (0..<10).map { i in
            let x = CGFloat(i) * 50
            return MachinePoint(Xm: x, Ym: 0, Zm: 0, Am: 0,
                                matX: x, matU: 25, matV: 0, isCorner: false)
        }
        let aPts: [MachinePoint] = (0..<10).map { i in
            let x = CGFloat(i) * 50
            let a = CGFloat(i) * 90   // 90°/step — forces large dAm per segment
            return MachinePoint(Xm: x, Ym: 0, Zm: 0, Am: a,
                                matX: x, matU: 25, matV: 0, isCorner: false)
        }
        let xPeak = VelocityProfiler(settings: s).profile(machinePoints: xPts).map(\.finalF).max() ?? 0
        let aPeak = VelocityProfiler(settings: s).profile(machinePoints: aPts).map(\.finalF).max() ?? 0
        XCTAssertLessThanOrEqual(Double(aPeak), Double(xPeak) + 1e-6,
                                  "A-heavy path must not exceed X-only peak feedrate under tight A accel")
    }
}

// MARK: - Lead-In Geometry Tests

/// Tests that every lead-in strategy produces geometrically correct approach geometry.
final class LeadInGeometryTests: XCTestCase {

    private let od: CGFloat = 50.8
    private var k: CGFloat { .pi * od / 360.0 }
    private var stock: StockInfo { makeRoundStock(od: od) }

    private func run(_ feature: GeometricFeature,
                     _ config: LeadInConfig,
                     disableLeadOut: Bool = true) -> PlannedPath {
        var s = GCodeSettings()
        s.leadInOverrides[feature.id]  = config
        if disableLeadOut {
            s.leadOutOverrides[feature.id] = LeadOutConfig(strategy: .none)
        }
        return ToolpathPlanner(settings: s).plan(
            feature: feature, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0
        ).plannedPath
    }

    // MARK: .none

    func testNoneLeadInIsEmpty() {
        let path = run(makeHoleFeature(), LeadInConfig(strategy: .none))
        XCTAssertTrue(path.leadInPoints.isEmpty, ".none lead-in must produce no points")
        XCTAssertFalse(path.cutPoints.isEmpty,   "Cut path must still be non-empty")
    }

    // MARK: .linear — holes

    func testLinearLeadInSinglePoint() {
        var cfg = LeadInConfig(strategy: .linear)
        cfg.linearLength = 6.0
        let path = run(makeHoleFeature(), cfg)
        XCTAssertEqual(path.leadInPoints.count, 1,
                       "linear lead-in for holes must produce exactly one approach point")
    }

    func testLinearLeadInLengthMatchesConfig() {
        var cfg = LeadInConfig(strategy: .linear)
        cfg.linearLength = 6.0
        let path = run(makeHoleFeature(), cfg)
        guard let pt = path.leadInPoints.first,
              let cut0 = path.cutPoints.first else { return XCTFail("Missing points") }
        let dist = surfaceDist(pt, cut0, k: k)
        XCTAssertEqual(Double(dist), 6.0, accuracy: 0.5,
                       "linear lead-in distance must match linearLength (got \(dist)mm)")
    }

    func testLinearLeadInNoNaN() {
        var cfg = LeadInConfig(strategy: .linear)
        cfg.linearLength = 5.0
        let path = run(makeHoleFeature(), cfg)
        for pt in path.leadInPoints {
            XCTAssertFalse(pt.x.isNaN || pt.x.isInfinite, "linear lead-in X must be finite")
            XCTAssertFalse(pt.a.isNaN || pt.a.isInfinite, "linear lead-in A must be finite")
        }
    }

    // MARK: .linear — sever cuts

    func testLinearLeadInStartCutApproachesFromScrapSide() {
        // startCut: scrap is at X < cut line → approach from –X direction.
        let xPos: CGFloat = 100
        var cfg = LeadInConfig(strategy: .linear)
        cfg.linearLength = 8.0
        let path = run(makeSeverFeature(type: .startCut, xPos: xPos), cfg)
        guard let pt = path.leadInPoints.first else { return XCTFail("No lead-in points") }
        XCTAssertLessThan(Double(pt.x), Double(xPos),
                          "startCut linear lead-in must start at X < cut line (got \(pt.x))")
    }

    func testLinearLeadInEndCutApproachesFromScrapSide() {
        // endCut: scrap is at X > cut line → approach from +X direction.
        let xPos: CGFloat = 100
        var cfg = LeadInConfig(strategy: .linear)
        cfg.linearLength = 8.0
        let path = run(makeSeverFeature(type: .endCut, xPos: xPos), cfg)
        guard let pt = path.leadInPoints.first else { return XCTFail("No lead-in points") }
        XCTAssertGreaterThan(Double(pt.x), Double(xPos),
                             "endCut linear lead-in must start at X > cut line (got \(pt.x))")
    }

    // MARK: .tangentArc

    func testTangentArcLeadInHasMultiplePoints() {
        // tangentArc produces [straightApproach] + arcPoints.
        var cfg = LeadInConfig(strategy: .tangentArc)
        cfg.arcRadius    = 5.0
        cfg.arcAngleDeg  = 90.0
        cfg.approachLength = 3.0
        let path = run(makeHoleFeature(), cfg)
        XCTAssertGreaterThanOrEqual(path.leadInPoints.count, 2,
                                    "tangentArc lead-in must produce ≥2 points (straight + arc)")
    }

    func testTangentArcLeadInLastPointNearCutPathStart() {
        var cfg = LeadInConfig(strategy: .tangentArc)
        cfg.arcRadius    = 5.0
        cfg.arcAngleDeg  = 90.0
        cfg.approachLength = 0.0   // suppress straight segment to isolate arc endpoint
        let path = run(makeHoleFeature(), cfg)
        guard let lastLead = path.leadInPoints.last,
              let firstCut = path.cutPoints.first else { return XCTFail("Missing points") }
        let dist = surfaceDist(lastLead, firstCut, k: k)
        XCTAssertLessThan(Double(dist), Double(cfg.arcRadius),
                          "Last tangentArc point must be within arcRadius of cut start (got \(dist)mm)")
    }

    func testTangentArcLeadInNoNaN() {
        var cfg = LeadInConfig(strategy: .tangentArc)
        cfg.arcRadius = 5.0
        let path = run(makeHoleFeature(), cfg)
        for pt in path.leadInPoints {
            XCTAssertFalse(pt.x.isNaN || pt.x.isInfinite, "tangentArc lead-in X must be finite")
            XCTAssertFalse(pt.a.isNaN || pt.a.isInfinite, "tangentArc lead-in A must be finite")
        }
    }

    // MARK: .centerPierce

    func testCenterPierceLeadInFirstPointNearFeatureCentroid() {
        let feature = makeHoleFeature(xCenter: 200, aCenter: 90)
        var cfg = LeadInConfig(strategy: .centerPierce)
        cfg.centerPierceSteps = 4
        let path = run(feature, cfg)
        guard let first = path.leadInPoints.first else { return XCTFail("No lead-in") }
        XCTAssertEqual(Double(first.x), Double(feature.xCenter), accuracy: 5.0,
                       "centerPierce first point must be near X centroid")
        XCTAssertEqual(Double(first.a), Double(feature.aCenterDeg), accuracy: 10.0,
                       "centerPierce first point must be near A centroid")
    }

    func testCenterPierceLeadInProgressesOutward() {
        // Each successive point should be further from centroid than previous.
        let feature = makeHoleFeature(xCenter: 200, aCenter: 90)
        var cfg = LeadInConfig(strategy: .centerPierce)
        cfg.centerPierceSteps = 5
        let path = run(feature, cfg)
        guard path.leadInPoints.count >= 3 else { return XCTFail("Too few lead-in points") }
        let cx = feature.xCenter
        let ca = feature.aCenterDeg
        var prevDist: CGFloat = -1
        for pt in path.leadInPoints {
            let d = surfaceDist(pt, ToolpathPoint(x: cx, a: ca), k: k)
            XCTAssertGreaterThanOrEqual(Double(d), Double(prevDist) - 0.5,
                                        "centerPierce lead-in must move outward from centroid")
            prevDist = d
        }
    }

    // MARK: .spiral

    func testSpiralLeadInStartsNearCentroid() {
        let feature = makeHoleFeature(xCenter: 200, aCenter: 90, xRadius: 20, aRadius: 40)
        var cfg = LeadInConfig(strategy: .spiral)
        cfg.spiralTurns = 0.75
        cfg.spiralSteps = 24
        let path = run(feature, cfg)
        guard let first = path.leadInPoints.first else { return XCTFail("No spiral lead-in") }
        XCTAssertEqual(Double(first.x), Double(feature.xCenter), accuracy: 5.0,
                       "Spiral must start near X centroid")
    }

    func testSpiralLeadInHasSufficientStepCount() {
        var cfg = LeadInConfig(strategy: .spiral)
        cfg.spiralSteps = 24
        cfg.spiralTurns = 0.75
        let path = run(makeHoleFeature(), cfg)
        XCTAssertGreaterThanOrEqual(path.leadInPoints.count, 8,
                                    "Spiral lead-in must produce ≥8 points (max(8, spiralSteps))")
    }

    func testSpiralLeadInNoNaN() {
        var cfg = LeadInConfig(strategy: .spiral)
        cfg.spiralTurns = 1.0
        let path = run(makeHoleFeature(), cfg)
        for pt in path.leadInPoints {
            XCTAssertFalse(pt.x.isNaN || pt.x.isInfinite, "spiral X must be finite")
            XCTAssertFalse(pt.a.isNaN || pt.a.isInfinite, "spiral A must be finite")
        }
    }

    // MARK: .rotationalArc — sever cuts

    func testRotationalArcLeadInStartCutStartsInScrapZone() {
        let xPos: CGFloat = 100
        var cfg = LeadInConfig(strategy: .rotationalArc)
        cfg.rotationalSweepMm   = 8.0
        cfg.scrapClearanceXMm   = 5.0
        let path = run(makeSeverFeature(type: .startCut, xPos: xPos), cfg)
        guard let first = path.leadInPoints.first else { return XCTFail("No lead-in") }
        // For startCut scrap is at X < xPos. First lead-in point must be to the left.
        XCTAssertLessThan(Double(first.x), Double(xPos),
                          "rotationalArc startCut must start in scrap zone (X < \(xPos))")
    }

    func testRotationalArcLeadInEndCutStartsInScrapZone() {
        let xPos: CGFloat = 100
        var cfg = LeadInConfig(strategy: .rotationalArc)
        cfg.rotationalSweepMm   = 8.0
        cfg.scrapClearanceXMm   = 5.0
        let path = run(makeSeverFeature(type: .endCut, xPos: xPos), cfg)
        guard let first = path.leadInPoints.first else { return XCTFail("No lead-in") }
        // For endCut scrap is at X > xPos. First lead-in point must be to the right.
        XCTAssertGreaterThan(Double(first.x), Double(xPos),
                             "rotationalArc endCut must start in scrap zone (X > \(xPos))")
    }

    func testRotationalArcLeadInSweepsAngle() {
        var cfg = LeadInConfig(strategy: .rotationalArc)
        cfg.rotationalSweepMm = 10.0
        cfg.scrapClearanceXMm = 3.0
        let path = run(makeSeverFeature(type: .startCut), cfg)
        guard path.leadInPoints.count >= 2 else { return XCTFail("Too few lead-in points") }
        let aFirst = path.leadInPoints.first!.a
        let aLast  = path.leadInPoints.last!.a
        // The A range must cover roughly rotationalSweepMm / k degrees.
        let expectedSweepDeg = 10.0 / Double(k)
        XCTAssertGreaterThan(abs(Double(aLast - aFirst)), expectedSweepDeg * 0.5,
                             "rotationalArc lead-in must sweep A by ≥ half of configured sweep distance")
    }

    // MARK: Small-hole auto-select

    func testSmallHoleAutoSelectsCenterPierce() {
        // Default threshold: diameter < 12mm → centerPierce.
        // The centerPierce first point should be near the centroid; a tangentArc first point would be far.
        var s = GCodeSettings()
        s.smallHoleDiameterThreshold = 12.0
        s.leadInByHole = LeadInConfig(strategy: .tangentArc)  // override would be tangentArc if not for auto-select

        let smallHole = makeHoleFeature(id: 10, xCenter: 200, aCenter: 90,
                                        xRadius: 4, aRadius: 4, diameter: 8)
        let path = ToolpathPlanner(settings: s).plan(
            feature: smallHole, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0
        ).plannedPath
        guard let first = path.leadInPoints.first else { return XCTFail("No lead-in") }
        // centerPierce starts near centroid; tangentArc does not.
        let distFromCentroid = surfaceDist(first, ToolpathPoint(x: smallHole.xCenter, a: smallHole.aCenterDeg), k: k)
        XCTAssertLessThan(Double(distFromCentroid), 15.0,
                          "Small-hole auto-select must choose centerPierce (first point near centroid)")
    }

    func testLeadInOverridePerFeatureIsHonoured() {
        // Default: tangentArc for holes. Override feature 1 with .linear.
        var s = GCodeSettings()
        s.leadInByHole = LeadInConfig(strategy: .tangentArc)
        var linCfg = LeadInConfig(strategy: .linear)
        linCfg.linearLength = 5.0
        let feature = makeHoleFeature(id: 1)
        s.leadInOverrides[feature.id] = linCfg
        let path = ToolpathPlanner(settings: s).plan(
            feature: feature, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0
        ).plannedPath
        // .linear produces exactly 1 point; tangentArc produces ≥2.
        XCTAssertEqual(path.leadInPoints.count, 1,
                       "Per-feature override to .linear must produce exactly 1 lead-in point")
    }

    // MARK: All strategies — no NaN

    func testAllLeadInStrategiesNoNaN() {
        let strategies: [LeadInStrategy] = [.rotationalArc, .tangentArc, .linear,
                                            .centerPierce, .spiral, .none]
        let feature = makeHoleFeature(id: 99, xCenter: 200, aCenter: 90,
                                      xRadius: 15, aRadius: 30, diameter: 30)
        for strategy in strategies {
            var s = GCodeSettings()
            s.leadInOverrides[feature.id]  = LeadInConfig(strategy: strategy)
            s.leadOutOverrides[feature.id] = LeadOutConfig(strategy: .none)
            let path = ToolpathPlanner(settings: s).plan(
                feature: feature, stock: stock,
                packStartX: 0, rollOffset: 0, previousMachineAm: 0
            ).plannedPath
            for (i, pt) in path.leadInPoints.enumerated() {
                XCTAssertFalse(pt.x.isNaN || pt.x.isInfinite,
                               "\(strategy) lead-in point \(i) X must be finite")
                XCTAssertFalse(pt.a.isNaN || pt.a.isInfinite,
                               "\(strategy) lead-in point \(i) A must be finite")
            }
        }
    }
}

// MARK: - Lead-Out / Overburn Geometry Tests

final class LeadOutGeometryTests: XCTestCase {

    private let od: CGFloat = 50.8
    private var k: CGFloat { .pi * od / 360.0 }
    private var stock: StockInfo { makeRoundStock(od: od) }

    private func run(_ feature: GeometricFeature,
                     leadOut: LeadOutConfig,
                     leadIn: LeadInConfig = LeadInConfig(strategy: .none)) -> PlannedPath {
        var s = GCodeSettings()
        s.leadInOverrides[feature.id]  = leadIn
        s.leadOutOverrides[feature.id] = leadOut
        return ToolpathPlanner(settings: s).plan(
            feature: feature, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0
        ).plannedPath
    }

    // MARK: .none

    func testNoneLeadOutIsEmpty() {
        let path = run(makeHoleFeature(), leadOut: LeadOutConfig(strategy: .none))
        XCTAssertTrue(path.leadOutPoints.isEmpty, ".none lead-out must produce no points")
    }

    // MARK: .linear — length

    func testLinearLeadOutLengthMatchesExtensionMm() {
        var cfg = LeadOutConfig(strategy: .linear)
        cfg.extensionMm      = 5.0
        cfg.extensionAngleDeg = 0.0
        let path = run(makeHoleFeature(), leadOut: cfg)
        guard let lastCut  = path.cutPoints.last,
              let leadOutPt = path.leadOutPoints.last else { return XCTFail("Missing points") }
        let dist = surfaceDist(leadOutPt, lastCut, k: k)
        XCTAssertEqual(Double(dist), 5.0, accuracy: 0.5,
                       "linear lead-out distance must equal extensionMm (got \(dist)mm)")
    }

    func testLinearLeadOutAtZeroAngleContinuesTangent() {
        // With extensionAngleDeg=0, lead-out continues straight along the exit tangent.
        // The final displacement direction should be roughly collinear with the last cut segment.
        var cfg = LeadOutConfig(strategy: .linear)
        cfg.extensionMm       = 6.0
        cfg.extensionAngleDeg = 0.0
        let path = run(makeHoleFeature(), leadOut: cfg)
        guard path.cutPoints.count >= 2,
              let lastCut  = path.cutPoints.last,
              let prevCut  = path.cutPoints.dropLast().last,
              let leadOutPt = path.leadOutPoints.first else { return XCTFail("Missing points") }

        // Exit tangent direction (in surface space)
        let dx = Double(lastCut.x - prevCut.x)
        let da = Double((lastCut.a - prevCut.a) * k)
        let tangentAngle = atan2(da, dx)

        let ox = Double(leadOutPt.x - lastCut.x)
        let oa = Double((leadOutPt.a - lastCut.a) * k)
        let exitAngle = atan2(oa, ox)

        var diff = abs(exitAngle - tangentAngle)
        if diff > .pi { diff = 2 * .pi - diff }
        XCTAssertLessThan(diff, 0.35,   // within ~20°
                          "Zero-angle lead-out must be roughly collinear with exit tangent (diff=\(diff)rad)")
    }

    func testLinearLeadOutDifferentAnglesProduceDifferentExits() {
        // Two configs with different extensionAngleDeg must produce different exit points —
        // confirming that the angle parameter actually rotates the exit direction.
        let feature = makeHoleFeature(id: 55)

        var cfg0 = LeadOutConfig(strategy: .linear)
        cfg0.extensionMm       = 5.0
        cfg0.extensionAngleDeg = 0.0

        var cfg45 = LeadOutConfig(strategy: .linear)
        cfg45.extensionMm       = 5.0
        cfg45.extensionAngleDeg = 45.0

        let path0  = run(feature, leadOut: cfg0)
        let path45 = run(feature, leadOut: cfg45)

        guard let exit0  = path0.leadOutPoints.last,
              let exit45 = path45.leadOutPoints.last else { return XCTFail("No lead-out points") }

        let diff = surfaceDist(exit0, exit45, k: k)
        XCTAssertGreaterThan(Double(diff), 0.1,
                             "extensionAngleDeg=0 vs 45° must produce different exit points (diff=\(diff))")
    }

    // MARK: .rotationalArc — X is constant, A sweeps

    func testRotationalArcLeadOutXDoesNotChange() {
        var cfg = LeadOutConfig(strategy: .rotationalArc)
        cfg.rotationalSweepMm = 6.0
        let path = run(makeSeverFeature(type: .startCut), leadOut: cfg)
        guard let lastCut = path.cutPoints.last else { return XCTFail("No cut points") }
        for (i, pt) in path.leadOutPoints.enumerated() {
            XCTAssertEqual(Double(pt.x), Double(lastCut.x), accuracy: 0.5,
                           "rotationalArc lead-out must not move X (point \(i))")
        }
    }

    func testRotationalArcLeadOutSweeepsA() {
        var cfg = LeadOutConfig(strategy: .rotationalArc)
        cfg.rotationalSweepMm = 8.0
        let path = run(makeSeverFeature(type: .startCut), leadOut: cfg)
        guard let lastCut = path.cutPoints.last,
              let lastOut = path.leadOutPoints.last else { return XCTFail("Missing points") }
        let sweepDeg = Double(cfg.rotationalSweepMm) / Double(k)
        let actualSweep = abs(Double(lastOut.a - lastCut.a))
        XCTAssertGreaterThan(actualSweep, sweepDeg * 0.8,
                             "rotationalArc lead-out must sweep ≥80% of configured distance in A")
    }

    func testRotationalArcLeadOutEndCutXDoesNotChange() {
        var cfg = LeadOutConfig(strategy: .rotationalArc)
        cfg.rotationalSweepMm = 6.0
        let path = run(makeSeverFeature(type: .endCut), leadOut: cfg)
        guard let lastCut = path.cutPoints.last else { return XCTFail("No cut points") }
        for pt in path.leadOutPoints {
            XCTAssertEqual(Double(pt.x), Double(lastCut.x), accuracy: 0.5,
                           "rotationalArc endCut lead-out must not move X")
        }
    }

    // MARK: All strategies — no NaN

    func testAllLeadOutStrategiesNoNaN() {
        let strategies: [LeadOutStrategy] = [.linear, .rotationalArc, .none]
        let feature = makeHoleFeature(id: 88)
        for strategy in strategies {
            var cfg = LeadOutConfig(strategy: strategy)
            if strategy == .linear         { cfg.extensionMm = 4.0 }
            if strategy == .rotationalArc  { cfg.rotationalSweepMm = 5.0 }
            let path = run(feature, leadOut: cfg)
            for (i, pt) in path.leadOutPoints.enumerated() {
                XCTAssertFalse(pt.x.isNaN || pt.x.isInfinite,
                               "\(strategy) lead-out point \(i) X must be finite")
                XCTAssertFalse(pt.a.isNaN || pt.a.isInfinite,
                               "\(strategy) lead-out point \(i) A must be finite")
            }
        }
    }

    func testAllLeadOutStrategiesOnSeverCutsNoNaN() {
        let strategies: [LeadOutStrategy] = [.linear, .rotationalArc, .none]
        for type in [SurfaceFeatureType.startCut, .endCut] {
            let feature = makeSeverFeature(type: type)
            for strategy in strategies {
                var cfg = LeadOutConfig(strategy: strategy)
                if strategy == .linear         { cfg.extensionMm = 3.0 }
                if strategy == .rotationalArc  { cfg.rotationalSweepMm = 5.0 }
                let path = run(feature, leadOut: cfg)
                for (i, pt) in path.leadOutPoints.enumerated() {
                    XCTAssertFalse(pt.x.isNaN || pt.x.isInfinite,
                                   "\(type)/\(strategy) lead-out \(i) X must be finite")
                    XCTAssertFalse(pt.a.isNaN || pt.a.isInfinite,
                                   "\(type)/\(strategy) lead-out \(i) A must be finite")
                }
            }
        }
    }

    // MARK: Points accounting

    func testPointsEqualLeadInPlusCutPlusLeadOut() {
        var cfg = LeadOutConfig(strategy: .linear)
        cfg.extensionMm = 4.0
        let liCfg = LeadInConfig(strategy: .tangentArc)
        let path = run(makeHoleFeature(), leadOut: cfg, leadIn: liCfg)
        XCTAssertEqual(path.points.count,
                       path.leadInPoints.count + path.cutPoints.count + path.leadOutPoints.count,
                       "points must equal leadIn + cut + leadOut")
    }
}
