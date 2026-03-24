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

    func testHSS2in2in125mm() throws {
        let name = "hss/2in-2in-125mm.step"
        let _ = try skip(ifMissing: name)
        
        guard let model = loadModel(name),
              let stock = model.selectableShapes.first?.stockInfo else {
            XCTFail("Failed to load model or extract stock info")
            return
        }
        
        // 1. Assert exactly 2 features, one startCut and one endCut.
        XCTAssertEqual(stock.features.count, 2, "Should have exactly 2 features for a plain square HSS")
        let types = Set(stock.features.map { $0.type })
        XCTAssertTrue(types.contains(.startCut), "Missing startCut")
        XCTAssertTrue(types.contains(.endCut), "Missing endCut")
        XCTAssertEqual(stock.profile, .square, "Should be identified as square stock")
        
        let gen = GCodeGenerator()
        var s = GCodeSettings()
        s.enableThermalHedging = false
        s.useSimCNC = false
        s.units = .metric
        s.enableKerfComp = false
        s.enableNonlinearErrorCompensation = false
        s.enableSingularityDamping = false
        gen.settings = s
        
        let gcode = gen.generateGCode(for: stock)
        let lines = gcode.components(separatedBy: .newlines)
        
        struct G1Move {
            var x, y, z, a: Double?
        }
        
        var cutBlocks: [[G1Move]] = []
        var currentBlock: [G1Move] = []
        var insideM3M5 = false
        
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.contains("M3") {
                insideM3M5 = true
                currentBlock = []
            } else if t.contains("M5") {
                if insideM3M5 && !currentBlock.isEmpty {
                    cutBlocks.append(currentBlock)
                }
                insideM3M5 = false
                currentBlock = []
            } else if insideM3M5 && (t.hasPrefix("G1") || t.hasPrefix("G0")) {
                var move = G1Move()
                let parts = t.components(separatedBy: .whitespaces)
                for p in parts {
                    let valStr = String(p.dropFirst())
                    if p.hasPrefix("X") { move.x = Double(valStr) }
                    else if p.hasPrefix("Y") { move.y = Double(valStr) }
                    else if p.hasPrefix("Z") { move.z = Double(valStr) }
                    else if p.hasPrefix("A") { move.a = Double(valStr) }
                }
                currentBlock.append(move)
            }
        }
        
        XCTAssertEqual(cutBlocks.count, 2, "Expected exactly 2 cutting blocks")
        
        for (blockIdx, block) in cutBlocks.enumerated() {
            guard let firstMove = block.first else { continue }
            let blockX = firstMove.x ?? 0.0
            
            // "no movement on X during cutting (between M3...M5)"
            for (moveIdx, move) in block.enumerated() {
                if let x = move.x {
                    XCTAssertEqual(x, blockX, accuracy: 0.001, "X moved in cutting block \(blockIdx) at move \(moveIdx)")
                }
            }
            
            // Pattern check: Torch moves on Y (flat), then AYZ (corner), then Y (flat)...
            // We expect 4 flat faces and 4 corners.
            enum segmentType { case flat, corner, unknown }
            struct Segment {
                let type: segmentType
                var distance: Double = 0
            }
            var segments: [Segment] = []
            
            var lastY: Double?
            var lastZ: Double?
            var lastA: Double?
            
            for move in block {
                let currentY = move.y ?? lastY
                let currentZ = move.z ?? lastZ
                let currentA = move.a ?? lastA

                let yDelta = (lastY != nil && currentY != nil) ? abs(currentY! - lastY!) : 0.0
                let zDelta = (lastZ != nil && currentZ != nil) ? abs(currentZ! - lastZ!) : 0.0
                let aDelta = (lastA != nil && currentA != nil) ? abs(currentA! - lastA!) : 0.0

                let yMove = yDelta > 0.001
                let zMove = zDelta > 0.001
                let aMove = aDelta > 0.001
                
                let currentType: segmentType
                if aMove && yMove && zMove {
                    currentType = .corner
                } else if yMove && !aMove && !zMove {
                    currentType = .flat
                } else {
                    currentType = .unknown
                }
                
                // For flat segments, distance is strictly along Y.
                let d = yDelta
                
                if segments.isEmpty || segments.last!.type != currentType {
                    segments.append(Segment(type: currentType, distance: d))
                } else {
                    segments[segments.count - 1].distance += d
                }
                
                lastY = currentY
                lastZ = currentZ
                lastA = currentA
            }
            
            // Filter out unknown segments (lead-ins/lead-outs might look different)
            let filteredSegments = segments.filter { $0.type != .unknown }
            
            // We expect at least 4 flats and 3 or 4 corners depending on where the cut starts/ends
            let flats = filteredSegments.filter { $0.type == .flat }
            let corners = filteredSegments.filter { $0.type == .corner }
            
            XCTAssertGreaterThanOrEqual(flats.count, 4, "Expected at least 4 flat segments in block \(blockIdx)")
            XCTAssertGreaterThanOrEqual(corners.count, 3, "Expected at least 3 corner segments in block \(blockIdx)")
            
            // "each flat side should be about 43.498mm"
            // Note: Lead-in/Lead-out might merge into one of the flats if they are perfectly aligned,
            // but the core faces should be exactly 43.498mm.
            var matchedFaces = 0
            for flat in flats {
                if abs(flat.distance - 43.498) < 0.1 {
                    matchedFaces += 1
                }
            }
            XCTAssertGreaterThanOrEqual(matchedFaces, 3, "Expected at least 3-4 flat faces to be exactly 43.498mm in block \(blockIdx). Found \(matchedFaces) with distance \(flats.map{$0.distance})")
        }
    }

    func testCylinderOneNotch() throws {
        let name = "cylinder-one-notch.step"
        let _ = try skip(ifMissing: name)
        
        guard let model = loadModel(name),
              let stock = model.selectableShapes.first?.stockInfo else {
            XCTFail("Failed to load model or extract stock info")
            return
        }
        
        // This model has 3 features: a startCut (X=0), an endCut (X=279.3), and a fishmouth cutout (X=214).
        // The user's request focuses on the one straight cut and one fishmouth.
        XCTAssertGreaterThanOrEqual(stock.features.count, 2, "Expected at least 2 features")
        
        let gen = GCodeGenerator()
        var s = GCodeSettings()
        s.enableThermalHedging = false
        s.useSimCNC = false
        s.units = .metric
        s.enableKerfComp = false
        s.enableNonlinearErrorCompensation = false
        s.enableSingularityDamping = false
        gen.settings = s
        
        let gcode = gen.generateGCode(for: stock)
        let lines = gcode.components(separatedBy: .newlines)
        
        struct G1Move {
            var x, y, z, a: Double?
        }
        
        var cutBlocks: [[G1Move]] = []
        var currentBlock: [G1Move] = []
        var insideM3M5 = false
        
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.contains("M3") {
                insideM3M5 = true
                currentBlock = []
            } else if t.contains("M5") {
                if insideM3M5 && !currentBlock.isEmpty {
                    cutBlocks.append(currentBlock)
                }
                insideM3M5 = false
                currentBlock = []
            } else if insideM3M5 && (t.hasPrefix("G1") || t.hasPrefix("G0")) {
                var move = G1Move()
                let parts = t.components(separatedBy: .whitespaces)
                for p in parts {
                    let valStr = String(p.dropFirst())
                    if p.hasPrefix("X") { move.x = Double(valStr) }
                    else if p.hasPrefix("Y") { move.y = Double(valStr) }
                    else if p.hasPrefix("Z") { move.z = Double(valStr) }
                    else if p.hasPrefix("A") { move.a = Double(valStr) }
                }
                currentBlock.append(move)
            }
        }
        
        XCTAssertGreaterThanOrEqual(cutBlocks.count, 2, "Expected at least 2 torch-on blocks")
        
        var foundStraightCut = false
        var foundFishmouth = false
        
        for (idx, block) in cutBlocks.enumerated() {
            let xValues = block.compactMap { $0.x }.filter { !$0.isNaN }
            let yValues = block.compactMap { $0.y }.filter { !$0.isNaN }
            let zValues = block.compactMap { $0.z }.filter { !$0.isNaN }
            let aValues = block.compactMap { $0.a }.filter { !$0.isNaN }
            
            let xSpan = (xValues.max() ?? 0) - (xValues.min() ?? 0)
            let ySpan = (yValues.max() ?? 0) - (yValues.min() ?? 0)
            let zSpan = (zValues.max() ?? 0) - (zValues.min() ?? 0)
            
            if xSpan < 0.01 {
                // Straight cut: No movement on X, Y, or Z. Only A.
                XCTAssertLessThan(ySpan, 0.01, "Y moved in straight cut block \(idx)")
                XCTAssertLessThan(zSpan, 0.01, "Z moved in straight cut block \(idx)")
                XCTAssertGreaterThan(aValues.count, 0, "No A moves in straight cut block \(idx)")
                foundStraightCut = true
            } else {
                // Fishmouth: Movement on X and A. No movement on Y or Z.
                XCTAssertLessThan(ySpan, 0.01, "Y moved in fishmouth block \(idx)")
                XCTAssertLessThan(zSpan, 0.01, "Z moved in fishmouth block \(idx)")
                XCTAssertGreaterThan(xSpan, 1.0, "X did not move enough in fishmouth block \(idx)")
                foundFishmouth = true
            }
        }
        
        XCTAssertTrue(foundStraightCut, "Could not find a straight cut block (constant X)")
        XCTAssertTrue(foundFishmouth, "Could not find a fishmouth block (varying X)")
    }

    func testHSSO3in125mmNoFeatures() throws {
        let name = "hss-o/3in-125mm-no-features.step"
        let _ = try skip(ifMissing: name)
        
        guard let model = loadModel(name) else {
            XCTFail("Failed to load model from \(name)")
            return
        }
        
        guard !model.selectableShapes.isEmpty else {
            XCTFail("Model \(name) has no selectable shapes")
            return
        }
        
        guard let stock = model.selectableShapes.first?.stockInfo else {
            XCTFail("Failed to extract stock info from model \(name)")
            return
        }
        
        // 1. Assert exactly 2 features, one startCut and one endCut.
        XCTAssertEqual(stock.features.count, 2, "Should have exactly 2 features for a plain tube (start/end cuts). Found: \(stock.features.map { $0.type.rawValue })")
        let types = Set(stock.features.map { $0.type })
        XCTAssertTrue(types.contains(.startCut), "Missing startCut")
        XCTAssertTrue(types.contains(.endCut), "Missing endCut")
        
        let gen = GCodeGenerator()
        var s = GCodeSettings()
        s.enableThermalHedging = false // predictable sequence (start/end)
        s.useSimCNC = false
        s.units = .metric
        s.enableKerfComp = false
        s.enableNonlinearErrorCompensation = false
        s.enableSingularityDamping = false
        gen.settings = s
        
        let gcode = gen.generateGCode(for: stock)
        let lines = gcode.components(separatedBy: .newlines)
        
        // 2. Parse G-code to verify movement constraints.
        struct G1Move {
            var x, y, z, a: Double?
        }
        
        var cutBlocks: [[G1Move]] = []
        var currentBlock: [G1Move] = []
        var insideM3M5 = false
        
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.contains("M3") {
                insideM3M5 = true
                currentBlock = []
            } else if t.contains("M5") {
                if insideM3M5 && !currentBlock.isEmpty {
                    cutBlocks.append(currentBlock)
                }
                insideM3M5 = false
                currentBlock = []
            } else if insideM3M5 && (t.hasPrefix("G1") || t.hasPrefix("G0")) {
                var move = G1Move()
                let parts = t.components(separatedBy: .whitespaces)
                for p in parts {
                    let valStr = String(p.dropFirst())
                    if p.hasPrefix("X") { move.x = Double(valStr) }
                    else if p.hasPrefix("Y") { move.y = Double(valStr) }
                    else if p.hasPrefix("Z") { move.z = Double(valStr) }
                    else if p.hasPrefix("A") { move.a = Double(valStr) }
                }
                currentBlock.append(move)
            }
        }
        
        if cutBlocks.count != 2 {
            print("FULL GCODE OUTPUT:\n\(gcode)")
            XCTFail("Expected exactly 2 torch-on cutting blocks, but found \(cutBlocks.count)")
            return
        }
        
        var blockCentroidsX: [Double] = []
        
        for (idx, block) in cutBlocks.enumerated() {
            guard let firstMove = block.first else { continue }
            let firstX = firstMove.x ?? 0
            let firstY = firstMove.y ?? 0
            let firstZ = firstMove.z ?? 0
            blockCentroidsX.append(firstX)
            
            XCTAssertFalse(firstX.isNaN, "X in block \(idx) is NaN")
            XCTAssertFalse(firstY.isNaN, "Y in block \(idx) is NaN")
            XCTAssertFalse(firstZ.isNaN, "Z in block \(idx) is NaN")
            
            // "both ends are cut with ONLY rotation on the A axis. X does not move during cutting (between M3...M5), Y does not move, Z does not move"
            for (moveIdx, move) in block.enumerated() {
                if let x = move.x {
                    XCTAssertEqual(x, firstX, accuracy: 0.001, "X moved in block \(idx) at move \(moveIdx) (expected constant X=\(firstX), got \(x))")
                }
                if let y = move.y {
                    XCTAssertEqual(y, firstY, accuracy: 0.001, "Y moved in block \(idx) at move \(moveIdx) (expected constant Y=\(firstY), got \(y))")
                }
                if let z = move.z {
                    XCTAssertEqual(z, firstZ, accuracy: 0.001, "Z moved in block \(idx) at move \(moveIdx) (expected constant Z=\(firstZ), got \(z))")
                }
            }
            
            // "the rotation is a full circle, so 360 degrees (or slightly more due to overburn on A)"
            let aValues = block.compactMap { $0.a }.filter { !$0.isNaN }
            if let minA = aValues.min(), let maxA = aValues.max() {
                let span = maxA - minA
                XCTAssertGreaterThanOrEqual(span, 359.0, "Rotation span in block \(idx) should be ~360°, got \(span)°")
            } else {
                XCTFail("No valid A values found in block \(idx)")
            }
        }
        
        // "there's a motion command between the cuts to move from start to end, which should be 125mm."
        if blockCentroidsX.count == 2 {
            let dist = abs(blockCentroidsX[0] - blockCentroidsX[1])
            XCTAssertEqual(dist, 125.0, accuracy: 0.1, "Distance between the two cut ends should be 125mm")
        }
    }
}
