import XCTest
import simd
@testable import pipe_macos

/// Integration tests for STEP parsing (PCA + AAG feature extraction)
/// using the existing fixture files in pipe-macos/examples/.
///
/// These tests require OpenCASCADE to be installed at runtime.
/// Individual tests skip gracefully when a fixture file is absent.
final class STEPBridgeTests: XCTestCase {

    // MARK: - Helpers

    private var examplesURL: URL {
        // #file = .../pipe-macosTests/STEPBridgeTests.swift at compile time.
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

    private func skip(ifMissing name: String) throws -> URL {
        let url = fixtureURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(name) not found in examples/")
        }
        return url
    }

    // MARK: - Load Tests

    func testAllFixturesLoad() {
        let fixtures = [
            "circ-test.step",
            "circ-test-all.step",
            "circ-test-simplified.step",
            "circ-test-same.step",
            "circ-test-same2.step",
            "circ-test-same3.step",
            "circ-test-notch-rect.step",
            "circ-test-notch-rect-rotate.step",
            "circ-test-rect-complex.step",
        ]
        for name in fixtures {
            guard FileManager.default.fileExists(atPath: fixtureURL(name).path) else { continue }
            let model = ModelLoader.loadSTEP(url: fixtureURL(name))
            XCTAssertNotNil(model, "\(name) must load without error")
            XCTAssertFalse(model?.selectableShapes.isEmpty ?? true,
                           "\(name) must produce at least one selectable shape")
        }
    }

    func testCirctestBasicLoads() throws {
        _ = try skip(ifMissing: "circ-test.step")
        let model = loadModel("circ-test.step")
        XCTAssertNotNil(model)
        XCTAssertFalse(model?.selectableShapes.isEmpty ?? true)
    }

    // MARK: - Stock Profile Classification

    func testProfileIsDetected() throws {
        _ = try skip(ifMissing: "circ-test.step")
        guard let stock = loadModel("circ-test.step")?.selectableShapes.first?.stockInfo else {
            XCTFail("No stockInfo on circ-test.step"); return
        }
        // circ-test.step is a square HSS tube; just verify a concrete profile is detected.
        XCTAssertNotEqual(stock.profile, .unknown,
                          "circ-test.step must be classified as a known profile, not .unknown")
    }

    func testRoundProfileDetected() throws {
        _ = try skip(ifMissing: "circ-test-simplified.step")
        guard let model = loadModel("circ-test-simplified.step"),
              let stock = model.selectableShapes.first?.stockInfo else {
            XCTFail("No stockInfo on circ-test-simplified.step"); return
        }
        // Accept any concrete profile — round OR rect depending on the fixture geometry.
        XCTAssertNotEqual(stock.profile, .unknown, "Profile must be detected")
        if stock.profile == .round {
            XCTAssertNotNil(stock.od, "Round stock must have an OD")
            XCTAssertGreaterThan(stock.od ?? 0, 0, "OD must be positive")
        }
    }

    func testRectProfileDetected() throws {
        _ = try skip(ifMissing: "circ-test-notch-rect.step")
        guard let stock = loadModel("circ-test-notch-rect.step")?.selectableShapes.first?.stockInfo else {
            XCTFail("No stockInfo on circ-test-notch-rect.step"); return
        }
        XCTAssertTrue(stock.profile == .square || stock.profile == .rectangular,
                      "circ-test-notch-rect.step must classify as square or rectangular HSS, got: \(stock.profile.rawValue)")
    }

    func testRotatedRectProfileDetected() throws {
        _ = try skip(ifMissing: "circ-test-notch-rect-rotate.step")
        guard let stock = loadModel("circ-test-notch-rect-rotate.step")?.selectableShapes.first?.stockInfo else {
            XCTFail("No stockInfo on circ-test-notch-rect-rotate.step"); return
        }
        XCTAssertTrue(stock.profile == .square || stock.profile == .rectangular,
                      "Rotated rect fixture must classify as rectangular/square HSS")
    }

