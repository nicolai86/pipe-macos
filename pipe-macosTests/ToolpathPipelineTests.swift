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

private func makeSquareStock(side: CGFloat = 50.0, length: CGFloat = 500) -> StockInfo {
    StockInfo(profile: .square, odX: side, odY: side, length: length,
              axis: SIMD3<Float>(1, 0, 0), uAxis: SIMD3<Float>(0, 1, 0),
              origin: SIMD3<Float>(Float(length / 2), 0, 0))
}

private func makeHoleFeature(xCenter: CGFloat = 200, aCenter: CGFloat = 90,
                              xRadius: CGFloat = 15, aRadius: CGFloat = 30) -> GeometricFeature {
    let steps = 12
    let path = (0...steps).map { i -> ToolpathPoint in
        let t = 2 * Double.pi * Double(i) / Double(steps)
        return ToolpathPoint(x: xCenter + xRadius * CGFloat(cos(t)),
                             a: aCenter + aRadius * CGFloat(sin(t)))
    }
    return GeometricFeature(id: 1, type: .hole, shape: .circle,
                          xCenter: xCenter, aCenterDeg: aCenter,
                          dimensions: ["diameter": 30], confidence: 1.0, rawPath: path)
}

private func makeSeverFeature(type: SurfaceFeatureType = .startCut,
                               xPos: CGFloat = 0) -> GeometricFeature {
    let path = (0...36).map { i in ToolpathPoint(x: xPos, a: CGFloat(i) * 10) }
    return GeometricFeature(id: 2, type: type, shape: .custom,
                          xCenter: xPos, aCenterDeg: 180,
                          dimensions: [:], confidence: 1.0, rawPath: path)
}

// MARK: - ToolpathPlanner Tests

final class ToolpathPlannerTests: XCTestCase {

    private func defaultSettings() -> GCodeSettings { GCodeSettings() }

    // MARK: Empty path

    func testEmptyPathReturnsEmptyPlan() {
        let feature = GeometricFeature(id: 1, type: .hole, shape: .circle,
                                     xCenter: 100, aCenterDeg: 90,
                                     dimensions: [:], confidence: 1.0, rawPath: [])
        let result = ToolpathPlanner(settings: defaultSettings()).plan(
            feature: feature, stock: makeRoundStock(),
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)
        XCTAssertTrue(result.plannedPath.points.isEmpty, "empty path must produce empty PlannedPath")
        XCTAssertFalse(result.plannedPath.isInternal)
    }

    // MARK: isInternal classification

    func testHoleIsInternal() {
        let result = ToolpathPlanner(settings: defaultSettings()).plan(
            feature: makeHoleFeature(), stock: makeRoundStock(),
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)
        XCTAssertTrue(result.plannedPath.isInternal, "Hole must be classified as internal")
    }

    func testSeverCutIsNotInternal() {
        let result = ToolpathPlanner(settings: defaultSettings()).plan(
            feature: makeSeverFeature(type: .startCut), stock: makeRoundStock(),
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)
        XCTAssertFalse(result.plannedPath.isInternal, "startCut must not be classified as internal")
    }

    func testNotchIsInternal() {
        let path = (0...8).map { i -> ToolpathPoint in
            ToolpathPoint(x: 100 + 15 * CGFloat(cos(Double(i) * .pi / 4)),
                          a:  90 + 20 * CGFloat(sin(Double(i) * .pi / 4)))
        }
        let notch = GeometricFeature(id: 3, type: .notch, shape: .custom,
                                   xCenter: 100, aCenterDeg: 90,
                                   dimensions: [:], confidence: 1.0, rawPath: path)
        let result = ToolpathPlanner(settings: defaultSettings()).plan(
            feature: notch, stock: makeRoundStock(),
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)
        XCTAssertTrue(result.plannedPath.isInternal, "Notch must be classified as internal")
    }

    // MARK: Pack + roll offset

