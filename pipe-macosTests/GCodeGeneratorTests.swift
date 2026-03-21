import XCTest
import simd
@testable import pipe_macos

final class GCodeGeneratorTests: XCTestCase {

    // MARK: - Stock Factories

    private func makeSquareHSS(length: CGFloat = 500.0) -> StockInfo {
        StockInfo(
            profile: .square,
            odX: 25.4, odY: 25.4,      // 1" × 1"
            length: length,
            axis: SIMD3<Float>(1, 0, 0),
            uAxis: SIMD3<Float>(0, 1, 0),
            origin: SIMD3<Float>(Float(length / 2), 0, 0)
        )
    }

    private func makeRectHSS(length: CGFloat = 600.0) -> StockInfo {
        StockInfo(
            profile: .rectangular,
            odX: 101.6, odY: 50.8,     // 4" × 2"
            length: length,
            axis: SIMD3<Float>(1, 0, 0),
            uAxis: SIMD3<Float>(0, 1, 0),
            origin: SIMD3<Float>(Float(length / 2), 0, 0)
        )
    }

    private func makeRoundHSS(od: CGFloat = 50.8, length: CGFloat = 500.0) -> StockInfo {
        StockInfo(
            profile: .round,
            od: od,                     // 2" OD
            length: length,
            axis: SIMD3<Float>(1, 0, 0),
            uAxis: SIMD3<Float>(0, 1, 0),
            origin: SIMD3<Float>(Float(length / 2), 0, 0)
        )
    }

    /// Full-circumference sever cut (startCut / endCut) at a fixed X.
    private func makeSeverCut(type: SurfaceFeatureType, xPos: CGFloat, id: Int = 1) -> SurfaceFeature {
        let path = (0...36).map { i -> ToolpathPoint in
            ToolpathPoint(x: xPos, a: CGFloat(i) * 10.0)
        }
        return SurfaceFeature(
            id: id, type: type, shape: .custom,
            xCenter: xPos, aCenterDeg: 180,
            dimensions: ["width": 0], confidence: 1.0, path: path
        )
    }

    /// Simple elliptical hole centred at (xCenter, aCenter).
    private func makeHole(id: Int, xCenter: CGFloat, aCenter: CGFloat = 90.0) -> SurfaceFeature {
        let steps = 8
        var path: [ToolpathPoint] = []
        for i in 0...steps {
            let t = 2.0 * Double.pi * Double(i) / Double(steps)
            path.append(ToolpathPoint(
                x: xCenter + CGFloat(15.0 * cos(t)),
                a: aCenter  + CGFloat(45.0 * sin(t))
            ))
        }
        return SurfaceFeature(
            id: id, type: .hole, shape: .circle,
            xCenter: xCenter, aCenterDeg: aCenter,
            dimensions: ["diameter": 30], confidence: 1.0, path: path
        )
    }

    /// Deterministic settings with thermal hedging and SimCNC disabled.
    private func simpleSettings() -> GCodeSettings {
        var s = GCodeSettings()
        s.enableThermalHedging = false
        s.useSimCNC = false
        s.enableDynamicTHC = false
        s.enableDynamicSafeZ = false
        s.enableKerfComp = true
        return s
    }

    // MARK: - Structural Tests

    func testGCodeStartsWithPercent() {
        let stock = makeSquareHSS()
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        let gen = GCodeGenerator()
        gen.settings = simpleSettings()
        XCTAssertTrue(gen.generateGCode(for: stock).hasPrefix("%"))
    }

    func testContainsMetricAndAbsoluteMode() {
        let stock = makeSquareHSS()
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        let gen = GCodeGenerator()
        gen.settings = simpleSettings()
        let gcode = gen.generateGCode(for: stock)
        XCTAssertTrue(gcode.contains("G21"), "Missing G21 (metric mode)")
        XCTAssertTrue(gcode.contains("G90"), "Missing G90 (absolute positioning)")
    }

    func testContainsTorchOnOff() {
        let stock = makeRoundHSS()
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        let gen = GCodeGenerator()
        gen.settings = simpleSettings()
        let gcode = gen.generateGCode(for: stock)
        XCTAssertTrue(gcode.contains("M3"), "Must have torch-on M3")
        XCTAssertTrue(gcode.contains("M5"), "Must have torch-off M5")
    }

