import Foundation
import SceneKit
import simd

// MARK: - Objective-C Bridge Interface
class STEPBridgeWrapperSwift {
    static func parseSTEPToJSON(_ url: URL) -> String? {
        do { return try STEPBridgeWrapper.parseSTEP(toJSON: url) }
        catch { print("OCCT bridge error: \(error)"); return nil }
    }
}

// MARK: - Multi-Body UI Types
struct Model3D {
    var url: URL?
    var rootNode: SCNNode = SCNNode()
    var selectableShapes: [SelectedShape] = []
}

struct SelectedShape: Equatable, Identifiable {
    let id = UUID()
    var node: SCNNode?
    var shapeData: ShapeData?
    var stockInfo: StockInfo? { return shapeData?.stockInfo }
    static func == (lhs: SelectedShape, rhs: SelectedShape) -> Bool { return lhs.node === rhs.node }
}

// MARK: - Stock Profile Types
enum StockProfile: String, Codable {
    case round = "HSS-O"
    case square = "HSS-Square"
    case rectangular = "HSS-Rect"
    case unknown = "UNKNOWN"
}

enum SurfaceFeatureType: String, Codable { case hole, notch, cutout, startCut, endCut }
enum FeatureShape: String, Codable { case circle, rectangle, custom }

// MARK: - Core Data Models
struct CylinderDimensions: Codable { var diameter: CGFloat; var height: CGFloat }
struct BoxDimensions: Codable { var width: CGFloat; var height: CGFloat; var depth: CGFloat }
struct ShapeData: Codable {
    enum ShapeType: String, Codable { case cylinder, box, custom }
    var type: ShapeType
    var dimensions: AnyCodable?
    var isCuttable: Bool
    var stockInfo: StockInfo?
}

class StockInfo: Codable {
    var profile: StockProfile
    var od: CGFloat?
    var odX: CGFloat?
    var odY: CGFloat?
    var cornerRadius: CGFloat?
    var length: CGFloat
    var axis: SIMD3<Float>
    /// Cross-section "up" axis — one of the face normal directions perpendicular to axis.
    /// Used in pack view to roll all pieces to the same orientation.
    var uAxis: SIMD3<Float>
    var origin: SIMD3<Float>
    var features: [GeometricFeature] = []
    /// Face-to-face distance in the uAxis direction (= vertical extent toward torch after roll alignment).
    /// Nil for round stock. For HSS-Rect/Square: vertDim = uAxisDimension, horizDim = (odX+odY) - uAxisDimension.
    var uAxisDimension: CGFloat?

    init(profile: StockProfile, od: CGFloat? = nil, odX: CGFloat? = nil, odY: CGFloat? = nil, length: CGFloat, axis: SIMD3<Float>, uAxis: SIMD3<Float>, origin: SIMD3<Float>) {
        self.profile = profile; self.od = od; self.odX = odX; self.odY = odY; self.length = length; self.axis = axis; self.uAxis = uAxis; self.origin = origin
    }
}

struct ToolpathPoint: Codable { var x: CGFloat; var a: CGFloat }

struct GeometricFeature: Codable, Identifiable {
    var id: Int
    var type: SurfaceFeatureType
    var shape: FeatureShape
    var xCenter: CGFloat
    var aCenterDeg: CGFloat
    var dimensions: [String: CGFloat]
    var confidence: Float
    var rawPath: [ToolpathPoint]
}

struct Mesh3D {
    var vertices: [SCNVector3]
    var faces: [[Int]]
    var shapeData: ShapeData?
}

// MARK: - Helper to wrap generic Codable dictionary
struct AnyCodable: Codable {
    let value: Any
    init(_ value: Any) { self.value = value }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let d = try? container.decode(CylinderDimensions.self) { value = d }
        else if let b = try? container.decode(BoxDimensions.self) { value = b }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown dimension") }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let d = value as? CylinderDimensions { try container.encode(d) }
        else if let b = value as? BoxDimensions { try container.encode(b) }
    }
}


// MARK: - Bulletproof JSON Extractors
fileprivate func getFloat(_ dict: [String: Any]?, _ key: String) -> Float {
    guard let dict = dict else { return 0.0 }
    if let d = dict[key] as? Double { return Float(d) }
    if let f = dict[key] as? Float { return f }
    if let n = dict[key] as? NSNumber { return n.floatValue }
    return 0.0
}

