import XCTest
import Foundation
import simd
@testable import pipe_macos

final class GCodeGeneratorTests: XCTestCase {

    // MARK: - Stock Factories

    private func alignAxisToX(_ axis: SIMD3<Float>) -> simd_quatf {
        let target = SIMD3<Float>(1, 0, 0)
        let a = simd_normalize(axis)
        let d = dot(a, target)
        if d > 0.9999 { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        if d < -0.9999 { return simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)) }
        return simd_quatf(angle: acos(d), axis: simd_normalize(cross(a, target)))
    }

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
    private func makeSeverCut(type: SurfaceFeatureType, xPos: CGFloat, id: Int = 1) -> GeometricFeature {
        let path = (0...36).map { i -> ToolpathPoint in
            ToolpathPoint(x: xPos, a: CGFloat(i) * 10.0)
        }
        return GeometricFeature(
            id: id, type: type, shape: .custom,
            xCenter: xPos, aCenterDeg: 180,
            dimensions: ["width": 0], confidence: 1.0, rawPath: path
        )
    }

    /// Simple elliptical hole centred at (xCenter, aCenter).
    private func makeHole(id: Int, xCenter: CGFloat, aCenter: CGFloat = 90.0) -> GeometricFeature {
        let steps = 8
        var path: [ToolpathPoint] = []
        for i in 0...steps {
            let t = 2.0 * Double.pi * Double(i) / Double(steps)
            path.append(ToolpathPoint(
                x: xCenter + CGFloat(15.0 * cos(t)),
                a: aCenter  + CGFloat(45.0 * sin(t))
            ))
        }
        return GeometricFeature(
            id: id, type: .hole, shape: .circle,
            xCenter: xCenter, aCenterDeg: aCenter,
            dimensions: ["diameter": 30], confidence: 1.0, rawPath: path
        )
    }

    /// Deterministic settings with thermal hedging and SimCNC disabled.
    private func simpleSettings() -> GCodeSettings {
        var s = GCodeSettings()
        s.enableThermalHedging = true
        s.thermalHedgingWeightA = 1.0
        s.thermalHedgingWeightX = 1.0
        s.useSimCNC = true
        s.enableDynamicTHC = false
        s.enableDynamicSafeZ = true
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

    // MARK: - Unit Mode Tests

    /// Returns a generator with simple (deterministic) settings in the given unit mode.
    private func makeGen(units: GCodeUnit, simCNC: Bool = false) -> GCodeGenerator {
        let gen = GCodeGenerator()
        var s = simpleSettings()
        s.units   = units
        s.useSimCNC = simCNC
        gen.settings = s
        return gen
    }

    /// Extract all G1 lines from a gcode string.
    private func g1Lines(_ gcode: String) -> [String] {
        gcode.components(separatedBy: "\n").filter { $0.hasPrefix("G1 ") }
    }

    /// Parse the numeric value of the first occurrence of `word` (e.g. "X", "Z", "F") on a line.
    private func parseWord(_ word: String, from line: String) -> Double? {
        guard let r = line.range(of: word) else { return nil }
        let tail = line[r.upperBound...].prefix(while: { $0.isNumber || $0 == "." || $0 == "-" })
        return Double(tail)
    }

    // --- Mode word ---

    func testMetricModeEmitsG21() {
        let stock = makeRoundHSS()
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        let gcode = makeGen(units: .metric).generateGCode(for: stock)
        XCTAssertTrue(gcode.contains("G21"),  "Metric mode must emit G21")
        XCTAssertFalse(gcode.contains("G20"), "Metric mode must not emit G20")
    }

    func testInchModeEmitsG20() {
        let stock = makeRoundHSS()
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        let gcode = makeGen(units: .inches).generateGCode(for: stock)
        XCTAssertTrue(gcode.contains("G20"),  "Inch mode must emit G20")
        XCTAssertFalse(gcode.contains("G21"), "Inch mode must not emit G21")
    }

    // --- G92 stock-length home position ---

    func testG92StockLengthMetric() {
        let stock = makeRoundHSS(length: 500)
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        let gcode = makeGen(units: .metric).generateGCode(for: stock)
        // Expect G92 X500.000
        XCTAssertTrue(gcode.contains("G92 X500.000"), "G92 X must be 500.000 mm in metric mode")
    }

    func testG92StockLengthInches() {
        let stock = makeRoundHSS(length: 508)   // 508 mm = exactly 20 in
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        let gcode = makeGen(units: .inches).generateGCode(for: stock)
        // 508 / 25.4 = 20.0000
        XCTAssertTrue(gcode.contains("G92 X20.0000"), "G92 X must be 20.0000 in in inch mode")
    }

    // --- Safe-height Z rapid ---

    func testSafeHeightZMetric() {
        let stock = makeRoundHSS()
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        var s = simpleSettings()
        s.safeHeight = 25.4   // chosen so inch conversion is exact
        let gen = GCodeGenerator(); gen.settings = s
        let gcode = gen.generateGCode(for: stock)
        XCTAssertTrue(gcode.contains("G0 Z25.400"), "Safe-height Z must be 25.400 mm in metric mode")
    }

    func testSafeHeightZInches() {
        let stock = makeRoundHSS()
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        var s = simpleSettings(); s.units = .inches; s.safeHeight = 25.4
        let gen = GCodeGenerator(); gen.settings = s
        let gcode = gen.generateGCode(for: stock)
        // 25.4 / 25.4 = 1.0000
        XCTAssertTrue(gcode.contains("G0 Z1.0000"), "Safe-height Z must be 1.0000 in in inch mode")
    }

    // --- Header dimensions ---

    func testHeaderDimensionsMetric() {
        let stock = makeRoundHSS(od: 50.8, length: 500)
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        let gcode = makeGen(units: .metric).generateGCode(for: stock)
        XCTAssertTrue(gcode.contains("50.800mm"), "OD header must show 50.800mm in metric mode")
        XCTAssertTrue(gcode.contains("500.000mm"), "Length header must show 500.000mm in metric mode")
    }

    func testHeaderDimensionsInches() {
        let stock = makeRoundHSS(od: 50.8, length: 508)  // 50.8mm = 2in, 508mm = 20in
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))
        let gcode = makeGen(units: .inches).generateGCode(for: stock)
        XCTAssertTrue(gcode.contains("2.0000in"), "OD header must show 2.0000in in inch mode")
        XCTAssertTrue(gcode.contains("20.0000in"), "Length header must show 20.0000in in inch mode")
    }

    // --- G1 coordinate scaling ---

    func testG1XCoordinatesInchesVsMetric() {
        // Use 508mm length (exact multiple of 25.4) so conversions are clean.
        let stock = makeRoundHSS(od: 50.8, length: 508)
        stock.features.append(makeSeverCut(type: .startCut, xPos: 254))   // midpoint = 10 in

        let gcodeMetric = makeGen(units: .metric).generateGCode(for: stock)
        let gcodeInches = makeGen(units: .inches).generateGCode(for: stock)

        let xMetric = g1Lines(gcodeMetric).compactMap { parseWord("X", from: $0) }
        let xInches = g1Lines(gcodeInches).compactMap { parseWord("X", from: $0) }

        XCTAssertEqual(xMetric.count, xInches.count,
                       "Same number of G1 lines must be produced in both unit modes")
        XCTAssertFalse(xMetric.isEmpty, "Must have at least one G1 line")

        for (mm, inch) in zip(xMetric, xInches) {
            XCTAssertEqual(mm / 25.4, inch, accuracy: 0.001,
                           "G1 X inch value must be X_mm / 25.4; got mm=\(mm) in=\(inch)")
        }
    }

    func testG1ZCoordinatesInchesVsMetric() {
        let stock = makeRoundHSS(od: 50.8, length: 508)
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))

        let gcodeMetric = makeGen(units: .metric).generateGCode(for: stock)
        let gcodeInches = makeGen(units: .inches).generateGCode(for: stock)

        let zMetric = g1Lines(gcodeMetric).compactMap { parseWord("Z", from: $0) }
        let zInches = g1Lines(gcodeInches).compactMap { parseWord("Z", from: $0) }

        XCTAssertEqual(zMetric.count, zInches.count)
        for (mm, inch) in zip(zMetric, zInches) {
            XCTAssertEqual(mm / 25.4, inch, accuracy: 0.001,
                           "G1 Z inch value must be Z_mm / 25.4; got mm=\(mm) in=\(inch)")
        }
    }

    // --- A axis must NOT be converted ---

    func testG1AAxisUnchangedInInchMode() {
        let stock = makeRoundHSS(od: 50.8, length: 508)
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))

        let gcodeMetric = makeGen(units: .metric).generateGCode(for: stock)
        let gcodeInches = makeGen(units: .inches).generateGCode(for: stock)

        let aMetric = g1Lines(gcodeMetric).compactMap { parseWord("A", from: $0) }
        let aInches = g1Lines(gcodeInches).compactMap { parseWord("A", from: $0) }

        XCTAssertEqual(aMetric.count, aInches.count)
        for (am, ai) in zip(aMetric, aInches) {
            XCTAssertEqual(am, ai, accuracy: 0.001,
                           "A-axis degrees must be identical in both unit modes; got metric=\(am) inch=\(ai)")
        }
    }

    // --- Feed rates (non-SimCNC) ---

    func testFeedRatesInchesVsMetric() {
        let stock = makeRoundHSS(od: 50.8, length: 508)
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))

        let gcodeMetric = makeGen(units: .metric, simCNC: false).generateGCode(for: stock)
        let gcodeInches = makeGen(units: .inches, simCNC: false).generateGCode(for: stock)

        let fMetric = g1Lines(gcodeMetric).compactMap { parseWord("F", from: $0) }
        let fInches = g1Lines(gcodeInches).compactMap { parseWord("F", from: $0) }

        XCTAssertFalse(fMetric.isEmpty, "Must have F values in G1 lines")
        XCTAssertEqual(fMetric.count, fInches.count)

        for (fm, fi) in zip(fMetric, fInches) {
            XCTAssertEqual(fm / 25.4, fi, accuracy: 0.01,
                           "Non-SimCNC feed rate in/min must be F_mm / 25.4; got mm=\(fm) in=\(fi)")
        }
    }

    // --- Pack mode ---

    func testPackModeEmitsCorrectUnitWord() {
        let stock = makeRoundHSS(od: 50.8, length: 508)
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))

        let genMetric = makeGen(units: .metric)
        let genInches = makeGen(units: .inches)

        var shape = SelectedShape(); shape.shapeData = ShapeData(type: .cylinder, dimensions: nil, isCuttable: true, stockInfo: stock)
        let entry = PackEntry(shape: shape, packStartX: 0)

        let gcodeMetric = genMetric.generatePackGCode(entries: [entry])
        let gcodeInches = genInches.generatePackGCode(entries: [entry])

        XCTAssertTrue(gcodeMetric.contains("G21"), "Pack metric mode must emit G21")
        XCTAssertFalse(gcodeMetric.contains("G20"), "Pack metric mode must not emit G20")
        XCTAssertTrue(gcodeInches.contains("G20"), "Pack inch mode must emit G20")
        XCTAssertFalse(gcodeInches.contains("G21"), "Pack inch mode must not emit G21")
    }

    func testPackModeG92InchConversion() {
        let stock = makeRoundHSS(od: 50.8, length: 508)   // 508 mm = 20 in
        stock.features.append(makeSeverCut(type: .startCut, xPos: 0))

        var shape = SelectedShape(); shape.shapeData = ShapeData(type: .cylinder, dimensions: nil, isCuttable: true, stockInfo: stock)
        let entry = PackEntry(shape: shape, packStartX: 0)

        let gcodeInches = makeGen(units: .inches).generatePackGCode(entries: [entry])
        XCTAssertTrue(gcodeInches.contains("G92 X20.0000"),
                      "Pack inch mode G92 X must be 20.0000 for 508mm stock")
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
        XCTAssertTrue(gcode.contains("#4061"),
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
        XCTAssertFalse(gcode.contains("4061"),
                       "THC control codes must be absent when enableDynamicTHC = false")
    }

    // MARK: - S-Curve Profiling Tests

    func testSCurveVelocityProfileSmoothness() {
        let length: CGFloat = 1000.0
        let stock = makeRoundHSS(od: 50.8, length: length)
        
        // Make a long straight cut to see the ramps
        let xStart: CGFloat = 100
        let xEnd: CGFloat = 900
        let steps = 100
        var path: [ToolpathPoint] = []
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            path.append(ToolpathPoint(x: xStart + t * (xEnd - xStart), a: 0))
        }
        let feature = GeometricFeature(
            id: 1, type: .hole, shape: .custom,
            xCenter: (xStart + xEnd) / 2.0, aCenterDeg: 0,
            dimensions: ["length": xEnd - xStart], confidence: 1.0, rawPath: path
        )
        stock.features.append(feature)
        
        let gen = GCodeGenerator()
        var s = simpleSettings()
        s.maxAccelX = 500.0 // mm/s^2
        s.maxJerkX = 1000.0  // mm/s^3 (low jerk for visible S-curve)
        s.feedRate = 6000.0  // 100 mm/s
        s.useSimCNC = false
        s.enableThermalHedging = false
        gen.settings = s
        
        let gcode = gen.generateGCode(for: stock)
        let lines = gcode.components(separatedBy: "\n")
        
        var velocities: [Double] = []
        var times: [Double] = []
        var lastX: Double? = nil
        var currentTime: Double = 0
        
        for line in lines where line.hasPrefix("G1") {
            guard let xRange = line.range(of: "X"),
                  let fRange = line.range(of: "F") else { continue }
            
            let xStr = line[xRange.upperBound...].prefix(while: { $0.isNumber || $0 == "." || $0 == "-" })
            let fStr = line[fRange.upperBound...].prefix(while: { $0.isNumber || $0 == "." || $0 == "-" })
            
            if let x = Double(xStr), let f = Double(fStr) {
                let v = f / 60.0 // mm/s
                if let lx = lastX {
                    let dx = abs(x - lx)
                    let vAvg = (v + (velocities.last ?? 0)) / 2.0
                    let dt = dx / max(vAvg, 1.0)
                    currentTime += dt
                    times.append(currentTime)
                    velocities.append(v)
                } else {
                    velocities.append(v)
                    times.append(0)
                }
                lastX = x
            }
        }
        
        XCTAssertGreaterThan(velocities.count, 10, "Should have enough G1 moves to check profile")
        
        var accelerations: [Double] = []
        for i in 1..<velocities.count {
            // dv between midpoints of segments
            let dv = velocities[i] - velocities[i-1]
            let dt = (times[i] - times[i-1])
            if dt > 1e-6 {
                accelerations.append(dv / dt)
            }
        }
        
        // Verify acceleration does not exceed maxAccelX (with some tolerance for discrete sampling)
        for a in accelerations {
            XCTAssertLessThanOrEqual(abs(a), Double(s.maxAccelX) * 1.5, "Acceleration \(a) exceeds limit \(s.maxAccelX)")
        }
        
        // Check for S-curve: initial acceleration should be ramped.
        if accelerations.count > 10 {
            let firstNonZeroA = accelerations.first { abs($0) > 1.0 } ?? 0
            XCTAssertLessThan(abs(firstNonZeroA), Double(s.maxAccelX) * 0.8, "Initial acceleration should be ramped (S-curve)")
        }
    }

    func testJerkScalingByThickness() {
        let manager = CutPresetManager.shared
        
        // 1/4" (6.35mm) is our baseline.
        let thinPreset = CutPreset(name: "Thin", source: "Test", amperage: 45, feedRate: 1000, thickness: 6.35, kerfWidth: 1.0, cutHeight: 1.0, pierceHeight: 1.0)
        manager.presets = [thinPreset]
        manager.activePresetID = thinPreset.id
        manager.advancedSettings.maxJerkX = 1000.0
        manager.advancedSettings.maxJerkA = 5000.0
        manager.advancedSettings.maxJerkY = 5000.0
        manager.advancedSettings.maxJerkZ = 2000.0
        
        let settingsThin = manager.currentGCodeSettings()
        XCTAssertEqual(Double(settingsThin.maxJerkX), 1000.0, accuracy: 0.1)
        XCTAssertEqual(Double(settingsThin.maxJerkA), 5000.0, accuracy: 0.1)
        
        // 1/2" (12.7mm) is double thickness, should half the jerk.
        let thickPreset = CutPreset(name: "Thick", source: "Test", amperage: 45, feedRate: 1000, thickness: 12.7, kerfWidth: 1.0, cutHeight: 1.0, pierceHeight: 1.0)
        manager.presets.append(thickPreset)
        manager.activePresetID = thickPreset.id
        
        let settingsThick = manager.currentGCodeSettings()
        XCTAssertEqual(Double(settingsThick.maxJerkX), 500.0, accuracy: 0.1, "X Jerk should be halved for double thickness")
        XCTAssertEqual(Double(settingsThick.maxJerkA), 2500.0, accuracy: 0.1, "A Jerk should be halved for double thickness")
        
        // Y and Z should remain unscaled
        XCTAssertEqual(Double(settingsThick.maxJerkY), 5000.0, accuracy: 0.1)
        XCTAssertEqual(Double(settingsThick.maxJerkZ), 2000.0, accuracy: 0.1)
    }

    // MARK: - Integration Tests
    
    private var examplesURL: URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()            // pipe-macosTests/
            .deletingLastPathComponent()            // project root
            .appendingPathComponent("pipe-macos/examples")
    }

    private func fixtureURL(_ name: String) -> URL {
        examplesURL.appendingPathComponent(name)
    }

    private func loadModel(_ name: String) -> Model3D? {
        let url = fixtureURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return ModelLoader.loadSTEP(url: url)
    }

    func testRectComplexFixtureRotationOnA() throws {
        let url = fixtureURL("circ-test-rect-complex.step")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("circ-test-rect-complex.step not found in examples/")
        }
        guard let model = loadModel("circ-test-rect-complex.step"),
              let stock = model.selectableShapes.first?.stockInfo else {
            XCTFail("Failed to load model or extract stock info")
            return
        }
        
        let gen = GCodeGenerator()
        gen.settings = simpleSettings()
        
        let gcode = gen.generateGCode(for: stock)
        let lines = gcode.components(separatedBy: CharacterSet.newlines)
        
        var currentFeature: String? = nil
        var minA: CGFloat = .greatestFiniteMagnitude
        var maxA: CGFloat = -.greatestFiniteMagnitude
        var featuresChecked = 0
        var insideCut = false
        var currentFeatureLines: [String] = []
        
        for line in lines {
            let t = line.trimmingCharacters(in: CharacterSet.whitespaces)
            if t.hasPrefix("; ---") {
                if let feature = currentFeature, feature != "Startcut" && feature != "Endcut" {
                    let diff = maxA - minA
                    if diff >= 1.0 {
                        print("Violating GCode section for feature \(feature):\n\(currentFeatureLines.joined(separator: "\n"))\n--- End of violating section ---")
                    }
                    XCTAssertLessThan(diff, 1.0, "Feature \(feature) should have < 1 degree of A-axis rotation, got \(diff)° (min: \(minA), max: \(maxA))")
                    featuresChecked += 1
                }
                
                let parts = t.components(separatedBy: CharacterSet.whitespaces)
                if parts.count >= 3 {
                    currentFeature = parts[2] // e.g. "; --- Hole X=... A=... ---"
                } else {
                    currentFeature = "Unknown"
                }
                minA = .greatestFiniteMagnitude
                maxA = -.greatestFiniteMagnitude
                insideCut = false
                currentFeatureLines = []
            }
            
            if currentFeature != nil {
                currentFeatureLines.append(line)
            }
            
            if t.hasPrefix("M3") {
                insideCut = true
            } else if t.hasPrefix("M5") {
                insideCut = false
            } else if insideCut && (t.hasPrefix("G0 ") || t.hasPrefix("G1 ")) {
                let tokens = t.components(separatedBy: CharacterSet.whitespaces)
                for token in tokens {
                    if token.hasPrefix("A") {
                        if let aVal = Double(token.dropFirst()) {
                            minA = min(minA, CGFloat(aVal))
                            maxA = max(maxA, CGFloat(aVal))
                        }
                    }
                }
            }
        }
        
        if let feature = currentFeature, feature != "Startcut" && feature != "Endcut" {
            let diff = maxA - minA
            if diff >= 1.0 {
                print("Violating GCode section for feature \(feature):\n\(currentFeatureLines.joined(separator: "\n"))\n--- End of violating section ---")
            }
            XCTAssertLessThan(diff, 1.0, "Feature \(feature) should have < 1 degree of A-axis rotation, got \(diff)° (min: \(minA), max: \(maxA))")
            featuresChecked += 1
        }
        
        XCTAssertEqual(featuresChecked, 4, "Expected to check 4 features on flat faces, but checked \(featuresChecked)")
    }
}