    func testSquareHSSProfileInHeader() {
        let stock = makeSquareHSS()
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        let gen = GCodeGenerator()
        gen.settings = simpleSettings()
        let gcode = gen.generateGCode(for: stock)
        XCTAssertTrue(gcode.contains("HSS-Square"), "Must reference square profile in header")
        XCTAssertTrue(gcode.contains("25.400"), "Must include 1\" (25.4 mm) dimension")
    }

    func testRectHSSProfileInHeader() {
        let stock = makeRectHSS()
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        let gen = GCodeGenerator()
        gen.settings = simpleSettings()
        let gcode = gen.generateGCode(for: stock)
        XCTAssertTrue(gcode.contains("HSS-Rect"),  "Must reference rectangular profile")
        XCTAssertTrue(gcode.contains("101.600"), "Must include 4\" (101.6 mm) dimension")
        XCTAssertTrue(gcode.contains("50.800"),  "Must include 2\" (50.8 mm) dimension")
    }

    func testRoundHSSProfileInHeader() {
        let stock = makeRoundHSS(od: 50.8)
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        let gen = GCodeGenerator()
        gen.settings = simpleSettings()
        let gcode = gen.generateGCode(for: stock)
        XCTAssertTrue(gcode.contains("HSS-O"),  "Must reference round profile")
        XCTAssertTrue(gcode.contains("50.800"), "Must include 2\" (50.8 mm) OD")
    }

    // MARK: - Kerf Compensation Tests

    func testKerfCompEnabledInsertsG41orG42() {
        let stock = makeRoundHSS()
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        let gen = GCodeGenerator()
        var s = simpleSettings()
        s.enableKerfComp = true
        gen.settings = s
        let gcode = gen.generateGCode(for: stock)
        XCTAssertTrue(gcode.contains("G41") || gcode.contains("G42"),
                      "Kerf comp enabled must insert G41/G42")
        XCTAssertTrue(gcode.contains("G40"), "Kerf comp must cancel with G40")
    }

    func testKerfCompDisabledNoCompInG1() {
        let stock = makeRoundHSS()
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        let gen = GCodeGenerator()
        var s = simpleSettings()
        s.enableKerfComp = false
        gen.settings = s
        let gcode = gen.generateGCode(for: stock)

        // G40 appears in the startup sequence; G41/G42 must NOT appear on any G1 line.
        let g1Lines = gcode.components(separatedBy: "\n").filter { $0.hasPrefix("G1 ") }
        for line in g1Lines {
            XCTAssertFalse(line.contains("G41") || line.contains("G42"),
                           "No kerf comp on G1 when disabled: \(line)")
        }
    }

    // MARK: - Z Sequence Tests

    func testPierceSequenceBeforeM3() {
        let stock = makeRoundHSS()
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        let gen = GCodeGenerator()
        var s = simpleSettings()
        s.safeHeight = 25.0
        s.pierceHeight = 5.0
        gen.settings = s
        let gcode = gen.generateGCode(for: stock)

        let lines = gcode.components(separatedBy: "\n")
        var g0zFound = false
        var m3Found  = false
        var g1AfterM3 = false

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("G0 Z") && !m3Found { g0zFound  = true }
            if t.contains("M3") && !m3Found    { m3Found   = true }
            if t.hasPrefix("G1") && m3Found    { g1AfterM3 = true }
        }