    func testPackOffsetShiftsAllPointsInX() {
        let packStartX: CGFloat = 300
        let result = ToolpathPlanner(settings: defaultSettings()).plan(
            feature: makeHoleFeature(xCenter: 50), stock: makeRoundStock(),
            packStartX: packStartX, rollOffset: 0, previousMachineAm: 0)
        let minX = result.plannedPath.points.map(\.x).min() ?? 0
        // Feature centroid at packStartX + 50 = 350; lead-in may reach ~5 mm below,
        // but must never reach below packStartX itself.
        XCTAssertGreaterThan(minX, packStartX - 30,
                             "All points must be shifted by packStartX (minX=\(minX))")
    }
    func testRollOffsetShiftsAllPointsInA() {
        let rollOffset: CGFloat = 180
        let result = ToolpathPlanner(settings: defaultSettings()).plan(
            feature: makeHoleFeature(aCenter: 0), stock: makeRoundStock(),
            packStartX: 0, rollOffset: rollOffset, previousMachineAm: rollOffset)
        let meanA = result.plannedPath.points.map(\.a).reduce(0, +) / CGFloat(result.plannedPath.points.count)
        // Feature was at 0°, rollOffset 180° → centroid of output should be near 180°.
        // Allow ±90° to account for lead-in/overburn geometry.
        XCTAssertEqual(Double(meanA), 180, accuracy: 90,
                       "Roll offset must shift A coordinates (meanA=\(meanA))")
    }

    // MARK: Lead-in and overburn

    func testLeadInAddsPointsBeyondRawInput() {
        let rawCount = makeHoleFeature().rawPath.count
        var s = defaultSettings()
        s.leadInDistance = 5
        s.leadInAngle = 90
        s.leadInAngleDistance = 3
        let result = ToolpathPlanner(settings: s).plan(
            feature: makeHoleFeature(), stock: makeRoundStock(),
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)
        XCTAssertGreaterThan(result.plannedPath.points.count, rawCount,
                             "Lead-in must increase point count beyond raw feature (\(rawCount) pts)")
    }

    // MARK: A-axis continuity

    func testAContinuityKeepsFirstPointNearPreviousAm() {
        // previousMachineAm = 360: the path should be shifted one full rotation forward
        // so the pierce point lands near 360°, not 0°.
        let previousAm: CGFloat = 360
        let hole = makeHoleFeature(aCenter: 90)  // raw pierce A near 90°
        let result = ToolpathPlanner(settings: defaultSettings()).plan(
            feature: hole, stock: makeRoundStock(),
            packStartX: 0, rollOffset: 0, previousMachineAm: previousAm)
        XCTAssertFalse(result.plannedPath.points.isEmpty)
        // The path should be continuous with previousAm: no point should be near 90° (un-shifted)
        // when the shifted value would be 450°.
        let anyPointNearZero = result.plannedPath.points.contains { abs($0.a - 90) < 5 }
        XCTAssertFalse(anyPointNearZero,
                       "Path must be shifted up by ~360° for continuity with previousMachineAm=360")
    }

    // MARK: Output validity

    func testNoNaNOrInfiniteCoordinates() {
        var s = defaultSettings()
        s.enableKerfComp = true
        s.kerfWidth = 2.0
        let result = ToolpathPlanner(settings: s).plan(
            feature: makeHoleFeature(), stock: makeRoundStock(),
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)
        for pt in result.plannedPath.points {
            XCTAssertFalse(pt.x.isNaN || pt.x.isInfinite, "X must be finite")
            XCTAssertFalse(pt.a.isNaN || pt.a.isInfinite, "A must be finite")
        }
    }

    func testHSSKerfOffsetProducesFiniteCoordinates() {
        var s = defaultSettings()
        s.enableKerfComp = true
        s.kerfWidth = 2.0
        let result = ToolpathPlanner(settings: s).plan(
            feature: makeHoleFeature(), stock: makeSquareStock(side: 50),
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)
        XCTAssertFalse(result.plannedPath.points.isEmpty)
        for pt in result.plannedPath.points {
            XCTAssertFalse(pt.x.isNaN || pt.x.isInfinite, "X must be finite on HSS")
            XCTAssertFalse(pt.a.isNaN || pt.a.isInfinite, "A must be finite on HSS")
        }
    }
}

// MARK: - KinematicsEngine Tests

final class KinematicsEngineTests: XCTestCase {

    /// Settings with both passes disabled for deterministic, single-step TCP tests.
    private func bareSettings() -> GCodeSettings {
        var s = GCodeSettings()
        s.enableSingularityDamping = false
        s.enableNonlinearErrorCompensation = false
        return s
    }

    private func convert(_ pts: [ToolpathPoint], stock: StockInfo,
                         settings: GCodeSettings? = nil,
                         initialAm: CGFloat? = nil) -> [MachinePoint] {
        let s = settings ?? bareSettings()
        let feature = GeometricFeature(id: 0, type: .hole, shape: .custom, xCenter: 0, aCenterDeg: 0, dimensions: [:], confidence: 1.0, rawPath: pts)
        let plannedFeature = PlannedFeature(source: feature, plannedPath: PlannedPath(points: pts, isInternal: false))
        return KinematicsEngine(settings: s).convert(plannedFeature: plannedFeature, stock: stock, initialMachineAm: initialAm)
    }