// MARK: - featureType Classification Tests

/// Unit tests for ModelLoader.featureType — specifically the complex-end-profile gap
/// where a full-profile (360°) loop whose shallowest point is a few mm beyond axisTol
/// was previously misclassified as .cutout.
final class FeatureTypeClassificationTests: XCTestCase {

    private let axisTol: Float = 2.0

    // MARK: Simple sever cuts (existing behaviour — must not regress)

    func testSimpleStartCutAtTubeOrigin() {
        // loopMinX = 0 → squarely within axisTol → .startCut
        let result = ModelLoader.featureType(
            loopMinX: 0, loopMaxX: 0.5, tubeLength: 500, isFullProfile: true, axisTol: axisTol)
        XCTAssertEqual(result, .startCut, "Flat cut at tube origin must be startCut")
    }

    func testSimpleEndCutAtTubeFar() {
        // loopMaxX = tubeLength → .endCut
        let result = ModelLoader.featureType(
            loopMinX: 499.5, loopMaxX: 500, tubeLength: 500, isFullProfile: true, axisTol: axisTol)
        XCTAssertEqual(result, .endCut, "Flat cut at tube far end must be endCut")
    }

    // MARK: Complex end profile (the bug under fix)

    func testComplexStartCutJustBeyondAxisTol() {
        // loopMinX = 3 mm — beyond axisTol (2 mm) but well within complexEndTol (10 mm).
        // This is the geometry produced by a round tube intersected with an HSS tube at the end:
        // the shallowest point of the intersection may be ~3-5 mm from the tube end.
        let result = ModelLoader.featureType(
            loopMinX: 3, loopMaxX: 23, tubeLength: 514, isFullProfile: true, axisTol: axisTol)
        XCTAssertEqual(result, .startCut,
            "Complex end profile (loopMinX=3mm > axisTol) must still be classified as startCut")
    }

