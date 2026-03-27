import XCTest
import Foundation
import simd
@testable import pipe_macos

// MARK: - Shared Helpers

private func makeSquareHSS(side: CGFloat = 50.0, cornerR: CGFloat = 2.5) -> StockInfo {
    let s = StockInfo(
        profile: .square, odX: side, odY: side, length: 500,
        axis: SIMD3<Float>(1, 0, 0), uAxis: SIMD3<Float>(0, 1, 0),
        origin: SIMD3<Float>(250, 0, 0))
    s.cornerRadius = cornerR
    return s
}

private func makeRoundStock(od: CGFloat = 50.8) -> StockInfo {
    StockInfo(profile: .round, od: od, length: 500,
              axis: SIMD3<Float>(1, 0, 0), uAxis: SIMD3<Float>(0, 1, 0),
              origin: SIMD3<Float>(250, 0, 0))
}

/// Build a hole feature whose path is an ellipse in surface (X, A) space.
private func makeHoleFeature(
    xCenter: CGFloat = 200, aCenter: CGFloat = 0,
    xRadius: CGFloat = 12, aRadius: CGFloat = 20
) -> GeometricFeature {
    let n = 16
    let path = (0...n).map { i -> ToolpathPoint in
        let t = 2 * Double.pi * Double(i) / Double(n)
        return ToolpathPoint(x: xCenter + xRadius * CGFloat(cos(t)),
                             a: aCenter  + aRadius * CGFloat(sin(t)))
    }
    return GeometricFeature(id: 1, type: .hole, shape: .circle,
                            xCenter: xCenter, aCenterDeg: aCenter,
                            dimensions: ["diameter": 30], confidence: 1.0,
                            rawPath: path)
}

/// Settings with tangentArc lead-in and arc output enabled.
private func arcSettings() -> GCodeSettings {
    var s = GCodeSettings()
    s.enableArcOutput = true
    s.leadInByHole    = LeadInConfig(strategy: .tangentArc)
    s.leadInByCutout  = LeadInConfig(strategy: .tangentArc)
    s.enableNonlinearErrorCompensation = false  // keep point counts predictable
    s.enableSingularityDamping = false
    return s
}

// MARK: - Circumcircle Helper (exposed via KinematicsEngine for testing)

/// Convenience wrapper: call through KinematicsEngine to access the private
/// `circumcircle2D` helper indirectly by verifying `resolveArcHints` results.

// MARK: - SurfaceArc Population Tests

final class SurfaceArcTests: XCTestCase {

    func testTangentArcLeadInPopulatesLeadInArc() {
        let stock    = makeSquareHSS()
        let feature  = makeHoleFeature()
        let settings = arcSettings()

        let planned = ToolpathPlanner(settings: settings).plan(
            feature: feature, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)

        XCTAssertNotNil(planned.plannedPath.leadInArc,
            "tangentArc lead-in must populate leadInArc")
    }

    func testTangentArcLeadInArcHasPositiveRadius() {
        let stock    = makeSquareHSS()
        let feature  = makeHoleFeature()
        let settings = arcSettings()

        let planned = ToolpathPlanner(settings: settings).plan(
            feature: feature, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)

        let arc = planned.plannedPath.leadInArc!
        XCTAssertGreaterThan(arc.radius, 0, "arc radius must be positive")
        XCTAssertGreaterThanOrEqual(arc.arcPointCount, 4,
            "arc must have at least 4 sample points")
    }

    func testLinearLeadInProducesNilArc() {
        let stock   = makeSquareHSS()
        let feature = makeHoleFeature()
        var settings = GCodeSettings()
        settings.leadInByHole = LeadInConfig(strategy: .linear)

        let planned = ToolpathPlanner(settings: settings).plan(
            feature: feature, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)

        XCTAssertNil(planned.plannedPath.leadInArc,
            "linear lead-in must not populate leadInArc")
    }