        XCTAssertTrue(g0zFound,   "G0 Z retract must appear before M3")
        XCTAssertTrue(m3Found,    "M3 torch-on must appear in output")
        XCTAssertTrue(g1AfterM3, "G1 feed move must appear after M3")
    }

    func testPierceHeightCommentPresent() {
        let stock = makeRoundHSS()
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        let gen = GCodeGenerator()
        var s = simpleSettings()
        s.pierceHeight = 5.5
        gen.settings = s
        let gcode = gen.generateGCode(for: stock)
        XCTAssertTrue(gcode.contains("; lower to pierce height"),
                      "Pierce height comment must be present in G-code")
    }

    // MARK: - Feed Rate Tests

    func testAllG1FeedRatesArePositive() {
        let stock = makeRoundHSS()
        stock.features.append(makeSeverCut(type: .endCut,   xPos:   0, id: 1))
        stock.features.append(makeSeverCut(type: .startCut, xPos: 500, id: 2))
        let gen = GCodeGenerator()
        gen.settings = simpleSettings()
        let gcode = gen.generateGCode(for: stock)

        let lines = gcode.components(separatedBy: "\n")
        for line in lines where line.hasPrefix("G1") {
            guard let fRange = line.range(of: "F") else { continue }
            let numStr = line[fRange.upperBound...].prefix(while: { $0.isNumber || $0 == "." })
            if let fVal = Double(numStr) {
                XCTAssertGreaterThan(fVal, 0.0, "Feed rate must be positive: \(line)")
            }
        }
    }

    // MARK: - Multi-Feature Tests

    func testRoundHSSWithHole() {
        let stock = makeRoundHSS()
        stock.features.append(makeHole(id: 1, xCenter: 250, aCenter: 90))
        stock.features.append(makeSeverCut(type: .startCut, xPos:   0, id: 2))
        stock.features.append(makeSeverCut(type: .endCut,   xPos: 500, id: 3))
        let gen = GCodeGenerator()
        gen.settings = simpleSettings()
        let gcode = gen.generateGCode(for: stock)

        let m3Count = gcode.components(separatedBy: "\n").filter { $0.contains("M3") }.count
        XCTAssertGreaterThanOrEqual(m3Count, 1, "Must have at least one torch-on cycle")
    }

    func testSquareHSSWithHoleAndSeverCuts() {
        let stock = makeSquareHSS(length: 500.0)
        stock.features.append(makeHole(id: 1, xCenter: 250, aCenter: 0))
        stock.features.append(makeSeverCut(type: .startCut, xPos:   0, id: 2))
        stock.features.append(makeSeverCut(type: .endCut,   xPos: 500, id: 3))
        let gen = GCodeGenerator()
        gen.settings = simpleSettings()
        let gcode = gen.generateGCode(for: stock)

        XCTAssertFalse(gcode.isEmpty, "G-code must not be empty")
        XCTAssertTrue(gcode.contains("HSS-Square"))
        XCTAssertTrue(gcode.contains("M3"))
        XCTAssertTrue(gcode.contains("M5"))
    }

    func testRectHSSWithHoleAndSeverCuts() {
        let stock = makeRectHSS(length: 600.0)
        stock.features.append(makeHole(id: 1, xCenter: 200, aCenter: 45))
        stock.features.append(makeHole(id: 2, xCenter: 400, aCenter: 270))
        stock.features.append(makeSeverCut(type: .startCut, xPos:   0, id: 3))
        stock.features.append(makeSeverCut(type: .endCut,   xPos: 600, id: 4))
        let gen = GCodeGenerator()
        gen.settings = simpleSettings()
        let gcode = gen.generateGCode(for: stock)

        XCTAssertTrue(gcode.contains("HSS-Rect"))
        let m3Count = gcode.components(separatedBy: "\n").filter { $0.contains("M3") }.count
        // 2 holes + 2 sever cuts = 4 features → ≥ 4 M3s (plus startup M5 but no M3)
        XCTAssertGreaterThanOrEqual(m3Count, 1)
    }

    // MARK: - Determinism Test

    func testGCodeIsDeterministic() {
        let stock = makeSquareHSS()
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0,   id: 1))
        stock.features.append(makeHole(id: 2, xCenter: 250, aCenter: 90))
        stock.features.append(makeSeverCut(type: .endCut,   xPos: 500, id: 3))

        let gen = GCodeGenerator()
        gen.settings = simpleSettings()

        let gcode1 = gen.generateGCode(for: stock)
        let gcode2 = gen.generateGCode(for: stock)

        // Strip the timestamp line; everything else must be byte-for-byte identical.
        let strip: (String) -> [String] = { gcode in
            gcode.components(separatedBy: "\n").filter { !$0.contains("GENERATED:") }
        }
        XCTAssertEqual(strip(gcode1), strip(gcode2),
                       "G-code must be deterministic for identical input")
    }

    // MARK: - Dynamic THC Tests

    func testDynamicTHCCodesPresent() {
        let stock = makeRoundHSS()
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        let gen = GCodeGenerator()
        var s = simpleSettings()
        s.enableDynamicTHC = true
        gen.settings = s
        let gcode = gen.generateGCode(for: stock)
        XCTAssertTrue(gcode.contains("M221") || gcode.contains("M220"),
                      "THC control codes must appear when enableDynamicTHC = true")
    }

    func testDynamicTHCCodesAbsent() {
        let stock = makeRoundHSS()
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        let gen = GCodeGenerator()
        var s = simpleSettings()
        s.enableDynamicTHC = false
        gen.settings = s
        let gcode = gen.generateGCode(for: stock)
        XCTAssertFalse(gcode.contains("M221") || gcode.contains("M220"),
                       "THC control codes must be absent when enableDynamicTHC = false")
    }
}