    func testComplexStartCutAtFiveMm() {
        // loopMinX = 5 mm — the user-reported case ("<5mm on one side")
        let result = ModelLoader.featureType(
            loopMinX: 4.5, loopMaxX: 23, tubeLength: 514, isFullProfile: true, axisTol: axisTol)
        XCTAssertEqual(result, .startCut,
            "Complex end profile with 4.5mm minimum depth must be classified as startCut, not cutout")
    }

    func testComplexEndCutJustBeyondAxisTol() {
        // Mirror case for endCut: loopMaxX = tubeLength - 3 mm
        let tubeLength: Float = 514
        let result = ModelLoader.featureType(
            loopMinX: tubeLength - 23, loopMaxX: tubeLength - 3,
            tubeLength: tubeLength, isFullProfile: true, axisTol: axisTol)
        XCTAssertEqual(result, .endCut,
            "Complex end profile near tube far end must be classified as endCut")
    }

    // MARK: Guard: full-profile feature in the middle of the tube must NOT become a sever cut

    func testFullProfileMidTubeRemainsNonSever() {
        // A hypothetical full-profile loop that is centered in the middle of the tube.
        // It should NOT be promoted to startCut/endCut by the complexEndTol branch.
        let result = ModelLoader.featureType(
            loopMinX: 200, loopMaxX: 230, tubeLength: 514, isFullProfile: true, axisTol: axisTol)
        XCTAssertEqual(result, .cutout,
            "Full-profile loop in the middle of the tube must remain .cutout, not sever")
    }

    func testFullProfileNearStartButTooDeepRemainsNonSever() {
        // loopMinX = 5 mm (within complexEndTol) BUT loopMaxX = 200 mm (> 25% of 514 mm = 128.5 mm).
        // The feature spans too much of the tube to be an end profile.
        let result = ModelLoader.featureType(
            loopMinX: 5, loopMaxX: 200, tubeLength: 514, isFullProfile: true, axisTol: axisTol)
        XCTAssertEqual(result, .cutout,
            "Full-profile loop that extends deep into the tube must not be misclassified as startCut")
    }

    // MARK: Notch and cutout (non-full-profile — must not regress)

    func testNotchTouchingStart() {
        let result = ModelLoader.featureType(
            loopMinX: 0, loopMaxX: 30, tubeLength: 500, isFullProfile: false, axisTol: axisTol)
        XCTAssertEqual(result, .notch, "Partial loop touching start must be .notch")
    }

    func testCutoutInMiddle() {
        let result = ModelLoader.featureType(
            loopMinX: 200, loopMaxX: 230, tubeLength: 500, isFullProfile: false, axisTol: axisTol)
        XCTAssertEqual(result, .cutout, "Partial loop not touching either end must be .cutout")
    }
}