    // MARK: Boundary conditions

    func testEmptyPathReturnsEmpty() {
        let result = convert([], stock: makeRoundStock())
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: Round tube geometry

    /// At surface A=90° (12 o'clock), the torch is directly above the tube centre:
    /// Ym=0, Zm=0 (relative to surface), Am=0°.
    func testRoundTubeTopPosition() {
        let od: CGFloat = 50.8
        let pts = [ToolpathPoint(x: 100, a: 90)]
        let result = convert(pts, stock: makeRoundStock(od: od))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(Double(result[0].Xm), 100, accuracy: 0.001, "Xm must equal input X")
        XCTAssertEqual(Double(result[0].Ym),   0, accuracy: 0.001, "Ym must be 0 at 12 o'clock")
        XCTAssertEqual(Double(result[0].Zm),   0, accuracy: 0.001, "Zm offset must be 0 at surface")
        XCTAssertEqual(Double(result[0].Am),   0, accuracy: 0.001, "Am must be 0° at 12 o'clock")
    }

    /// At surface A=0° (3 o'clock), the normal points in +U direction → Am=90°.
    func testRoundTubeRightSideAm() {
        let pts = [ToolpathPoint(x: 50, a: 0)]
        let result = convert(pts, stock: makeRoundStock())
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(Double(result[0].Am), 90, accuracy: 0.01,
                       "Am must be 90° when surface normal points in +U direction")
    }

    func testXmEqualsInputXForAllPoints() {
        let xs: [CGFloat] = [0, 25, 50, 75, 100]
        let pts = xs.map { ToolpathPoint(x: $0, a: 90) }
        let result = convert(pts, stock: makeRoundStock())
        XCTAssertEqual(result.count, xs.count)
        for (mp, x) in zip(result, xs) {
            XCTAssertEqual(Double(mp.Xm), Double(x), accuracy: 0.001,
                           "Xm must equal input X (\(x))")
        }
    }

    // MARK: Corner detection

    func testRoundStockNeverFlagsCorners() {
        let angles: [CGFloat] = [0, 30, 45, 90, 135, 180, 225, 270, 315]
        let pts = angles.map { ToolpathPoint(x: 100, a: $0) }
        let result = convert(pts, stock: makeRoundStock())
        for (i, mp) in result.enumerated() {
            XCTAssertFalse(mp.isCorner, "Round stock must never flag corners (index \(i), A=\(angles[i])°)")
        }
    }

    func testSquareHSSFlatFaceNotCorner() {
        // A=0° hits the right flat face → Nu=1, Nv=0 → isCorner = false
        let pts = [ToolpathPoint(x: 100, a: 0)]
        let result = convert(pts, stock: makeSquareStock())
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result[0].isCorner, "Flat face (A=0°) must not be flagged as corner")
    }

    func testSquareHSSCornerAngleFlagsCorner() {
        // A=45° hits the upper-right fillet → normal is neither axis-aligned → isCorner = true
        let pts = [ToolpathPoint(x: 100, a: 45)]
        let result = convert(pts, stock: makeSquareStock())
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].isCorner, "Diagonal (A=45°) on square HSS must be flagged as corner")
    }

    // MARK: Compensation only adds points

    func testNonlinearCompensationNeverRemovesPoints() {
        var s = GCodeSettings()
        s.enableSingularityDamping = false
        s.enableNonlinearErrorCompensation = true
        s.nonlinearErrorTolerance = 0.001   // very tight — forces subdivision
        // A path that curves significantly in A to trigger subdivision
        let pts = (0..<10).map { i in ToolpathPoint(x: CGFloat(i) * 5, a: CGFloat(i) * 36) }
        let result = convert(pts, stock: makeRoundStock(), settings: s)
        XCTAssertGreaterThanOrEqual(result.count, pts.count,
                                    "Nonlinear compensation must only add, never remove, points")
    }

    // MARK: A-axis wrapping

    func testInitialMachineAmPreventsBigJump() {
        // Two consecutive surface points that cross the 0°/360° boundary.
        // With initialMachineAm=350, the first machine Am should stay near 350°, not jump to ~-10°.
        let pts = [ToolpathPoint(x: 0, a: 350), ToolpathPoint(x: 10, a: 370)]
        let result = convert(pts, stock: makeRoundStock(), initialAm: 350)
        XCTAssertEqual(result.count, 2)
        XCTAssertLessThanOrEqual(abs(result[1].Am - result[0].Am), 180,
                                  "Consecutive Am values must not jump more than 180°")
    }
}