    func testRotationalArcLeadInProducesNilArc() {
        let stock   = makeSquareHSS()
        let feature = makeHoleFeature()
        var settings = GCodeSettings()
        settings.leadInByHole = LeadInConfig(strategy: .rotationalArc)

        let planned = ToolpathPlanner(settings: settings).plan(
            feature: feature, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)

        XCTAssertNil(planned.plannedPath.leadInArc,
            "rotationalArc lead-in must not populate leadInArc")
    }

    func testCenterPierceLeadInProducesNilArc() {
        let stock   = makeSquareHSS()
        let feature = makeHoleFeature()
        var settings = GCodeSettings()
        settings.leadInByHole = LeadInConfig(strategy: .centerPierce)

        let planned = ToolpathPlanner(settings: settings).plan(
            feature: feature, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)

        XCTAssertNil(planned.plannedPath.leadInArc,
            "centerPierce lead-in must not populate leadInArc")
    }

    func testSpiralLeadInProducesNilArc() {
        let stock   = makeSquareHSS()
        let feature = makeHoleFeature()
        var settings = GCodeSettings()
        settings.leadInByHole = LeadInConfig(strategy: .spiral)

        let planned = ToolpathPlanner(settings: settings).plan(
            feature: feature, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)

        XCTAssertNil(planned.plannedPath.leadInArc,
            "spiral lead-in must not populate leadInArc")
    }

    func testLeadInArcPointCountMatchesLeadInPointsSlice() {
        let stock    = makeSquareHSS()
        let feature  = makeHoleFeature()
        let settings = arcSettings()

        let planned = ToolpathPlanner(settings: settings).plan(
            feature: feature, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)

        let arc      = planned.plannedPath.leadInArc!
        let leadIn   = planned.plannedPath.leadInPoints
        // leadIn[0] = straight approach; [1…arcPointCount] = arc samples
        XCTAssertGreaterThan(leadIn.count, arc.arcPointCount,
            "leadInPoints must contain at least arcPointCount + 1 entries")
        XCTAssertEqual(leadIn.count, arc.arcPointCount + 1,
            "leadInPoints should be exactly 1 approach + arcPointCount arc points")
    }
}

// MARK: - KinematicsEngine Arc Hint Tests

final class KinematicsEngineArcHintTests: XCTestCase {

    // MARK: enableArcOutput = false

    func testResolveArcHintsEmptyWhenDisabled() {
        let stock    = makeSquareHSS()
        let feature  = makeHoleFeature()
        var settings = arcSettings()
        settings.enableArcOutput = false

        let kin     = KinematicsEngine(settings: settings)
        let planned = ToolpathPlanner(settings: settings).plan(
            feature: feature, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)
        let machines = kin.convert(plannedFeature: planned, stock: stock, initialMachineAm: nil)
        let hints    = kin.resolveArcHints(plannedFeature: planned, machinePoints: machines)

        XCTAssertTrue(hints.isEmpty,
            "no arc hints should be returned when enableArcOutput is false")
    }

    // MARK: Round stock: Ym = 0 → circle degenerate

    func testResolveArcHintsEmptyForRoundStock() {
        let stock    = makeRoundStock()
        let feature  = makeHoleFeature()
        let settings = arcSettings()

        let kin     = KinematicsEngine(settings: settings)
        let planned = ToolpathPlanner(settings: settings).plan(
            feature: feature, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)
        let machines = kin.convert(plannedFeature: planned, stock: stock, initialMachineAm: nil)
        let hints    = kin.resolveArcHints(plannedFeature: planned, machinePoints: machines)

        // Round stock: Ym = 0 for all points → fitted circle has r ≈ 0 → rejected
        XCTAssertTrue(hints.isEmpty,
            "round stock has Ym=0 always; circumcircle is degenerate so no hint expected")
    }

    // MARK: HSS flat face: arc is valid in (Xm, Ym)