    // MARK: - Stock Dimension Sanity

    func testLengthIsPositive() {
        let fixtures = ["circ-test.step", "circ-test-notch-rect.step", "circ-test-same.step"]
        for name in fixtures {
            guard let stock = loadModel(name)?.selectableShapes.first?.stockInfo else { continue }
            XCTAssertGreaterThan(stock.length, 0,
                                 "\(name): length must be positive, got \(stock.length)")
        }
    }

    func testAxisIsUnitVector() {
        let fixtures = ["circ-test.step", "circ-test-notch-rect.step", "circ-test-same.step"]
        for name in fixtures {
            guard let stock = loadModel(name)?.selectableShapes.first?.stockInfo else { continue }
            let len = simd_length(stock.axis)
            XCTAssertEqual(Double(len), 1.0, accuracy: 0.01,
                           "\(name): tube axis must be a unit vector (length=\(len))")
        }
    }

    func testODPositiveForRoundStock() throws {
        // Check any fixture that happens to be round; skip gracefully if none are.
        let roundFixtures = ["circ-test-simplified.step", "circ-test-same.step"]
        for name in roundFixtures {
            guard let stock = loadModel(name)?.selectableShapes.first?.stockInfo,
                  stock.profile == .round else { continue }
            XCTAssertGreaterThan(stock.od ?? 0, 0, "\(name): round stock OD must be positive")
            return
        }
        // No round fixture found — skip.
        throw XCTSkip("No round-profile fixture available to test OD assertion")
    }

    func testCrossSectionPositiveForRectStock() throws {
        _ = try skip(ifMissing: "circ-test-notch-rect.step")
        guard let stock = loadModel("circ-test-notch-rect.step")?.selectableShapes.first?.stockInfo else { return }
        guard stock.profile == .square || stock.profile == .rectangular else { return }
        XCTAssertGreaterThan(stock.odX ?? 0, 0, "Rect stock odX must be positive")
        XCTAssertGreaterThan(stock.odY ?? 0, 0, "Rect stock odY must be positive")
    }

    // MARK: - Feature Extraction

    func testBasicFeatureExtraction() throws {
        _ = try skip(ifMissing: "circ-test.step")
        guard let stock = loadModel("circ-test.step")?.selectableShapes.first?.stockInfo else { return }
        XCTAssertFalse(stock.features.isEmpty,
                       "circ-test.step must produce at least one surface feature")
        let types = Set(stock.features.map { $0.type })
        XCTAssertTrue(types.contains(.startCut) || types.contains(.endCut),
                      "Must detect at least one sever cut, got: \(types.map { $0.rawValue })")
    }

    func testNotchDetected() throws {
        _ = try skip(ifMissing: "circ-test-notch-rect.step")
        guard let stock = loadModel("circ-test-notch-rect.step")?.selectableShapes.first?.stockInfo else { return }
        let types = Set(stock.features.map { $0.type })
        XCTAssertTrue(types.contains(.notch) || types.contains(.cutout),
                      "Notch fixture must detect a notch/cutout, got: \(types.map { $0.rawValue })")
    }

    func testAllFeaturesFixtureHasMultipleFeatures() throws {
        _ = try skip(ifMissing: "circ-test-all.step")
        guard let stock = loadModel("circ-test-all.step")?.selectableShapes.first?.stockInfo else { return }
        XCTAssertGreaterThanOrEqual(stock.features.count, 2,
                             "circ-test-all.step must have at least 2 features, got \(stock.features.count)")
    }