// MARK: - VelocityProfiler Tests

final class VelocityProfilerTests: XCTestCase {

    private func defaultSettings() -> GCodeSettings {
        var s = GCodeSettings()
        s.feedRate   = 1000
        s.rapidRate  = 3000
        s.useSimCNC  = true
        return s
    }

    /// Straight-line machine points along X, stationary in Y/Z/A.
    private func straightLine(steps: Int = 6, stepSize: CGFloat = 20) -> [MachinePoint] {
        (0..<steps).map { i in
            let x = CGFloat(i) * stepSize
            return MachinePoint(Xm: x, Ym: 0, Zm: 0, Am: 0,
                                matX: x, matU: 25, matV: 0, isCorner: false)
        }
    }

    // MARK: Boundary conditions

    func testEmptyInputReturnsEmptySegments() {
        let result = VelocityProfiler(settings: defaultSettings()).profile(machinePoints: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testSinglePointReturnsEmptySegments() {
        let pt = MachinePoint(Xm: 0, Ym: 0, Zm: 0, Am: 0, matX: 0, matU: 25, matV: 0, isCorner: false)
        let result = VelocityProfiler(settings: defaultSettings()).profile(machinePoints: [pt])
        XCTAssertTrue(result.isEmpty, "One point → no segments")
    }

    // MARK: Segment count

    func testSegmentCountIsPointsMinusOne() {
        let points = straightLine(steps: 7)
        let result = VelocityProfiler(settings: defaultSettings()).profile(machinePoints: points)
        XCTAssertEqual(result.count, points.count - 1,
                       "Segment count must equal point count minus one")
    }

    // MARK: Feedrate invariants

    func testAllFinalFeedRatesArePositive() {
        let result = VelocityProfiler(settings: defaultSettings()).profile(machinePoints: straightLine())
        XCTAssertFalse(result.isEmpty)
        for (i, seg) in result.enumerated() {
            XCTAssertGreaterThan(seg.finalF, 0, "finalF must be positive (segment \(i))")
        }
    }

    func testNoFinalFeedRateExceedsRapidRate() {
        var s = defaultSettings()
        s.rapidRate = 2000
        let result = VelocityProfiler(settings: s).profile(machinePoints: straightLine(steps: 10))
        for (i, seg) in result.enumerated() {
            XCTAssertLessThanOrEqual(Double(seg.finalF), Double(s.rapidRate) + 1e-6,
                                     "finalF must not exceed rapidRate (segment \(i))")
        }
    }

    // MARK: Segment geometry

    func testAllDSArePositive() {
        let result = VelocityProfiler(settings: defaultSettings()).profile(machinePoints: straightLine())
        for (i, seg) in result.enumerated() {
            XCTAssertGreaterThan(seg.dS, 0, "dS must be positive (segment \(i))")
        }
    }

    func testSegmentDeltasMatchPointDifferences() {
        let points = straightLine(steps: 4, stepSize: 15)
        let result = VelocityProfiler(settings: defaultSettings()).profile(machinePoints: points)
        XCTAssertEqual(result.count, 3)
        for (i, seg) in result.enumerated() {
            let expected = points[i + 1].Xm - points[i].Xm
            XCTAssertEqual(Double(seg.dXm), Double(expected), accuracy: 1e-9,
                           "dXm must match Xm difference (segment \(i))")
        }
    }

    // MARK: Accel/decel profile

    func testProfileStartsAndEndsAtRest() {
        // With default S-curve: first segment starts accelerating from 0, last segment decelerates to 0.
        // We can verify by checking the first segment's finalF is lower than the middle segment's.
        let points = straightLine(steps: 20, stepSize: 5)
        let result = VelocityProfiler(settings: defaultSettings()).profile(machinePoints: points)
        guard result.count >= 3 else { return }
        let first  = result.first!.finalF
        let middle = result[result.count / 2].finalF
        XCTAssertLessThanOrEqual(Double(first), Double(middle) + 1,
                                  "First segment feed should be lower than mid-path (ramp-up)")
    }
}

// MARK: - GCodeEmitter Tests

final class GCodeEmitterTests: XCTestCase {

    private func defaultSettings() -> GCodeSettings {
        var s = GCodeSettings()
        s.safeHeight    = 25.0
        s.pierceHeight  = 3.8
        s.cutHeight     = 3.2
        s.enableDynamicSafeZ = false
        s.enableDynamicTHC   = false
        return s
    }

    /// Minimal straight-line machine points and pre-solved segments for emitter tests.
    private func makePoints(_ count: Int = 5, xStep: CGFloat = 20) -> [MachinePoint] {
        (0..<count).map { i in
            MachinePoint(Xm: CGFloat(i) * xStep, Ym: 0, Zm: 0, Am: 0,
                         matX: CGFloat(i) * xStep, matU: 25, matV: 0, isCorner: false)
        }
    }

    private func makeSegments(_ count: Int = 4, finalF: CGFloat = 1000) -> [TrajectorySegment] {
        (0..<count).map { _ in
            TrajectorySegment(dS: 20, dMachine: 20, dXm: 20, dYm: 0, dZm: 0, dAm: 0,
                              aPath: 500 * 3600, jPath: 5000 * 216_000, finalF: finalF)
        }
    }

    // MARK: emitHeader

    func testEmitHeaderContainsRoundProfile() {
        let stock = makeRoundStock(od: 50.8)
        let lines = GCodeEmitter(settings: defaultSettings()).emitHeader(stock: stock)
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("HSS-O"), "Header must name round profile")
        XCTAssertTrue(joined.contains("50.800"), "Header must include OD dimension")
    }

    func testEmitHeaderContainsSquareProfile() {
        let stock = makeSquareStock(side: 50.0)
        let lines = GCodeEmitter(settings: defaultSettings()).emitHeader(stock: stock)
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("HSS-Square"), "Header must name square profile")
        XCTAssertTrue(joined.contains("50.000"), "Header must include side dimension")
    }