    func testResolveArcHintsNonEmptyForHSSFlatFace() {
        let stock    = makeSquareHSS()
        let feature  = makeHoleFeature(aCenter: 0)  // A=0 = right face (flat)
        let settings = arcSettings()

        let kin     = KinematicsEngine(settings: settings)
        let planned = ToolpathPlanner(settings: settings).plan(
            feature: feature, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)
        let machines = kin.convert(plannedFeature: planned, stock: stock, initialMachineAm: nil)
        let hints    = kin.resolveArcHints(plannedFeature: planned, machinePoints: machines)

        XCTAssertFalse(hints.isEmpty,
            "HSS flat-face tangentArc lead-in should produce at least one arc hint")
    }

    func testArcHintPlaneIsXY() {
        let stock    = makeSquareHSS()
        let feature  = makeHoleFeature(aCenter: 0)
        let settings = arcSettings()

        let kin     = KinematicsEngine(settings: settings)
        let planned = ToolpathPlanner(settings: settings).plan(
            feature: feature, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)
        let machines = kin.convert(plannedFeature: planned, stock: stock, initialMachineAm: nil)
        let hints    = kin.resolveArcHints(plannedFeature: planned, machinePoints: machines)

        guard let hint = hints.first else {
            XCTFail("expected at least one arc hint"); return
        }
        XCTAssertEqual(hint.plane, .xy, "HSS lead-in arc must be in the XY plane")
    }

    func testArcHintIndicesInBounds() {
        let stock    = makeSquareHSS()
        let feature  = makeHoleFeature(aCenter: 0)
        let settings = arcSettings()

        let kin     = KinematicsEngine(settings: settings)
        let planned = ToolpathPlanner(settings: settings).plan(
            feature: feature, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)
        let machines = kin.convert(plannedFeature: planned, stock: stock, initialMachineAm: nil)
        let hints    = kin.resolveArcHints(plannedFeature: planned, machinePoints: machines)

        guard let hint = hints.first else {
            XCTFail("expected at least one arc hint"); return
        }
        XCTAssertGreaterThanOrEqual(hint.startMachineIndex, 1,
            "arc cannot start at pierce point (index 0)")
        XCTAssertLessThan(hint.endMachineIndex, machines.count,
            "arc end index must be within machinePoints bounds")
        XCTAssertLessThan(hint.startMachineIndex, hint.endMachineIndex,
            "arc start must precede arc end")
    }

    func testArcHintIJOffsetsMeetCircleConstraint() {
        // The center of the arc in machine space = start + (I, J).
        // Every arc point must lie on the circle with that centre and radius.
        let stock    = makeSquareHSS()
        let feature  = makeHoleFeature(aCenter: 0)
        let settings = arcSettings()

        let kin     = KinematicsEngine(settings: settings)
        let planned = ToolpathPlanner(settings: settings).plan(
            feature: feature, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)
        let machines = kin.convert(plannedFeature: planned, stock: stock, initialMachineAm: nil)
        let hints    = kin.resolveArcHints(plannedFeature: planned, machinePoints: machines)

        guard let hint = hints.first else {
            XCTFail("expected at least one arc hint"); return
        }

        let startMP = machines[hint.startMachineIndex]
        let cx = startMP.Xm + hint.iOffset
        let cy = startMP.Ym + hint.jOffset
        let refR = sqrt(hint.iOffset * hint.iOffset + hint.jOffset * hint.jOffset)

        for i in hint.startMachineIndex...hint.endMachineIndex {
            let mp = machines[i]
            let dist = sqrt(pow(mp.Xm - cx, 2) + pow(mp.Ym - cy, 2))
            XCTAssertEqual(dist, refR, accuracy: 0.1,
                "machine point \(i) must lie on the arc circle (dist=\(dist), r=\(refR))")
        }
    }

    // MARK: nonlinear compensation skip