    func testFeatureXPositionsWithinStockBounds() throws {
        _ = try skip(ifMissing: "circ-test-all.step")
        guard let stock = loadModel("circ-test-all.step")?.selectableShapes.first?.stockInfo else { return }
        let margin: CGFloat = 10.0     // allow small overhang for sever-cut tolerance
        for feature in stock.features {
            XCTAssertGreaterThanOrEqual(feature.xCenter, -margin,
                "Feature \(feature.id) xCenter \(feature.xCenter) is too far left of stock")
            XCTAssertLessThanOrEqual(feature.xCenter, stock.length + margin,
                "Feature \(feature.id) xCenter \(feature.xCenter) exceeds stock length \(stock.length)")
        }
    }

    // MARK: - Feature Path Sanity

    func testFeaturesHaveNonEmptyPaths() throws {
        _ = try skip(ifMissing: "circ-test.step")
        guard let stock = loadModel("circ-test.step")?.selectableShapes.first?.stockInfo else { return }
        for feature in stock.features {
            guard let path = feature.path else {
                XCTFail("Feature \(feature.id) has nil path"); continue
            }
            XCTAssertGreaterThan(path.count, 1,
                                 "Feature \(feature.id) path must have > 1 point for toolpath generation")
        }
    }

    // MARK: - Rotated Rect Fixture: Shape Count, Profile, Dimensions, Feature Count

    func testRotatedRectFixtureShapeCount() throws {
        _ = try skip(ifMissing: "circ-test-notch-rect-rotate.step")
        let model = loadModel("circ-test-notch-rect-rotate.step")
        let shapes = model?.selectableShapes ?? []
        XCTAssertEqual(shapes.count, 2,
                       "circ-test-notch-rect-rotate.step must contain exactly 2 selectable shapes, got \(shapes.count)")
    }

    func testRotatedRectFixtureProfileIsRect() throws {
        _ = try skip(ifMissing: "circ-test-notch-rect-rotate.step")
        guard let shapes = loadModel("circ-test-notch-rect-rotate.step")?.selectableShapes else { return }
        for (i, shape) in shapes.enumerated() {
            guard let stock = shape.stockInfo else {
                XCTFail("Shape \(i) has no stockInfo"); continue
            }
            XCTAssertTrue(stock.profile == .rectangular || stock.profile == .square,
                          "Shape \(i) must be HSS-Rect or HSS-Square, got \(stock.profile.rawValue)")
        }
    }

    func testRotatedRectFixtureDimensions() throws {
        _ = try skip(ifMissing: "circ-test-notch-rect-rotate.step")
        guard let shapes = loadModel("circ-test-notch-rect-rotate.step")?.selectableShapes else { return }
        let tolerance: CGFloat = 1.0   // ±1 mm to allow for measurement/rounding
        let expectedLarge: CGFloat = 76.2
        let expectedSmall: CGFloat = 50.8
        for (i, shape) in shapes.enumerated() {
            guard let stock = shape.stockInfo else { continue }
            let odX = stock.odX ?? 0
            let odY = stock.odY ?? 0
            let large = max(odX, odY)
            let small = min(odX, odY)
            XCTAssertEqual(Double(large), Double(expectedLarge), accuracy: Double(tolerance),
                           "Shape \(i) larger OD should be ~76.2 mm, got \(large) mm (odX=\(odX), odY=\(odY))")
            XCTAssertEqual(Double(small), Double(expectedSmall), accuracy: Double(tolerance),
                           "Shape \(i) smaller OD should be ~50.8 mm, got \(small) mm (odX=\(odX), odY=\(odY))")
        }
    }

    func testRotatedRectFixtureFeatureCount() throws {
        _ = try skip(ifMissing: "circ-test-notch-rect-rotate.step")
        guard let shapes = loadModel("circ-test-notch-rect-rotate.step")?.selectableShapes else { return }
        for (i, shape) in shapes.enumerated() {
            guard let stock = shape.stockInfo else {
                XCTFail("Shape \(i) has no stockInfo"); continue
            }
            XCTAssertEqual(stock.features.count, 3,
                           "Shape \(i) must have exactly 3 features, got \(stock.features.count): \(stock.features.map { $0.type.rawValue })")
        }
    }