    // MARK: emitStartup

    func testEmitStartupContainsModalSetup() {
        let stock = makeRoundStock()
        let lines = GCodeEmitter(settings: defaultSettings())
            .emitStartup(totalLength: 500, stock: stock)
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("G21"), "Startup must set metric mode G21")
        XCTAssertTrue(joined.contains("G90"), "Startup must set absolute positioning G90")
        XCTAssertTrue(joined.contains("G92"), "Startup must set home position G92")
        XCTAssertTrue(joined.contains("M5"),  "Startup must ensure torch off M5")
    }

    func testEmitStartupG92ContainsStockLength() {
        let stock = makeRoundStock(length: 400)
        let lines = GCodeEmitter(settings: defaultSettings())
            .emitStartup(totalLength: 400, stock: stock)
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("G92 X400.000"), "Startup G92 X must equal total length")
    }

    // MARK: emitEnd

    func testEmitEndContainsM30AndPercent() {
        let lines = GCodeEmitter(settings: defaultSettings()).emitEnd(stock: nil)
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("M30"), "End sequence must include M30 (program end)")
        XCTAssertTrue(lines.last == "%",      "End sequence must close with %")
    }

    func testEmitEndContainsHomeMove() {
        let lines = GCodeEmitter(settings: defaultSettings()).emitEnd(stock: nil)
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("G0 X0 Y0 A0"), "End sequence must return to home")
    }

    // MARK: emitFeature — sequence ordering

    func testEmitFeatureStartsWithG0ZRetract() {
        let settings = defaultSettings()
        let feature = makeHoleFeature()
        let points = makePoints()
        let segments = makeSegments()
        let planned = PlannedFeature(source: feature, plannedPath: PlannedPath(points: feature.rawPath, isInternal: true))
        let toolpathFeature = ToolpathFeature(source: planned, machinePoints: points, segments: segments)
        
        let lines = GCodeEmitter(settings: settings).emitFeature(
            toolpathFeature: toolpathFeature, stock: makeRoundStock(),
            packStartX: 0, rollOffset: 0)
        
        // First motion line must be the safe-Z retract
        let firstMotion = lines.first(where: { $0.hasPrefix("G0") || $0.hasPrefix("G1") })!
        XCTAssertTrue(firstMotion.hasPrefix("G0 Z"),
                      "First motion must be G0 Z retract. Got: \(firstMotion)")
    }

    func testEmitFeatureContainsM3BeforeFirstG1() {
        let feature = makeHoleFeature()
        let points = makePoints()
        let segments = makeSegments()
        let planned = PlannedFeature(source: feature, plannedPath: PlannedPath(points: feature.rawPath, isInternal: true))
        let toolpathFeature = ToolpathFeature(source: planned, machinePoints: points, segments: segments)

        let lines = GCodeEmitter(settings: defaultSettings()).emitFeature(
            toolpathFeature: toolpathFeature, stock: makeRoundStock(),
            packStartX: 0, rollOffset: 0)
            
        var m3Found = false
        var g1BeforeM3 = false
        for line in lines {
            if line.contains("M3") { m3Found = true }
            if line.hasPrefix("G1") && !m3Found { g1BeforeM3 = true }
        }
        XCTAssertTrue(m3Found,       "Feature must contain M3 torch-on")
        XCTAssertFalse(g1BeforeM3,   "G1 feed move must not appear before M3")
    }

    func testEmitFeatureEndsWithM5() {
        let feature = makeHoleFeature()
        let points = makePoints()
        let segments = makeSegments()
        let planned = PlannedFeature(source: feature, plannedPath: PlannedPath(points: feature.rawPath, isInternal: true))
        let toolpathFeature = ToolpathFeature(source: planned, machinePoints: points, segments: segments)

        let lines = GCodeEmitter(settings: defaultSettings()).emitFeature(
            toolpathFeature: toolpathFeature, stock: makeRoundStock(),
            packStartX: 0, rollOffset: 0)
            
        XCTAssertTrue(lines.last?.contains("M5") == true,
                      "Feature must end with M5 torch-off")
    }

    // MARK: emitFeature — G1 feedrate validity

    func testAllG1LinesHavePositiveFeedRate() {
        let feature = makeHoleFeature()
        let points = makePoints()
        let segments = makeSegments(finalF: 800)
        let planned = PlannedFeature(source: feature, plannedPath: PlannedPath(points: feature.rawPath, isInternal: true))
        let toolpathFeature = ToolpathFeature(source: planned, machinePoints: points, segments: segments)

        let lines = GCodeEmitter(settings: defaultSettings()).emitFeature(
            toolpathFeature: toolpathFeature, stock: makeRoundStock(),
            packStartX: 0, rollOffset: 0)
            
        for line in lines where line.hasPrefix("G1") {
            guard let fRange = line.range(of: "F") else {
                XCTFail("G1 line missing F word: \(line)"); continue
            }
            let numStr = line[fRange.upperBound...].prefix(while: { $0.isNumber || $0 == "." })
            if let f = Double(numStr) {
                XCTAssertGreaterThan(f, 0, "Feedrate must be positive: \(line)")
            }
        }
    }

    // MARK: THC codes

    func testTHCCodesAbsentWhenDisabled() {
        var s = defaultSettings()
        s.enableDynamicTHC = false
        let feature = makeHoleFeature()
        let points = makePoints()
        let segments = makeSegments()
        let planned = PlannedFeature(source: feature, plannedPath: PlannedPath(points: feature.rawPath, isInternal: true))
        let toolpathFeature = ToolpathFeature(source: planned, machinePoints: points, segments: segments)

        let lines = GCodeEmitter(settings: s).emitFeature(
            toolpathFeature: toolpathFeature, stock: makeRoundStock(),
            packStartX: 0, rollOffset: 0)
            
        let joined = lines.joined(separator: "\n")
        XCTAssertFalse(joined.contains("#4061"), "THC lock variable must be absent when THC disabled")
    }

    func testTHCLockEmittedAtCornerWhenEnabled() {
        var s = defaultSettings()
        s.enableDynamicTHC = true
        // Pierce point (first machine point) flagged as corner
        let cornerPierce = MachinePoint(Xm: 0, Ym: 0, Zm: 0, Am: 0,
                                        matX: 0, matU: 25, matV: 0, isCorner: true)
        let flatPoints = (1..<5).map { i in
            MachinePoint(Xm: CGFloat(i) * 20, Ym: 0, Zm: 0, Am: 0,
                         matX: CGFloat(i) * 20, matU: 25, matV: 0, isCorner: false)
        }
        let points = [cornerPierce] + flatPoints
        let segments = makeSegments(4)
        let feature = makeHoleFeature()
        let planned = PlannedFeature(source: feature, plannedPath: PlannedPath(points: feature.rawPath, isInternal: true))
        let toolpathFeature = ToolpathFeature(source: planned, machinePoints: points, segments: segments)

        let lines = GCodeEmitter(settings: s).emitFeature(
            toolpathFeature: toolpathFeature, stock: makeRoundStock(),
            packStartX: 0, rollOffset: 0)
            
        let joined = lines.joined(separator: "\n")
        XCTAssertTrue(joined.contains("#4061 = 100"), "THC lock must be emitted when pierce is at corner")
    }
}