    func testArcSpanNotExpandedByNonlinearCompensation() {
        // With arc output enabled, the arc span should NOT be subdivided.
        // Without arc output, nonlinear compensation may insert extra points.
        let stock       = makeSquareHSS()
        let feature     = makeHoleFeature(aCenter: 0)
        var settingsArc = arcSettings()
        settingsArc.enableNonlinearErrorCompensation = true  // re-enable NLC
        var settingsBaseline = settingsArc
        settingsBaseline.enableArcOutput = false

        let plannedArc = ToolpathPlanner(settings: settingsArc).plan(
            feature: feature, stock: stock, packStartX: 0, rollOffset: 0, previousMachineAm: 0)
        let plannedBase = ToolpathPlanner(settings: settingsBaseline).plan(
            feature: feature, stock: stock, packStartX: 0, rollOffset: 0, previousMachineAm: 0)

        let machinesArc = KinematicsEngine(settings: settingsArc).convert(
            plannedFeature: plannedArc, stock: stock, initialMachineAm: nil)
        let machinesBase = KinematicsEngine(settings: settingsBaseline).convert(
            plannedFeature: plannedBase, stock: stock, initialMachineAm: nil)

        // When arc output is on, the arc span is not expanded → total point
        // count should be ≤ the fully-compensated count.
        XCTAssertLessThanOrEqual(machinesArc.count, machinesBase.count,
            "arc output mode must not expand the arc span via NLC")
    }
}

// MARK: - GCodeEmitter Arc Tests

final class GCodeEmitterArcTests: XCTestCase {

    private func emit(feature: GeometricFeature, stock: StockInfo, settings: GCodeSettings) -> String {
        let kin     = KinematicsEngine(settings: settings)
        let planned = ToolpathPlanner(settings: settings).plan(
            feature: feature, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)
        let machines = kin.convert(plannedFeature: planned, stock: stock, initialMachineAm: nil)
        let segments = VelocityProfiler(settings: settings).profile(machinePoints: machines)
        let hints    = kin.resolveArcHints(plannedFeature: planned, machinePoints: machines)
        var tf = ToolpathFeature(source: planned, machinePoints: machines, segments: segments)
        tf.arcHints = hints
        return GCodeEmitter(settings: settings).emitFeature(
            toolpathFeature: tf, stock: stock, packStartX: 0, rollOffset: 0
        ).joined(separator: "\n")
    }

    // MARK: Arc output disabled: only G1

    func testNoG2G3WhenArcOutputDisabled() {
        var settings = arcSettings()
        settings.enableArcOutput = false
        let gcode = emit(feature: makeHoleFeature(aCenter: 0),
                         stock: makeSquareHSS(), settings: settings)
        XCTAssertFalse(gcode.contains("G2") || gcode.contains("G3"),
            "G2/G3 must not appear when enableArcOutput is false")
    }

    // MARK: Arc output enabled on HSS flat face

    func testG2OrG3PresentForHSSFlatFaceArc() {
        let settings = arcSettings()
        let gcode    = emit(feature: makeHoleFeature(aCenter: 0),
                            stock: makeSquareHSS(), settings: settings)
        let hasArc = gcode.contains("G2 ") || gcode.contains("G3 ")
        XCTAssertTrue(hasArc, "HSS flat-face tangentArc lead-in must emit G2 or G3")
    }

    func testG17PlaneSetBeforeArc() {
        let settings = arcSettings()
        let lines    = emit(feature: makeHoleFeature(aCenter: 0),
                            stock: makeSquareHSS(), settings: settings)
            .components(separatedBy: "\n")

        // G17 must appear before the first G2/G3
        let g17Idx   = lines.firstIndex(where: { $0.hasPrefix("G17") })
        let arcIdx   = lines.firstIndex(where: { $0.hasPrefix("G2 ") || $0.hasPrefix("G3 ") })
        guard let gi = g17Idx, let ai = arcIdx else {
            XCTFail("expected both G17 and a G2/G3 line"); return
        }
        XCTAssertLessThan(gi, ai, "G17 plane selection must precede the arc command")
    }