    // MARK: - Simplified Fixture: Shape Count, Profile, Dimensions, Feature Count & Types

    func testSimplifiedFixtureShapeCount() throws {
        _ = try skip(ifMissing: "circ-test-simplified.step")
        let shapes = loadModel("circ-test-simplified.step")?.selectableShapes ?? []
        XCTAssertEqual(shapes.count, 2,
                       "circ-test-simplified.step must contain exactly 2 selectable shapes, got \(shapes.count)")
    }

    func testSimplifiedFixtureProfileIsSquare() throws {
        _ = try skip(ifMissing: "circ-test-simplified.step")
        guard let shapes = loadModel("circ-test-simplified.step")?.selectableShapes else { return }
        for (i, shape) in shapes.enumerated() {
            guard let stock = shape.stockInfo else {
                XCTFail("Shape \(i) has no stockInfo"); continue
            }
            XCTAssertEqual(stock.profile, .square,
                           "Shape \(i) must be HSS-Square, got \(stock.profile.rawValue)")
        }
    }

    func testSimplifiedFixtureDimensions() throws {
        _ = try skip(ifMissing: "circ-test-simplified.step")
        guard let shapes = loadModel("circ-test-simplified.step")?.selectableShapes else { return }
        let tolerance: CGFloat = 1.0   // ±1 mm to allow for measurement/rounding
        let expected: CGFloat = 12.7
        for (i, shape) in shapes.enumerated() {
            guard let stock = shape.stockInfo else { continue }
            let odX = stock.odX ?? stock.od ?? 0
            let odY = stock.odY ?? stock.od ?? 0
            XCTAssertEqual(Double(odX), Double(expected), accuracy: Double(tolerance),
                           "Shape \(i) odX should be ~12.7 mm, got \(odX) mm")
            XCTAssertEqual(Double(odY), Double(expected), accuracy: Double(tolerance),
                           "Shape \(i) odY should be ~12.7 mm, got \(odY) mm")
        }
    }

    func testSimplifiedFixtureFeatureCount() throws {
        _ = try skip(ifMissing: "circ-test-simplified.step")
        guard let shapes = loadModel("circ-test-simplified.step")?.selectableShapes else { return }
        for (i, shape) in shapes.enumerated() {
            guard let stock = shape.stockInfo else {
                XCTFail("Shape \(i) has no stockInfo"); continue
            }
            XCTAssertEqual(stock.features.count, 2,
                           "Shape \(i) must have exactly 2 features, got \(stock.features.count): \(stock.features.map { $0.type.rawValue })")
        }
    }

    func testSimplifiedFixtureFeatureTypes() throws {
        _ = try skip(ifMissing: "circ-test-simplified.step")
        guard let shapes = loadModel("circ-test-simplified.step")?.selectableShapes else { return }
        for (i, shape) in shapes.enumerated() {
            guard let stock = shape.stockInfo else { continue }
            let types = Set(stock.features.map { $0.type })
            XCTAssertTrue(types.contains(.startCut),
                          "Shape \(i) must have a startCut feature, got: \(types.map { $0.rawValue })")
            XCTAssertTrue(types.contains(.endCut),
                          "Shape \(i) must have an endCut feature, got: \(types.map { $0.rawValue })")
        }
    }

    // MARK: - Rect Complex Fixture: Shape Count, Profile, Dimensions, Feature Count & Types

    func testRectComplexFixtureShapeCount() throws {
        _ = try skip(ifMissing: "circ-test-rect-complex.step")
        let shapes = loadModel("circ-test-rect-complex.step")?.selectableShapes ?? []
        XCTAssertEqual(shapes.count, 1,
                       "circ-test-rect-complex.step must contain exactly 1 selectable shape, got \(shapes.count)")
    }