fileprivate func getInt(_ dict: [String: Any], _ key: String) -> Int {
    if let i = dict[key] as? Int { return i }
    if let n = dict[key] as? NSNumber { return n.intValue }
    return 0
}

fileprivate func getIntArray(_ anyArr: Any?) -> [Int] {
    if let arr = anyArr as? [Int] { return arr }
    if let arr = anyArr as? [NSNumber] { return arr.map { $0.intValue } }
    if let arr = anyArr as? [Double] { return arr.map { Int($0) } }
    return []
}

fileprivate func getIntMatrix(_ anyArr: Any?) -> [[Int]] {
    guard let outer = anyArr as? [Any] else { return [] }
    var result: [[Int]] = []
    for inner in outer { result.append(getIntArray(inner)) }
    return result
}

// MARK: - Model Loader
class ModelLoader {

    static func loadSTEP(url: URL) -> Model3D? {
        guard let jsonString = STEPBridgeWrapperSwift.parseSTEPToJSON(url),
              let jsonData = jsonString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any],
              let solids = parsed["solids"] as? [[String: Any]] else {
            return nil
        }

        var model = Model3D()
        model.url = url

        var allVertices: [SCNVector3] = []
        var tempNodes: [(node: SCNNode, mesh: Mesh3D, stockInfo: StockInfo?, solidId: Any)] = []

        for solidData in solids {
            if let (mesh, stockInfo) = try? parseSolidJSON(solidData) {
                allVertices.append(contentsOf: mesh.vertices)

                let geometry = SCNGeometry(vertices: mesh.vertices, faces: mesh.faces)
                let material = SCNMaterial()
                material.diffuse.contents = NSColor.lightGray
                material.isDoubleSided = true
                geometry.materials = [material]

                let node = SCNNode(geometry: geometry)
                let solidId = solidData["solidId"] ?? UUID().uuidString

                tempNodes.append((node: node, mesh: mesh, stockInfo: stockInfo, solidId: solidId))
            }
        }

        var globalMin = SCNVector3(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var globalMax = SCNVector3(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)

        for v in allVertices {
            globalMin.x = min(globalMin.x, v.x); globalMin.y = min(globalMin.y, v.y); globalMin.z = min(globalMin.z, v.z)
            globalMax.x = max(globalMax.x, v.x); globalMax.y = max(globalMax.y, v.y); globalMax.z = max(globalMax.z, v.z)
        }

        let globalCenter = SCNVector3((globalMin.x + globalMax.x) / 2, (globalMin.y + globalMax.y) / 2, (globalMin.z + globalMax.z) / 2)

        for temp in tempNodes {
            temp.node.name = "model_solid_\(temp.solidId)"
            model.rootNode.addChildNode(temp.node)
            model.selectableShapes.append(SelectedShape(node: temp.node, shapeData: temp.mesh.shapeData))
        }

        model.rootNode.position = SCNVector3(-globalCenter.x, -globalCenter.y, -globalCenter.z)
        return model
    }