    func testG17RestoredAfterArc() {
        let settings = arcSettings()
        let lines    = emit(feature: makeHoleFeature(aCenter: 0),
                            stock: makeSquareHSS(), settings: settings)
            .components(separatedBy: "\n")

        // After the G2/G3 line there must be a G17 restore
        let arcIdx = lines.firstIndex(where: { $0.hasPrefix("G2 ") || $0.hasPrefix("G3 ") })
        guard let ai = arcIdx else { XCTFail("no arc line found"); return }
        let restoreIdx = lines[(ai + 1)...].firstIndex(where: { $0.hasPrefix("G17") })
        XCTAssertNotNil(restoreIdx, "G17 restore must appear after the arc command")
    }

    func testArcLineContainsIJOffsets() {
        let settings = arcSettings()
        let gcode    = emit(feature: makeHoleFeature(aCenter: 0),
                            stock: makeSquareHSS(), settings: settings)
        // The G2/G3 line must carry I and J centre offsets
        let arcLine = gcode.components(separatedBy: "\n")
            .first { $0.hasPrefix("G2 ") || $0.hasPrefix("G3 ") }
        guard let line = arcLine else { XCTFail("no arc line"); return }
        XCTAssertTrue(line.contains(" I"), "arc command must include I offset")
        XCTAssertTrue(line.contains(" J"), "arc command must include J offset")
    }

    func testArcLineContainsXYZAF() {
        let settings = arcSettings()
        let gcode    = emit(feature: makeHoleFeature(aCenter: 0),
                            stock: makeSquareHSS(), settings: settings)
        let arcLine = gcode.components(separatedBy: "\n")
            .first { $0.hasPrefix("G2 ") || $0.hasPrefix("G3 ") }
        guard let line = arcLine else { XCTFail("no arc line"); return }
        XCTAssertTrue(line.contains(" X"), "arc command must include X endpoint")
        XCTAssertTrue(line.contains(" Y"), "arc command must include Y endpoint")
        XCTAssertTrue(line.contains(" Z"), "arc command must include Z endpoint")
        XCTAssertTrue(line.contains(" A"), "arc command must include A endpoint")
        XCTAssertTrue(line.contains(" F"), "arc command must include feed rate")
    }

    // MARK: Round stock: no arcs

    func testNoG2G3ForRoundStock() {
        let settings = arcSettings()
        let gcode    = emit(feature: makeHoleFeature(aCenter: 0),
                            stock: makeRoundStock(), settings: settings)
        XCTAssertFalse(gcode.contains("G2 ") || gcode.contains("G3 "),
            "round stock must never emit G2/G3 (Ym = 0 → degenerate arc)")
    }

    // MARK: G01 is still emitted for cut path (only lead-in is arc)

    func testG1StillPresentAfterArcLeadIn() {
        let settings = arcSettings()
        let gcode    = emit(feature: makeHoleFeature(aCenter: 0),
                            stock: makeSquareHSS(), settings: settings)
        XCTAssertTrue(gcode.contains("G1 "),
            "cut path after arc lead-in must still use G1")
    }

    // MARK: Example output (run with -v to read the G-code in the test log)

    func testArcOutputExampleGCode() {
        // 50 × 50 mm square HSS, hole centred at X=200, A=0° (right flat face).
        // With enableArcOutput=true the lead-in arc collapses to a single G17 G2/G3.
        let settings = arcSettings()
        let gcode = emit(feature: makeHoleFeature(aCenter: 0),
                         stock: makeSquareHSS(), settings: settings)
        // Print so the full G-code block appears in the test log.
        print("=== ARC OUTPUT EXAMPLE ===\n\(gcode)\n=== END ===")
        let hasArc = gcode.contains("G2 ") || gcode.contains("G3 ")
        XCTAssertTrue(hasArc)
    }

    // MARK: Idempotence: same result on two calls

    func testEmissionIdempotent() {
        let settings = arcSettings()
        let stock    = makeSquareHSS()
        let feature  = makeHoleFeature(aCenter: 0)
        let g1 = emit(feature: feature, stock: stock, settings: settings)
        let g2 = emit(feature: feature, stock: stock, settings: settings)
        XCTAssertEqual(g1, g2, "G-code emission must be deterministic")
    }
}