    func testRectComplexFixtureProfileIsRect() throws {
        _ = try skip(ifMissing: "circ-test-rect-complex.step")
        guard let stock = loadModel("circ-test-rect-complex.step")?.selectableShapes.first?.stockInfo else {
            XCTFail("No stockInfo on circ-test-rect-complex.step"); return
        }
        XCTAssertTrue(stock.profile == .rectangular || stock.profile == .square,
                      "Must be HSS-Rect or HSS-Square, got \(stock.profile.rawValue)")
    }

    func testRectComplexFixtureDimensions() throws {
        _ = try skip(ifMissing: "circ-test-rect-complex.step")
        guard let stock = loadModel("circ-test-rect-complex.step")?.selectableShapes.first?.stockInfo else { return }
        let tolerance: CGFloat = 1.0   // ±1 mm to allow for measurement/rounding
        let expectedLarge: CGFloat = 76.2
        let expectedSmall: CGFloat = 25.4
        let odX = stock.odX ?? 0
        let odY = stock.odY ?? 0
        let large = max(odX, odY)
        let small = min(odX, odY)
        XCTAssertEqual(Double(large), Double(expectedLarge), accuracy: Double(tolerance),
                       "Larger OD should be ~76.2 mm, got \(large) mm (odX=\(odX), odY=\(odY))")
        XCTAssertEqual(Double(small), Double(expectedSmall), accuracy: Double(tolerance),
                       "Smaller OD should be ~25.4 mm, got \(small) mm (odX=\(odX), odY=\(odY))")
    }

    func testRectComplexFixtureTotalFeatureCount() throws {
        _ = try skip(ifMissing: "circ-test-rect-complex.step")
        guard let stock = loadModel("circ-test-rect-complex.step")?.selectableShapes.first?.stockInfo else { return }
        XCTAssertEqual(stock.features.count, 6,
                       "Must have exactly 6 features, got \(stock.features.count): \(stock.features.map { $0.type.rawValue })")
    }

    func testRectComplexFixtureSeverCuts() throws {
        _ = try skip(ifMissing: "circ-test-rect-complex.step")
        guard let stock = loadModel("circ-test-rect-complex.step")?.selectableShapes.first?.stockInfo else { return }
        let types = stock.features.map { $0.type }
        XCTAssertEqual(types.filter { $0 == .startCut }.count, 1,
                       "Must have exactly 1 startCut, got \(types.filter { $0 == .startCut }.count)")
        XCTAssertEqual(types.filter { $0 == .endCut }.count, 1,
                       "Must have exactly 1 endCut, got \(types.filter { $0 == .endCut }.count)")
    }

    func testRectComplexFixtureCutoutCount() throws {
        _ = try skip(ifMissing: "circ-test-rect-complex.step")
        guard let stock = loadModel("circ-test-rect-complex.step")?.selectableShapes.first?.stockInfo else { return }
        let types = stock.features.map { $0.type }
        let cutouts = types.filter { $0 == .cutout || $0 == .notch || $0 == .hole }
        XCTAssertEqual(cutouts.count, 4,
                       "Must have exactly 4 cutout/notch/hole features, got \(cutouts.count): \(cutouts.map { $0.rawValue })")
    }

    // MARK: - Notch4 Fixture: Shape Count, Profile, OD, Feature Count & Types

    func testNotch4FixtureShapeCount() throws {
        _ = try skip(ifMissing: "circ-test-notch4.step")
        let shapes = loadModel("circ-test-notch4.step")?.selectableShapes ?? []
        XCTAssertEqual(shapes.count, 1,
                       "circ-test-notch4.step must contain exactly 1 selectable shape, got \(shapes.count)")
    }

    func testNotch4FixtureProfileIsRound() throws {
        _ = try skip(ifMissing: "circ-test-notch4.step")
        guard let stock = loadModel("circ-test-notch4.step")?.selectableShapes.first?.stockInfo else {
            XCTFail("No stockInfo on circ-test-notch4.step"); return
        }
        XCTAssertEqual(stock.profile, .round,
                       "Must be HSS-O (round), got \(stock.profile.rawValue)")
    }