    private static func parseSolidJSON(_ solid: [String: Any]) throws -> (Mesh3D, StockInfo?) {
        let facesData = solid["faces"] as? [[String: Any]] ?? []

        // Build render mesh
        var renderVerts: [SCNVector3] = []
        var renderFaces: [[Int]] = []
        for f in facesData {
            let vArr = f["vertices"] as? [[String: Any]] ?? []
            let offset = renderVerts.count
            for v in vArr {
                renderVerts.append(SCNVector3(CGFloat(getFloat(v, "x")), CGFloat(getFloat(v, "y")), CGFloat(getFloat(v, "z"))))
            }
            for idxs in getIntMatrix(f["indices"]) { renderFaces.append(idxs.map { $0 + offset }) }
        }

        // --- Step 1: Seed tube axis from PCA (direction-only fallback) ---
        // pcaAxis is kept immutable so it can be used as a stable reference in all later steps.
        let pca = solid["pca"] as? [String: Any]
        let rawPca = SIMD3<Float>(getFloat(pca, "axis3X"), getFloat(pca, "axis3Y"), getFloat(pca, "axis3Z"))
        let pcaAxis = length(rawPca) > 0.1 ? normalize(rawPca) : SIMD3<Float>(1, 0, 0)
        var tubeAxis = pcaAxis

        // --- Step 2: Cluster exact OCCT plane normals (rotation-invariant, no winding dependency) ---
        // WHY: We extract plane normals directly from the OpenCASCADE B-Rep geometry. 
        // By clustering these normals, we find the dominant faces of a square or rectangular tube.
        // This method is robust against arbitrary stock orientation in the STEP file.
        var normalClusters: [(dir: SIMD3<Float>, weight: Int)] = []
        for f in facesData {
            guard let type = f["surface_type"] as? String, type == "PLANE",
                  let pd = f["plane"] as? [String: Any] else { continue }
            let raw = SIMD3<Float>(getFloat(pd, "normalX"), getFloat(pd, "normalY"), getFloat(pd, "normalZ"))
            guard length(raw) > 0.5 else { continue }
            let n = normalize(raw)
            let w = (f["vertices"] as? [[String: Any]])?.count ?? 1
            var found = false
            for i in 0..<normalClusters.count {
                if abs(dot(normalClusters[i].dir, n)) > 0.95 { normalClusters[i].weight += w; found = true; break }
            }
            if !found { normalClusters.append((dir: n, weight: w)) }
        }
        normalClusters.sort { $0.weight > $1.weight }

        // --- Step 3: Derive tube axis from perpendicular normal pairs ---
        var bestScore: Float = 0.0
        for i in 0..<normalClusters.count {
            for j in (i + 1)..<normalClusters.count {
                let n1 = normalClusters[i].dir, n2 = normalClusters[j].dir
                guard abs(dot(n1, n2)) < 0.15 else { continue }  // must be perpendicular
                let candidate = normalize(cross(n1, n2))
                let alignment = abs(dot(candidate, pcaAxis))  // always score against immutable PCA
                guard alignment > 0.95 else { continue }       // reject candidates >~18° from PCA
                let score = Float(normalClusters[i].weight + normalClusters[j].weight) * alignment
                if score > bestScore {
                    bestScore = score
                    tubeAxis = dot(candidate, pcaAxis) >= 0 ? candidate : -candidate
                }
            }
        }

        // --- Step 4: Refine tube axis; measure cylinder angular coverage ---
        // Round tubes have one dominant cylinder subtending ~360° around the tube axis.
        // Rectangular-tube corner fillets each subtend only ~90°.  We measure the
        // angular span of each cylinder's tessellation vertices in the cross-section
        // plane via the "largest-gap" method (span = 2π − maxGap) so the result is
        // exact and model-independent — no hardcoded radius or vertex-count limits.
        // WHY: This is the critical discriminator between a round tube (HSS-O) and
        // rectangular stock with fillets. A round tube will have at least one cylinder
        // with >180° span, while a fillet never exceeds 90°.
        var maxCylAngularSpan: Float = 0
        var filletRadii: [Float] = []
        for f in facesData {
            guard let type = f["surface_type"] as? String, type == "CYLINDER",
                  let cd = f["cylinder"] as? [String: Any] else { continue }
            let axis = normalize(SIMD3<Float>(getFloat(cd, "axisX"), getFloat(cd, "axisY"), getFloat(cd, "axisZ")))
            guard abs(dot(axis, tubeAxis)) > 0.9 else { continue }
            let verts = f["vertices"] as? [[String: Any]] ?? []
            guard verts.count >= 3 else { continue }

            // Build an orthonormal basis {u, v} perpendicular to the cylinder axis.
            let loc = SIMD3<Float>(getFloat(cd, "locationX"), getFloat(cd, "locationY"), getFloat(cd, "locationZ"))
            let arb: SIMD3<Float> = abs(axis.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
            let uVec = normalize(cross(axis, arb))
            let vVec = normalize(cross(axis, uVec))

            // Project each vertex onto the cross-section plane and compute its angle.
            let angles: [Float] = verts.map { vtx in
                let p = SIMD3<Float>(getFloat(vtx, "x"), getFloat(vtx, "y"), getFloat(vtx, "z")) - loc
                return atan2(dot(p, vVec), dot(p, uVec))
            }.sorted()

            // Largest gap between consecutive sorted angles (including wrap-around).
            var maxGap = angles[0] + 2 * .pi - angles[angles.count - 1]
            for i in 1..<angles.count { maxGap = max(maxGap, angles[i] - angles[i - 1]) }
            let span = 2 * .pi - maxGap

            if span > maxCylAngularSpan {
                maxCylAngularSpan = span
                tubeAxis = dot(axis, tubeAxis) >= 0 ? axis : -axis
            }
            
            // Fillet identification: subtends ~90 degrees (between 45 and 135)
            if span < 0.75 * .pi && span > 0.25 * .pi {
                filletRadii.append(getFloat(cd, "radius"))
            }
        }
        tubeAxis = normalize(tubeAxis)
        let cornerRadius = filletRadii.isEmpty ? nil : filletRadii.reduce(0, +) / Float(filletRadii.count)

        // --- Step 5: Determine cross-section axes (uAxis / vAxis) ---
        let sideWallCandidates = normalClusters.filter { abs(dot($0.dir, tubeAxis)) < 0.2 }
        let sideWallsWithPartners = sideWallCandidates.filter { c in
            sideWallCandidates.contains { other in abs(dot(c.dir, other.dir)) < 0.15 }
        }

        let uAxis: SIMD3<Float>
        if let dominant = sideWallsWithPartners.first {
            uAxis = dominant.dir
        } else if let sideWall = sideWallCandidates.first {
            uAxis = sideWall.dir
        } else {
            let arb: SIMD3<Float> = abs(tubeAxis.x) > 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
            uAxis = normalize(cross(tubeAxis, arb))
        }
        let vAxis = normalize(cross(tubeAxis, uAxis))

        // --- Step 6: Extremum measurement over all mesh vertices ---
        var minX: Float = .greatestFiniteMagnitude,  maxX: Float = -.greatestFiniteMagnitude
        var maxPosU: Float = -.greatestFiniteMagnitude, minNegU: Float = .greatestFiniteMagnitude
        var maxPosV: Float = -.greatestFiniteMagnitude, minNegV: Float = .greatestFiniteMagnitude

        for v in renderVerts {
            let p = SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
            let x = dot(p, tubeAxis); let u = dot(p, uAxis); let vv = dot(p, vAxis)
            minX = min(minX, x); maxX = max(maxX, x)
            maxPosU = max(maxPosU, u); minNegU = min(minNegU, u)
            maxPosV = max(maxPosV, vv); minNegV = min(minNegV, vv)
        }

        let trueLength   = maxX - minX
        let trueWidth    = maxPosU - minNegU
        let trueHeight   = maxPosV - minNegV
        let trueCenter   = tubeAxis * ((minX + maxX) / 2.0)
                         + uAxis   * ((maxPosU + minNegU) / 2.0)
                         + vAxis   * ((maxPosV + minNegV) / 2.0)

        let trueCrossMax = max(trueWidth, trueHeight)
        let trueCrossMin = min(trueWidth, trueHeight)

        // A round tube has one cylinder spanning > π (180°) around its axis.
        // Rectangular corner fillets each span only ~ π/2 (90°), so no single fillet
        // ever crosses the half-circle threshold regardless of radius or mesh density.
        let isRound = maxCylAngularSpan > .pi
        let isRectangular = !isRound && !sideWallCandidates.isEmpty

        let profile: StockProfile
        if isRectangular {
            profile = abs(trueCrossMax - trueCrossMin) < 2.0 ? .square : .rectangular
        } else if isRound {
            profile = .round
        } else {
            profile = .round
        }

        let stockInfo = StockInfo(
            profile: profile,
            od:  isRectangular ? nil : CGFloat(trueCrossMax),
            odX: isRectangular ? CGFloat(trueCrossMax) : nil,
            odY: isRectangular ? CGFloat(trueCrossMin) : nil,
            length: CGFloat(trueLength),
            axis: tubeAxis,
            uAxis: uAxis,
            origin: trueCenter
        )
        if isRectangular { 
            stockInfo.uAxisDimension = CGFloat(trueWidth)
            if let cr = cornerRadius {
                stockInfo.cornerRadius = CGFloat(cr)
            }
        }

        extractFeaturesFromTopology(
            facesData: facesData, renderVerts: renderVerts, tubeAxis: tubeAxis, uAxis: uAxis, vAxis: vAxis,
            center: trueCenter, maxPosU: maxPosU, minNegU: minNegU, maxPosV: maxPosV, minNegV: minNegV,
            stockInfo: stockInfo
        )

        let shapeData = ShapeData(type: isRectangular ? .box : .cylinder, dimensions: nil, isCuttable: true, stockInfo: stockInfo)
        return (Mesh3D(vertices: renderVerts, faces: renderFaces, shapeData: shapeData), stockInfo)
    }

    // MARK: - Internal helpers (exposed for unit-testing threshold boundary conditions)

    /// Stitches an unordered collection of partial loops into complete feature loops by
    /// connecting segments whose endpoints are within `tolerance` mm of each other.
    ///
    /// Exposed `internal` so unit tests can drive it directly with synthetic data to verify
    /// the fixed stitchTolerance (2 mm) does not accidentally merge features that are
    /// 2–3 mm apart at face boundaries (bug 2 regression).
    internal static func stitch(_ partialLoops: [[SIMD3<Float>]], tolerance: Float) -> [[SIMD3<Float>]] {
        var loops: [[SIMD3<Float>]] = []
        var unvisited = partialLoops
        while !unvisited.isEmpty {
            var current = unvisited.removeFirst()
            var added = true
            while added {
                added = false
                for (i, seg) in unvisited.enumerated() {
                    let s = current.first!, e = current.last!
                    let es = seg.first!, ee = seg.last!
                    if distance(e, es) < tolerance {
                        current.append(contentsOf: seg.dropFirst()); unvisited.remove(at: i); added = true; break
                    } else if distance(e, ee) < tolerance {
                        current.append(contentsOf: seg.reversed().dropFirst()); unvisited.remove(at: i); added = true; break
                    } else if distance(s, ee) < tolerance {
                        current.insert(contentsOf: seg.dropLast(), at: 0); unvisited.remove(at: i); added = true; break
                    } else if distance(s, es) < tolerance {
                        current.insert(contentsOf: seg.reversed().dropLast(), at: 0); unvisited.remove(at: i); added = true; break
                    }
                }
            }
            loops.append(current)
        }
        return loops
    }

    /// Classifies a feature loop as startCut, endCut, notch, or cutout given its axial
    /// extents and whether it is a full-profile (360°) contour.
    ///
    /// Exposed `internal` so unit tests can verify that the fixed `axisTol` (2 mm) does
    /// not promote features starting 2–3 mm from a tube end into `.notch` — which the old
    /// `max(3.0, tubeLength × 0.015)` formula did (bug 3 regression).
    internal static func featureType(
        loopMinX: Float, loopMaxX: Float,
        tubeLength: Float, isFullProfile: Bool, axisTol: Float
    ) -> SurfaceFeatureType {
        let touchesStart = loopMinX <= axisTol
        let touchesEnd   = loopMaxX >= tubeLength - axisTol
        if isFullProfile && touchesStart { return .startCut }
        if isFullProfile && touchesEnd   { return .endCut   }
        if touchesStart || touchesEnd    { return .notch    }
        return .cutout
    }

    // MARK: - AAG Feature Extractor (exact OCCT normals + centroid-based hull identification)
    private static func extractFeaturesFromTopology(
        facesData: [[String: Any]], renderVerts: [SCNVector3], tubeAxis: SIMD3<Float>, uAxis: SIMD3<Float>, vAxis: SIMD3<Float>,
        center: SIMD3<Float>, maxPosU: Float, minNegU: Float, maxPosV: Float, minNegV: Float, stockInfo: StockInfo
    ) {
        // A PLANE face is on the outer hull if its projection onto its own normal equals the
        // global maximum in that direction. OCCT's tessellation evaluates plane vertices
        // exactly (planes are linear), so they land within floating-point precision of maxD.
        // 0.5 mm (5× the 0.1 mm mesh deflection) gives ample numerical margin while staying
        // safely below any realistic wall thickness — ruling out inner faces on all standard
        // HSS grades (minimum EN 10219 / ASTM A500 wall thickness is 1.5 mm).
        let extremumTol: Float = 0.5
        var outerWallFaceIDs = Set<Int>()

        // Identify outer hull faces using each face's OWN normal direction as reference.
        for face in facesData {
            let faceID = getInt(face, "faceID")
            guard let vArr = face["vertices"] as? [[String: Any]], !vArr.isEmpty else { continue }

            if let type = face["surface_type"] as? String {
                if type == "PLANE", let pd = face["plane"] as? [String: Any] {
                    let n = normalize(SIMD3<Float>(getFloat(pd, "normalX"), getFloat(pd, "normalY"), getFloat(pd, "normalZ")))
                    guard length(n) > 0.5, abs(dot(n, tubeAxis)) < 0.15 else { continue }

                    let fv = vArr[0]
                    let d = dot(SIMD3<Float>(getFloat(fv, "x"), getFloat(fv, "y"), getFloat(fv, "z")), n)

                    var maxD: Float = -.greatestFiniteMagnitude
                    for rv in renderVerts {
                        maxD = max(maxD, dot(SIMD3<Float>(Float(rv.x), Float(rv.y), Float(rv.z)), n))
                    }

                    if d >= maxD - extremumTol {
                        outerWallFaceIDs.insert(faceID)
                    }
                } else if type == "CYLINDER", let cyl = face["cylinder"] as? [String: Any] {
                    let cAxis = normalize(SIMD3<Float>(getFloat(cyl, "axisX"), getFloat(cyl, "axisY"), getFloat(cyl, "axisZ")))
                    let axisAlign = abs(dot(cAxis, tubeAxis))
                    guard axisAlign > 0.9 else { continue }
                    let cLoc = SIMD3<Float>(getFloat(cyl, "locationX"), getFloat(cyl, "locationY"), getFloat(cyl, "locationZ"))
                    let radius = getFloat(cyl, "radius")
                    let u  = abs(dot(cLoc - center, uAxis))
                    let vv = abs(dot(cLoc - center, vAxis))
                    
                    let halfU = (maxPosU - minNegU) / 2.0
                    let halfV = (maxPosV - minNegV) / 2.0
                    let cylTol: Float = 0.5
                    
                    if u + radius >= halfU - cylTol || vv + radius >= halfV - cylTol {
                        outerWallFaceIDs.insert(faceID)
                    }
                }
            }
        }

        // =================================================================================
        // SOTA: HIERARCHICAL WIRE EXTRACTION
        // We now extract and maintain the exact OpenCASCADE wire topology.
        // BRepTools_WireExplorer guarantees edges are sequential. We append them safely
        // without distance-guessing, which prevents jumping kerf gaps.
        // WHY: Naive point-clustering often fails when multiple cut lines are close 
        // (e.g. kerf width gaps). By following the topological wires, we ensure that
        // feature boundaries are extracted exactly as defined in the CAD model.
        // =================================================================================
        var partialLoops: [[SIMD3<Float>]] = []

        for face in facesData {
            let faceID = getInt(face, "faceID")
            guard outerWallFaceIDs.contains(faceID),
                  let wires = face["wires"] as? [[String: Any]] else { continue }

            for wire in wires {
                guard let edges = wire["edges"] as? [[String: Any]] else { continue }
                
                var currentWireLoop: [SIMD3<Float>] = []
                
                // Iterate through the edges sequentially as provided by BRepTools_WireExplorer
                for edge in edges {
                    let adjFaces = getIntArray(edge["adjacentFaceIDs"])
                    guard let pointsData = edge["points"] as? [[String: Any]], !pointsData.isEmpty else { continue }
                    
                    // Manifold feature boundary edge check
                    let touchesInnerFace = adjFaces.count >= 2 &&
                        adjFaces.contains { !outerWallFaceIDs.contains($0) }
                    
                    if touchesInnerFace {
                        var pts: [SIMD3<Float>] = []
                        for p in pointsData { pts.append(SIMD3<Float>(getFloat(p, "x"), getFloat(p, "y"), getFloat(p, "z"))) }
                        
                        if currentWireLoop.isEmpty {
                            currentWireLoop.append(contentsOf: pts)
                        } else {
                            let lastPt = currentWireLoop.last!
                            let firstPt = pts.first!
                            let endPt = pts.last!
                            
                            // 1e-3 tolerance for exact topological connection within the same B-Rep wire
                            if distance(lastPt, firstPt) < 1e-3 {
                                currentWireLoop.append(contentsOf: pts.dropFirst())
                            } else if distance(lastPt, endPt) < 1e-3 {
                                currentWireLoop.append(contentsOf: pts.reversed().dropFirst())
                            } else {
                                // Gap in the feature boundary (e.g., skipped a non-boundary edge)
                                partialLoops.append(currentWireLoop)
                                currentWireLoop = pts
                            }
                        }
                    }
                }
                if !currentWireLoop.isEmpty {
                    partialLoops.append(currentWireLoop)
                }
            }
        }

        // =================================================================================
        // SOTA: MACROSCOPIC FACE STITCHING
        // We only stitch the massive, pre-assembled wire segments across face boundaries.
        // =================================================================================
        let tubeLength = Float(stockInfo.length)
        // Stitch tolerance is set by tessellation density, not tube length.
        // STEPBridge uses GCPnts_UniformAbscissa at 1 mm spacing, so the maximum gap
        // between face-boundary wire endpoints from adjacent faces is ≤ 1 mm per side.
        // 2 mm (2× the discretization step) closes real face-boundary gaps without
        // accidentally merging endpoints from distinct nearby features.
        // stitchTolerance rationale: see ModelLoader.stitch(_:tolerance:) doc-comment.
        let loops = ModelLoader.stitch(partialLoops, tolerance: 2.0)

        // Map 3D loops to 2D (axial position, angular position) and classify as features.
        var featureId = 1
        // Axial endpoint tolerance follows the same logic as stitchTolerance: a sever-cut
        // loop reaches the tube end within one discretization step (1 mm). 2 mm gives a
        // 2× safety margin independent of tube length, preventing nearby-end notches from
        // being misclassified as sever cuts on long tubes.
        let axisTol: Float = 2.0

        for loop3D in loops {
            var pathPoints2D: [ToolpathPoint] = []
            var loopMinX = Float.greatestFiniteMagnitude, loopMaxX = -Float.greatestFiniteMagnitude

            for pos in loop3D {
                let axialProj = dot(pos - center, tubeAxis)
                let axial = axialProj + (tubeLength / 2.0)
                loopMinX = min(loopMinX, axial); loopMaxX = max(loopMaxX, axial)

                let centerProj = center + tubeAxis * axialProj
                let radialVec  = pos - centerProj
                let u  = dot(radialVec, uAxis)
                let vv = dot(radialVec, vAxis)
                var angle = atan2(Double(vv), Double(u)) * 180.0 / .pi
                if angle < 0 { angle += 360.0 }
                pathPoints2D.append(ToolpathPoint(x: CGFloat(axial), a: CGFloat(angle)))
            }

            var accumulatedAngle: CGFloat = 0.0
            for i in 0..<pathPoints2D.count {
                let currentA = pathPoints2D[i].a
                let nextA    = pathPoints2D[(i + 1) % pathPoints2D.count].a
                var diff = nextA - currentA
                while diff >  180.0 { diff -= 360.0 }
                while diff < -180.0 { diff += 360.0 }
                accumulatedAngle += diff
            }

            let isFullProfile = abs(accumulatedAngle) > 350.0
            let type = ModelLoader.featureType(
                loopMinX: loopMinX, loopMaxX: loopMaxX,
                tubeLength: tubeLength, isFullProfile: isFullProfile, axisTol: axisTol
            )

            let xCenter = CGFloat(loopMinX + loopMaxX) / 2.0
            let width   = CGFloat(loopMaxX - loopMinX)

            var unwrappedPath: [ToolpathPoint] = [pathPoints2D[0]]
            for i in 1..<pathPoints2D.count {
                var currentA = pathPoints2D[i].a
                let prevA    = unwrappedPath.last!.a
                while currentA - prevA >  180.0 { currentA -= 360.0 }
                while currentA - prevA < -180.0 { currentA += 360.0 }
                unwrappedPath.append(ToolpathPoint(x: pathPoints2D[i].x, a: currentA))
            }

            if type == .startCut || type == .endCut {
                unwrappedPath.sort { $0.a < $1.a }
                if let firstPt = unwrappedPath.first {
                    unwrappedPath.append(ToolpathPoint(x: firstPt.x, a: firstPt.a + 360.0))
                }
            }

            let sortedA = unwrappedPath.map { $0.a }.sorted()
            var aCenter = sortedA[sortedA.count / 2]
            while aCenter >= 360.0 { aCenter -= 360.0 }
            while aCenter < 0.0    { aCenter += 360.0 }

            let feature = GeometricFeature(
                id: featureId, type: type, shape: .rectangle,
                xCenter: xCenter, aCenterDeg: aCenter,
                dimensions: ["width": width], confidence: 1.0, rawPath: unwrappedPath
            )
            stockInfo.features.append(feature)
            featureId += 1
        }
    }
}