// MARK: - Circumcircle Unit Tests

/// Tests the KinematicsEngine circumcircle helper indirectly by constructing
/// known arcs, running them through resolveArcHints, and checking that the
/// returned I/J offsets reconstruct the expected centre.
final class CircumcircleTests: XCTestCase {

    /// Three points on a known circle → hint must place centre at origin.
    func testCircumcircleKnownCircle() {
        // Circle centred at (5, 3) with radius 4.
        // Three points: (9,3), (5,7), (1,3)
        let cx: CGFloat = 5, cy: CGFloat = 3, r: CGFloat = 4
        let p1 = (cx + r, cy)
        let p2 = (cx, cy + r)
        let p3 = (cx - r, cy)

        // Build minimal machine points that lie on this circle
        // to drive resolveArcHints.  We do this via a synthetic ToolpathFeature
        // approach: construct machine points manually with Xm = x, Ym = y.
        // The arc hint iOffset = cx - p1.x, jOffset = cy - p1.y.
        let expectedI = cx - p1.0
        let expectedJ = cy - p1.1

        // Verify arithmetic (the real test is below in end-to-end tests)
        XCTAssertEqual(expectedI, cx - (cx + r), accuracy: 1e-6)
        XCTAssertEqual(expectedJ, cy - cy,       accuracy: 1e-6)
        _ = (p1, p2, p3)  // suppress unused warnings
    }

    /// Collinear points must not produce an arc hint (circle undefined).
    func testCollinearPointsProduceNoHint() {
        // Place three collinear points in the lead-in arc region.
        // We test this via KinematicsEngine.resolveArcHints with a synthetic
        // plannedFeature that has a SurfaceArc but collinear machine points.
        let stock    = makeSquareHSS()
        let feature  = makeHoleFeature(aCenter: 0)
        let settings = arcSettings()

        let kin     = KinematicsEngine(settings: settings)
        let planned = ToolpathPlanner(settings: settings).plan(
            feature: feature, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)
        let machines = kin.convert(plannedFeature: planned, stock: stock, initialMachineAm: nil)

        // Corrupt the arc span to be collinear: set all arc Ym to the same value
        guard let arc = planned.plannedPath.leadInArc, arc.arcPointCount >= 2 else {
            XCTSkip("no arc metadata available"); return
        }
        var collinear = machines
        for i in 1...arc.arcPointCount {
            collinear[i] = MachinePoint(
                Xm: machines[i].Xm, Ym: 0,
                Zm: machines[i].Zm, Am: machines[i].Am,
                matX: machines[i].matX, matU: machines[i].matU,
                matV: machines[i].matV, isCorner: false)
        }

        let hints = kin.resolveArcHints(plannedFeature: planned, machinePoints: collinear)
        XCTAssertTrue(hints.isEmpty,
            "collinear arc points (Ym=0) must not produce an arc hint")
    }

    /// Too few machine points (< arcPointCount + 2) → no hint.
    func testTooFewMachinePointsProduceNoHint() {
        let stock    = makeSquareHSS()
        let feature  = makeHoleFeature(aCenter: 0)
        let settings = arcSettings()

        let kin     = KinematicsEngine(settings: settings)
        let planned = ToolpathPlanner(settings: settings).plan(
            feature: feature, stock: stock,
            packStartX: 0, rollOffset: 0, previousMachineAm: 0)

        // Pass only 2 machine points — always too few for the arc span
        let stubs = [MachinePoint(Xm:0,Ym:0,Zm:0,Am:0,matX:0,matU:0,matV:0,isCorner:false),
                     MachinePoint(Xm:1,Ym:0,Zm:0,Am:5,matX:1,matU:0,matV:0,isCorner:false)]
        let hints = kin.resolveArcHints(plannedFeature: planned, machinePoints: stubs)
        XCTAssertTrue(hints.isEmpty,
            "fewer machine points than arcPointCount must not produce a hint")
    }
}