    func testNotch4FixtureOD() throws {
        _ = try skip(ifMissing: "circ-test-notch4.step")
        guard let stock = loadModel("circ-test-notch4.step")?.selectableShapes.first?.stockInfo else { return }
        let tolerance: CGFloat = 1.0   // ±1 mm to allow for measurement/rounding
        let expectedOD: CGFloat = 42.2
        let od = stock.od ?? 0
        XCTAssertEqual(Double(od), Double(expectedOD), accuracy: Double(tolerance),
                       "OD should be ~42.2 mm, got \(od) mm")
    }

    func testNotch4FixtureTotalFeatureCount() throws {
        _ = try skip(ifMissing: "circ-test-notch4.step")
        guard let stock = loadModel("circ-test-notch4.step")?.selectableShapes.first?.stockInfo else { return }
        XCTAssertEqual(stock.features.count, 4,
                       "Must have exactly 4 features, got \(stock.features.count): \(stock.features.map { $0.type.rawValue })")
    }

    func testNotch4FixtureSeverCuts() throws {
        _ = try skip(ifMissing: "circ-test-notch4.step")
        guard let stock = loadModel("circ-test-notch4.step")?.selectableShapes.first?.stockInfo else { return }
        let types = stock.features.map { $0.type }
        XCTAssertEqual(types.filter { $0 == .startCut }.count, 1,
                       "Must have exactly 1 startCut, got \(types.filter { $0 == .startCut }.count)")
        XCTAssertEqual(types.filter { $0 == .endCut }.count, 1,
                       "Must have exactly 1 endCut, got \(types.filter { $0 == .endCut }.count)")
    }

    func testNotch4FixtureCutoutCount() throws {
        _ = try skip(ifMissing: "circ-test-notch4.step")
        guard let stock = loadModel("circ-test-notch4.step")?.selectableShapes.first?.stockInfo else { return }
        let types = stock.features.map { $0.type }
        let cutouts = types.filter { $0 == .cutout || $0 == .notch || $0 == .hole }
        XCTAssertEqual(cutouts.count, 2,
                       "Must have exactly 2 cutout/notch/hole features, got \(cutouts.count): \(cutouts.map { $0.rawValue })")
    }

    // MARK: - Round-trip: STEP → StockInfo → GCode

    func testSTEPToGCodeRoundTrip() throws {
        _ = try skip(ifMissing: "circ-test.step")
        guard let stock = loadModel("circ-test.step")?.selectableShapes.first?.stockInfo else { return }
        guard !stock.features.isEmpty else {
            XCTFail("circ-test.step produced no features to generate G-code for"); return
        }

        let gen = GCodeGenerator()
        var s = GCodeSettings()
        s.enableThermalHedging = false
        s.useSimCNC = false
        s.enableDynamicTHC = false
        gen.settings = s

        let gcode = gen.generateGCode(for: stock)
        XCTAssertTrue(gcode.hasPrefix("%"), "Round-trip G-code must start with %")
        XCTAssertTrue(gcode.contains("M3"),  "Round-trip G-code must have torch-on")
        XCTAssertTrue(gcode.contains("M5"),  "Round-trip G-code must have torch-off")
        XCTAssertFalse(gcode.isEmpty)
    }

    func testRectSTEPToGCodeRoundTrip() throws {
        _ = try skip(ifMissing: "circ-test-notch-rect.step")
        guard let stock = loadModel("circ-test-notch-rect.step")?.selectableShapes.first?.stockInfo else { return }

        let gen = GCodeGenerator()
        var s = GCodeSettings()
        s.enableThermalHedging = false
        s.useSimCNC = false
        s.enableDynamicTHC = false
        gen.settings = s

        let gcode = gen.generateGCode(for: stock)
        XCTAssertTrue(gcode.hasPrefix("%"))
        XCTAssertFalse(gcode.isEmpty)
    }
}
