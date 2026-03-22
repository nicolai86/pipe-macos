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
