import Foundation
import SceneKit
import simd

// MARK: - Objective-C Bridge Interface
class STEPBridgeWrapperSwift {
    static func parseSTEPToJSON(_ url: URL) -> String? {
        do { return try STEPBridgeWrapper.parseSTEP(toJSON: url) } catch {
            print("OCCT bridge error: \(error)")
            return nil
        }
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
    static func == (lhs: SelectedShape, rhs: SelectedShape) -> Bool {
        return lhs.node === rhs.node
    }
}

// MARK: - Stock Profile Types
enum StockProfile: String, Codable {
    case round = "HSS-O"
    case square = "HSS-Square"
    case rectangular = "HSS-Rect"
    case unknown = "UNKNOWN"
}

enum SurfaceFeatureType: String, Codable {
    case hole, notch, cutout, startCut, endCut
}
enum FeatureShape: String, Codable { case circle, rectangle, custom }

// MARK: - Core Data Models
struct CylinderDimensions: Codable {
    var diameter: CGFloat
    var height: CGFloat
}
struct BoxDimensions: Codable {
    var width: CGFloat
    var height: CGFloat
    var depth: CGFloat
}
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

    init(
        profile: StockProfile,
        od: CGFloat? = nil,
        odX: CGFloat? = nil,
        odY: CGFloat? = nil,
        length: CGFloat,
        axis: SIMD3<Float>,
        uAxis: SIMD3<Float>,
        origin: SIMD3<Float>
    ) {
        self.profile = profile
        self.od = od
        self.odX = odX
        self.odY = odY
        self.length = length
        self.axis = axis
        self.uAxis = uAxis
        self.origin = origin
    }
}

struct ToolpathPoint: Codable {
    var x: CGFloat
    var a: CGFloat
}

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
        if let d = try? container.decode(CylinderDimensions.self) {
            value = d
        } else if let b = try? container.decode(BoxDimensions.self) {
            value = b
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown dimension"
            )
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let d = value as? CylinderDimensions {
            try container.encode(d)
        } else if let b = value as? BoxDimensions {
            try container.encode(b)
        }
    }
}

// MARK: - Bulletproof JSON Extractors
private func getFloat(_ dict: [String: Any]?, _ key: String) -> Float {
    guard let dict = dict else { return 0.0 }
    if let d = dict[key] as? Double { return Float(d) }
    if let f = dict[key] as? Float { return f }
    if let n = dict[key] as? NSNumber { return n.floatValue }
    return 0.0
}

private func getInt(_ dict: [String: Any], _ key: String) -> Int {
    if let i = dict[key] as? Int { return i }
    if let n = dict[key] as? NSNumber { return n.intValue }
    return 0
}

private func getIntArray(_ anyArr: Any?) -> [Int] {
    if let arr = anyArr as? [Int] { return arr }
    if let arr = anyArr as? [NSNumber] { return arr.map { $0.intValue } }
    if let arr = anyArr as? [Double] { return arr.map { Int($0) } }
    return []
}

private func getIntMatrix(_ anyArr: Any?) -> [[Int]] {
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
            let parsed = try? JSONSerialization.jsonObject(
                with: jsonData,
                options: []
            ) as? [String: Any],
            let solids = parsed["solids"] as? [[String: Any]]
        else {
            return nil
        }

        var model = Model3D()
        model.url = url

        var allVertices: [SCNVector3] = []
        var tempNodes:
            [(node: SCNNode, mesh: Mesh3D, stockInfo: StockInfo?, solidId: Any)] =
                []

        for solidData in solids {
            if let (mesh, stockInfo) = try? parseSolidJSON(solidData) {
                allVertices.append(contentsOf: mesh.vertices)

                let geometry = SCNGeometry(
                    vertices: mesh.vertices,
                    faces: mesh.faces
                )
                let material = SCNMaterial()
                material.diffuse.contents = NSColor.lightGray
                material.isDoubleSided = true
                geometry.materials = [material]

                let node = SCNNode(geometry: geometry)
                let solidId = solidData["solidId"] ?? UUID().uuidString

                tempNodes.append(
                    (
                        node: node, mesh: mesh, stockInfo: stockInfo,
                        solidId: solidId
                    )
                )
            }
        }

        var globalMin = SCNVector3(
            Float.greatestFiniteMagnitude,
            Float.greatestFiniteMagnitude,
            Float.greatestFiniteMagnitude
        )
        var globalMax = SCNVector3(
            -Float.greatestFiniteMagnitude,
            -Float.greatestFiniteMagnitude,
            -Float.greatestFiniteMagnitude
        )

        for v in allVertices {
            globalMin.x = min(globalMin.x, v.x)
            globalMin.y = min(globalMin.y, v.y)
            globalMin.z = min(globalMin.z, v.z)
            globalMax.x = max(globalMax.x, v.x)
            globalMax.y = max(globalMax.y, v.y)
            globalMax.z = max(globalMax.z, v.z)
        }

        let globalCenter = SCNVector3(
            (globalMin.x + globalMax.x) / 2,
            (globalMin.y + globalMax.y) / 2,
            (globalMin.z + globalMax.z) / 2
        )

        for temp in tempNodes {
            temp.node.name = "model_solid_\(temp.solidId)"
            model.rootNode.addChildNode(temp.node)
            model.selectableShapes.append(
                SelectedShape(node: temp.node, shapeData: temp.mesh.shapeData)
            )
        }

        model.rootNode.position = SCNVector3(
            -globalCenter.x,
            -globalCenter.y,
            -globalCenter.z
        )
        return model
    }

    private static func parseSolidJSON(_ solid: [String: Any]) throws -> (
        Mesh3D, StockInfo?
    ) {
        let facesData = solid["faces"] as? [[String: Any]] ?? []

        // Build render mesh
        var renderVerts: [SCNVector3] = []
        var renderFaces: [[Int]] = []
        for f in facesData {
            let vArr = f["vertices"] as? [[String: Any]] ?? []
            let offset = renderVerts.count
            for v in vArr {
                renderVerts.append(
                    SCNVector3(
                        CGFloat(getFloat(v, "x")),
                        CGFloat(getFloat(v, "y")),
                        CGFloat(getFloat(v, "z"))
                    )
                )
            }
            for idxs in getIntMatrix(f["indices"]) {
                renderFaces.append(idxs.map { $0 + offset })
            }
        }

        // --- Step 1: Seed tube axis from PCA (direction-only fallback) ---
        // pcaAxis is kept immutable so it can be used as a stable reference in all later steps.
        let pca = solid["pca"] as? [String: Any]
        let rawPca = SIMD3<Float>(
            getFloat(pca, "axis3X"),
            getFloat(pca, "axis3Y"),
            getFloat(pca, "axis3Z")
        )
        let pcaAxis =
            length(rawPca) > 0.1 ? normalize(rawPca) : SIMD3<Float>(1, 0, 0)
        var tubeAxis = pcaAxis

        // --- Step 2: Cluster exact OCCT plane normals (rotation-invariant, no winding dependency) ---
        // WHY: We extract plane normals directly from the OpenCASCADE B-Rep geometry.
        // By clustering these normals, we find the dominant faces of a square or rectangular tube.
        // This method is robust against arbitrary stock orientation in the STEP file.
        var normalClusters: [(dir: SIMD3<Float>, weight: Int)] = []
        for f in facesData {
            guard let type = f["surface_type"] as? String, type == "PLANE",
                let pd = f["plane"] as? [String: Any]
            else { continue }
            let raw = SIMD3<Float>(
                getFloat(pd, "normalX"),
                getFloat(pd, "normalY"),
                getFloat(pd, "normalZ")
            )
            guard length(raw) > 0.5 else { continue }
            let n = normalize(raw)
            let w = (f["vertices"] as? [[String: Any]])?.count ?? 1
            var found = false
            for i in 0..<normalClusters.count {
                if abs(dot(normalClusters[i].dir, n)) > 0.95 {
                    normalClusters[i].weight += w
                    found = true
                    break
                }
            }
            if !found { normalClusters.append((dir: n, weight: w)) }
        }
        normalClusters.sort { $0.weight > $1.weight }

        // --- Step 3: Derive tube axis from perpendicular normal pairs ---
        var bestScore: Float = 0.0
        for i in 0..<normalClusters.count {
            for j in (i + 1)..<normalClusters.count {
                let n1 = normalClusters[i].dir
                let n2 = normalClusters[j].dir
                guard abs(dot(n1, n2)) < 0.15 else { continue }  // must be perpendicular
                let candidate = normalize(cross(n1, n2))
                let alignment = abs(dot(candidate, pcaAxis))  // always score against immutable PCA
                guard alignment > 0.95 else { continue }  // reject candidates >~18° from PCA
                let score =
                    Float(normalClusters[i].weight + normalClusters[j].weight)
                    * alignment
                if score > bestScore {
                    bestScore = score
                    tubeAxis =
                        dot(candidate, pcaAxis) >= 0 ? candidate : -candidate
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
                let cd = f["cylinder"] as? [String: Any]
            else { continue }
            let axis = normalize(
                SIMD3<Float>(
                    getFloat(cd, "axisX"),
                    getFloat(cd, "axisY"),
                    getFloat(cd, "axisZ")
                )
            )
            guard abs(dot(axis, tubeAxis)) > 0.9 else { continue }
            let verts = f["vertices"] as? [[String: Any]] ?? []
            guard verts.count >= 3 else { continue }

            // Build an orthonormal basis {u, v} perpendicular to the cylinder axis.
            let loc = SIMD3<Float>(
                getFloat(cd, "locationX"),
                getFloat(cd, "locationY"),
                getFloat(cd, "locationZ")
            )
            let arb: SIMD3<Float> =
                abs(axis.x) < 0.9
                ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
            let uVec = normalize(cross(axis, arb))
            let vVec = normalize(cross(axis, uVec))

            // Project each vertex onto the cross-section plane and compute its angle.
            let angles: [Float] = verts.map { vtx in
                let p =
                    SIMD3<Float>(
                        getFloat(vtx, "x"),
                        getFloat(vtx, "y"),
                        getFloat(vtx, "z")
                    ) - loc
                return atan2(dot(p, vVec), dot(p, uVec))
            }.sorted()

            // Largest gap between consecutive sorted angles (including wrap-around).
            var maxGap = angles[0] + 2 * .pi - angles[angles.count - 1]
            for i in 1..<angles.count {
                maxGap = max(maxGap, angles[i] - angles[i - 1])
            }
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
        let cornerRadius =
            filletRadii.isEmpty
            ? nil : filletRadii.reduce(0, +) / Float(filletRadii.count)

        // --- Step 5: Determine cross-section axes (uAxis / vAxis) ---
        let sideWallCandidates = normalClusters.filter {
            abs(dot($0.dir, tubeAxis)) < 0.2
        }
        let sideWallsWithPartners = sideWallCandidates.filter { c in
            sideWallCandidates.contains { other in
                abs(dot(c.dir, other.dir)) < 0.15
            }
        }

        let uAxis: SIMD3<Float>
        if let dominant = sideWallsWithPartners.first {
            uAxis = dominant.dir
        } else if let sideWall = sideWallCandidates.first {
            uAxis = sideWall.dir
        } else {
            let arb: SIMD3<Float> =
                abs(tubeAxis.x) > 0.9
                ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
            uAxis = normalize(cross(tubeAxis, arb))
        }
        let vAxis = normalize(cross(tubeAxis, uAxis))

        // --- Step 6: Extremum measurement over all mesh vertices ---
        var minX: Float = .greatestFiniteMagnitude
        var maxX: Float = -.greatestFiniteMagnitude
        var maxPosU: Float = -.greatestFiniteMagnitude
        var minNegU: Float = .greatestFiniteMagnitude
        var maxPosV: Float = -.greatestFiniteMagnitude
        var minNegV: Float = .greatestFiniteMagnitude

        for v in renderVerts {
            let p = SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
            let x = dot(p, tubeAxis)
            let u = dot(p, uAxis)
            let vv = dot(p, vAxis)
            minX = min(minX, x)
            maxX = max(maxX, x)
            maxPosU = max(maxPosU, u)
            minNegU = min(minNegU, u)
            maxPosV = max(maxPosV, vv)
            minNegV = min(minNegV, vv)
        }

        let trueLength = maxX - minX
        let trueWidth = maxPosU - minNegU
        let trueHeight = maxPosV - minNegV
        let trueCenter =
            tubeAxis * ((minX + maxX) / 2.0)
            + uAxis * ((maxPosU + minNegU) / 2.0)
            + vAxis * ((maxPosV + minNegV) / 2.0)

        let trueCrossMax = max(trueWidth, trueHeight)
        let trueCrossMin = min(trueWidth, trueHeight)

        // A cylinder spanning >180° indicates a round tube; fillets span ~90°
        let isRound = maxCylAngularSpan > .pi
        let isRectangular = !isRound && !sideWallCandidates.isEmpty

        // --- BUG FIX: Canonical Cross-Section Orientation ---
        // Force uAxis to ALWAYS align with the major (longest) cross-sectional dimension.
        // This makes orientation immune to arbitrary STEP tessellation weights.
        var outUAxis = uAxis
        var outVAxis = vAxis
        var outMaxPosU = maxPosU
        var outMinNegU = minNegU
        var outMaxPosV = maxPosV
        var outMinNegV = minNegV
        var outWidth = trueWidth

        if isRectangular && trueWidth < trueHeight {
            outUAxis = vAxis
            outVAxis = -uAxis  // Maintain right-handed coordinate system

            outMaxPosU = maxPosV
            outMinNegU = minNegV

            // Because new V = -old U, the extrema limits are inverted and negated
            outMaxPosV = -minNegU
            outMinNegV = -maxPosU

            outWidth = trueHeight
        }

        let profile: StockProfile
        if isRectangular {
            profile =
                abs(trueCrossMax - trueCrossMin) < 2.0 ? .square : .rectangular
        } else if isRound {
            profile = .round
        } else {
            profile = .round
        }

        let stockInfo = StockInfo(
            profile: profile,
            od: isRectangular ? nil : CGFloat(trueCrossMax),
            odX: isRectangular ? CGFloat(trueCrossMax) : nil,
            odY: isRectangular ? CGFloat(trueCrossMin) : nil,
            length: CGFloat(trueLength),
            axis: tubeAxis,
            uAxis: outUAxis,  // <-- Use the normalized axis
            origin: trueCenter
        )
        if isRectangular {
            stockInfo.uAxisDimension = CGFloat(outWidth)  // <-- Use the normalized width
            if let cr = cornerRadius {
                stockInfo.cornerRadius = CGFloat(cr)
            }
        }

        extractFeaturesFromTopology(
            facesData: facesData,
            renderVerts: renderVerts,
            tubeAxis: tubeAxis,
            uAxis: outUAxis,
            vAxis: outVAxis,
            center: trueCenter,
            maxPosU: outMaxPosU,
            minNegU: outMinNegU,
            maxPosV: outMaxPosV,
            minNegV: outMinNegV,
            stockInfo: stockInfo
        )

        let shapeData = ShapeData(
            type: isRectangular ? .box : .cylinder,
            dimensions: nil,
            isCuttable: true,
            stockInfo: stockInfo
        )
        return (
            Mesh3D(
                vertices: renderVerts,
                faces: renderFaces,
                shapeData: shapeData
            ), stockInfo
        )
    }

    // MARK: - Internal helpers (exposed for unit-testing threshold boundary conditions)

    /// Stitches an unordered collection of partial loops into complete feature loops by
    /// connecting segments whose endpoints are within `tolerance` mm of each other.
    ///
    /// Exposed `internal` so unit tests can drive it directly with synthetic data to verify
    /// the fixed stitchTolerance (2 mm) does not accidentally merge features that are
    /// 2–3 mm apart at face boundaries (bug 2 regression).
    internal static func stitch(
        _ partialLoops: [[SIMD3<Float>]],
        tolerance: Float
    ) -> [[SIMD3<Float>]] {
        var loops: [[SIMD3<Float>]] = []
        var unvisited = partialLoops
        while !unvisited.isEmpty {
            var current = unvisited.removeFirst()
            var added = true
            while added {
                added = false
                for (i, seg) in unvisited.enumerated() {
                    let s = current.first!
                    let e = current.last!
                    let es = seg.first!
                    let ee = seg.last!
                    if distance(e, es) < tolerance {
                        current.append(contentsOf: seg.dropFirst())
                        unvisited.remove(at: i)
                        added = true
                        break
                    } else if distance(e, ee) < tolerance {
                        current.append(contentsOf: seg.reversed().dropFirst())
                        unvisited.remove(at: i)
                        added = true
                        break
                    } else if distance(s, ee) < tolerance {
                        current.insert(contentsOf: seg.dropLast(), at: 0)
                        unvisited.remove(at: i)
                        added = true
                        break
                    } else if distance(s, es) < tolerance {
                        current.insert(
                            contentsOf: seg.reversed().dropLast(),
                            at: 0
                        )
                        unvisited.remove(at: i)
                        added = true
                        break
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
        loopMinX: Float,
        loopMaxX: Float,
        tubeLength: Float,
        isFullProfile: Bool,
        axisTol: Float
    ) -> SurfaceFeatureType {
        let touchesStart = loopMinX <= axisTol
        let touchesEnd = loopMaxX >= tubeLength - axisTol
        if isFullProfile && touchesStart { return .startCut }
        if isFullProfile && touchesEnd { return .endCut }
        // Complex end profiles: full 360° loop whose near edge is within complexEndTol
        // of a tube end, and whose entire extent stays within the first/last quarter of
        // the tube. Handles saddle-cut intersections where the shallowest point is a few
        // mm from the tube end but still clearly outside the tight axisTol margin.
        if isFullProfile {
            let complexEndTol: Float = max(axisTol * 5.0, 10.0)
            if loopMinX <= complexEndTol && loopMaxX < tubeLength * 0.25 {
                return .startCut
            }
            if loopMaxX >= tubeLength - complexEndTol
                && loopMinX > tubeLength * 0.75
            {
                return .endCut
            }
        }
        if touchesStart || touchesEnd { return .notch }
        return .cutout
    }

    // MARK: - AAG Feature Extractor (exact OCCT normals + centroid-based hull identification)
    private static func extractFeaturesFromTopology(
        facesData: [[String: Any]],
        renderVerts: [SCNVector3],
        tubeAxis: SIMD3<Float>,
        uAxis: SIMD3<Float>,
        vAxis: SIMD3<Float>,
        center: SIMD3<Float>,
        maxPosU: Float,
        minNegU: Float,
        maxPosV: Float,
        minNegV: Float,
        stockInfo: StockInfo
    ) {
        // A PLANE face is on the outer hull if its projection onto its own normal equals the
        // global maximum in that direction. OCCT's tessellation evaluates plane vertices
        // exactly (planes are linear), so they land within floating-point precision of maxD.
        // 0.5 mm (5× the 0.1 mm mesh deflection) gives ample numerical margin while staying
        // safely below any realistic wall thickness — ruling out inner faces on all standard
        // HSS grades (minimum EN 10219 / ASTM A500 wall thickness is 1.5 mm).
        // Identification of outer wall faces is based strictly on detected stock dimensions.
        // This ensures that intersecting features (like other tubes) are not misidentified
        // as part of the stock hull, even if they extend beyond the stock's dimensions.
        var outerWallFaceIDs = Set<Int>()
        let isRectangular =
            stockInfo.profile == .square || stockInfo.profile == .rectangular
        let stockR = Float((stockInfo.od ?? 0) / 2.0)

        // Identify outer hull faces using StockInfo as the absolute geometric reference.
        for face in facesData {
            let faceID = getInt(face, "faceID")
            guard let vArr = face["vertices"] as? [[String: Any]], !vArr.isEmpty
            else { continue }

            if let type = face["surface_type"] as? String {
                if type == "PLANE", let pd = face["plane"] as? [String: Any] {
                    let n = normalize(
                        SIMD3<Float>(
                            getFloat(pd, "normalX"),
                            getFloat(pd, "normalY"),
                            getFloat(pd, "normalZ")
                        )
                    )
                    // Plane must be parallel to the tube axis (normal perpendicular to axis)
                    guard length(n) > 0.5, abs(dot(n, tubeAxis)) < 0.15 else {
                        continue
                    }

                    if isRectangular {
                        // Outer PLANE faces lie at the mesh extremum in their normal direction.
                        // Use mesh-global maxD so this works regardless of StockInfo accuracy.
                        let fv = vArr[0]
                        let d = dot(
                            SIMD3<Float>(
                                getFloat(fv, "x"),
                                getFloat(fv, "y"),
                                getFloat(fv, "z")
                            ),
                            n
                        )
                        var maxD: Float = -.greatestFiniteMagnitude
                        for rv in renderVerts {
                            maxD = max(
                                maxD,
                                dot(
                                    SIMD3<Float>(
                                        Float(rv.x),
                                        Float(rv.y),
                                        Float(rv.z)
                                    ),
                                    n
                                )
                            )
                        }
                        let extremumTol: Float = 0.5
                        if d >= maxD - extremumTol {
                            outerWallFaceIDs.insert(faceID)
                        }
                    }
                } else if type == "CYLINDER",
                    let cyl = face["cylinder"] as? [String: Any]
                {
                    let cAxis = normalize(
                        SIMD3<Float>(
                            getFloat(cyl, "axisX"),
                            getFloat(cyl, "axisY"),
                            getFloat(cyl, "axisZ")
                        )
                    )
                    // Cylinder axis must be parallel to the tube axis
                    guard abs(dot(cAxis, tubeAxis)) > 0.95 else { continue }

                    let radius = getFloat(cyl, "radius")
                    let cLoc = SIMD3<Float>(
                        getFloat(cyl, "locationX"),
                        getFloat(cyl, "locationY"),
                        getFloat(cyl, "locationZ")
                    )
                    // Radial distance of the cylinder's axis from the tube's axis
                    let distFromAxis = length(
                        (cLoc - center) - tubeAxis
                            * dot(cLoc - center, tubeAxis)
                    )

                    if stockInfo.profile == .round {
                        // For round stock, the outer wall is the main cylinder itself (distFromAxis ~ 0)
                        if abs(radius - stockR) < 2.0 && distFromAxis < 2.0 {
                            outerWallFaceIDs.insert(faceID)
                        }
                    } else if isRectangular {
                        // For rectangular stock, include corner fillet cylinders whose arc
                        // reaches the hull boundary. Use mesh extrema so this works even
                        // when corner radius is not explicitly known (e.g., not in StockInfo).
                        let u = abs(dot(cLoc - center, uAxis))
                        let vv = abs(dot(cLoc - center, vAxis))
                        let halfU = (maxPosU - minNegU) / 2.0
                        let halfV = (maxPosV - minNegV) / 2.0
                        let cylTol: Float = 0.5
                        if u + radius >= halfU - cylTol
                            || vv + radius >= halfV - cylTol
                        {
                            outerWallFaceIDs.insert(faceID)
                        }
                    }
                }
            }
        }

        // =================================================================================
        // HYBRID WIRE EXTRACTION: TWO-PASS APPROACH
        //
        // The complete feature boundary for any cut consists of two kinds of edges:
        //
        //   Type A (outer-surface edges): shared between an outer wall face and a
        //   non-outer face.  These appear in outer wall face wires. Captured by Pass 1.
        //
        //   Type B (interior-closure edges): shared between a non-outer feature face
        //   (e.g. an intersecting pipe cylinder) and an end-cap plane.  These appear only
        //   in end-cap or feature-face wires — never in outer wall wires.  Needed when
        //   a saddle/cope cut profile closes through the tube interior rather than across
        //   the outer surface.  Captured by Pass 2.
        //
        // Simple sever cuts have only Type A edges → Pass 2 adds nothing.
        // Saddle/cope cuts that don't reach the opposite outer face have both types →
        // Pass 2 adds the interior closure so the profile loop can be stitched closed.
        // Holes, notches, cutouts that fully penetrate the wall have only Type A → unchanged.
        // =================================================================================

        // Classify non-outer faces into end caps vs feature faces.
        //
        // End caps: axial-normal PLANE faces (normal nearly parallel to tubeAxis).
        //
        // Feature faces: non-outer, non-end-cap faces that DIRECTLY TOUCH an outer wall face
        // (i.e., share at least one edge with a face in outerWallFaceIDs).
        //
        // WHY the adjacency check: hollow HSS stock has inner wall faces (inner flat panels +
        // inner corner fillet cylinders) that are neither outer walls nor end caps. Without
        // this check they fall into featureFaceIDs and cause pass 2 to spuriously collect the
        // inner-ring boundary of the annular end cap as a "feature" loop — producing garbled
        // rawPath geometry. Inner walls are separated from outer walls by the tube wall
        // thickness (≥ 1.5 mm for any standard HSS grade) and therefore never share an edge
        // with an outer wall face. Actual feature faces (the cutting pipe cylinder, notch
        // surfaces, hole cylinders) DO share edges with outer wall faces.
        var endCapFaceIDs = Set<Int>()
        var featureFaceIDs = Set<Int>()
        for face in facesData {
            let fid = getInt(face, "faceID")
            guard !outerWallFaceIDs.contains(fid) else { continue }
            var isEndCap = false
            if let type = face["surface_type"] as? String, type == "PLANE",
                let pd = face["plane"] as? [String: Any]
            {
                let raw = SIMD3<Float>(
                    getFloat(pd, "normalX"),
                    getFloat(pd, "normalY"),
                    getFloat(pd, "normalZ")
                )
                if length(raw) > 0.5
                    && abs(dot(normalize(raw), tubeAxis)) > 0.85
                {
                    isEndCap = true
                }
            }
            if isEndCap {
                // Require end cap to touch the outer wall, excluding internal notch-bottom
                // planes that have axial normals but are bounded only by notch side walls.
                // True sever end caps and complex end caps always share at least one edge
                // with the outer wall face at the tube perimeter.
                guard let capWires = face["wires"] as? [[String: Any]] else {
                    continue
                }
                var capTouchesOuter = false
                capSearch: for wire in capWires {
                    guard let edges = wire["edges"] as? [[String: Any]] else {
                        continue
                    }
                    for edge in edges {
                        let adjFaces = getIntArray(edge["adjacentFaceIDs"])
                        if adjFaces.contains(where: {
                            outerWallFaceIDs.contains($0)
                        }) {
                            capTouchesOuter = true
                            break capSearch
                        }
                    }
                }
                if capTouchesOuter { endCapFaceIDs.insert(fid) }
            } else {
                // Only treat as a feature face if it touches an outer wall face.
                guard let wires = face["wires"] as? [[String: Any]] else {
                    continue
                }
                var touchesOuterWall = false
                outerSearch: for wire in wires {
                    guard let edges = wire["edges"] as? [[String: Any]] else {
                        continue
                    }
                    for edge in edges {
                        let adjFaces = getIntArray(edge["adjacentFaceIDs"])
                        if adjFaces.contains(where: {
                            outerWallFaceIDs.contains($0)
                        }) {
                            touchesOuterWall = true
                            break outerSearch
                        }
                    }
                }
                if touchesOuterWall { featureFaceIDs.insert(fid) }
            }
        }

        var pass1PartialLoops: [[SIMD3<Float>]] = []
        var pass2PartialLoops: [[SIMD3<Float>]] = []

        // ── Pass 1: outer wall face wires ─────────────────────────────────────────
        // Collect Type A edges: edges shared between an outer wall face and any
        // non-outer face (end cap, feature face, or inner wall).
        //
        // Pass 1 and Pass 2 collect geometrically distinct edge sets:
        //   Pass 1: outer_wall ↔ end_cap  AND  outer_wall ↔ feature_face
        //   Pass 2: end_cap ↔ feature_face
        // These connect at shared topological vertices (where outer_wall, end_cap, and
        // feature_face all meet), forming the complete boundary without any duplication.
        for face in facesData {
            let faceID = getInt(face, "faceID")
            guard outerWallFaceIDs.contains(faceID),
                let wires = face["wires"] as? [[String: Any]]
            else { continue }

            for wire in wires {
                guard let edges = wire["edges"] as? [[String: Any]] else {
                    continue
                }

                var currentWireLoop: [SIMD3<Float>] = []

                for edge in edges {
                    let adjFaces = getIntArray(edge["adjacentFaceIDs"])
                    guard let pointsData = edge["points"] as? [[String: Any]],
                        !pointsData.isEmpty
                    else { continue }

                    let touchesInnerFace =
                        adjFaces.count >= 2
                        && adjFaces.contains { !outerWallFaceIDs.contains($0) }

                    if touchesInnerFace {
                        let pts = pointsData.map {
                            SIMD3<Float>(
                                getFloat($0, "x"),
                                getFloat($0, "y"),
                                getFloat($0, "z")
                            )
                        }

                        if currentWireLoop.isEmpty {
                            currentWireLoop.append(contentsOf: pts)
                        } else {
                            let lastPt = currentWireLoop.last!
                            if distance(lastPt, pts.first!) < 1e-3 {
                                currentWireLoop.append(
                                    contentsOf: pts.dropFirst()
                                )
                            } else if distance(lastPt, pts.last!) < 1e-3 {
                                currentWireLoop.append(
                                    contentsOf: pts.reversed().dropFirst()
                                )
                            } else {
                                pass1PartialLoops.append(currentWireLoop)
                                currentWireLoop = pts
                            }
                        }
                    }
                }
                if !currentWireLoop.isEmpty {
                    pass1PartialLoops.append(currentWireLoop)
                }
            }
        }

        // One-step extension of featureFaceIDs: faces directly adjacent to a primary
        // feature face (but not outer walls or end caps) are also treated as feature faces
        // for the purpose of Pass 2 collection.
        //
        // WHY: for HSS-O with a deep rectangular notch that penetrates the tube wall, the
        // inner cylinder is adjacent to the notch side walls (primary feature faces). Its
        // edge with the complex sever end cap is needed to close the feature loop across
        // the notch opening, but the inner cylinder is not a primary feature face (it does
        // not directly touch the outer cylinder).
        //
        // One step only (no transitive closure): inner flat walls of hollow HSS are never
        // adjacent to any primary feature face (separated by wall thickness), so they are
        // correctly excluded. A full transitive closure would pull in too many faces.
        var oneStepFeatureFaceIDs = featureFaceIDs
        for face in facesData {
            let fid = getInt(face, "faceID")
            guard !oneStepFeatureFaceIDs.contains(fid),
                !outerWallFaceIDs.contains(fid),
                !endCapFaceIDs.contains(fid),
                let wires = face["wires"] as? [[String: Any]]
            else { continue }
            extSearch: for wire in wires {
                guard let edges = wire["edges"] as? [[String: Any]] else {
                    continue
                }
                for edge in edges {
                    let adj = getIntArray(edge["adjacentFaceIDs"])
                    if adj.contains(where: { featureFaceIDs.contains($0) }) {
                        oneStepFeatureFaceIDs.insert(fid)
                        break extSearch
                    }
                }
            }
        }

        // ── Pass 2: end cap face wires ────────────────────────────────────────────
        // Collect Type B edges: edges on the OUTER wire of end-cap faces that are
        // adjacent to a feature face (primary or one-step extended).
        //
        // OUTER wire only (isInner=false): for a complex sever end cap (e.g. rectangular
        // notch cutting through the tube wall), the inner-wall arc that closes the notch
        // opening is on the outer wire. For a simple annular sever end cap the inner
        // circle is on the inner wire (isInner=true) and must not be collected.
        //
        // oneStepFeatureFaceIDs filter: collects round-tube cylinder arcs (HSS hook) and
        // inner-cylinder arcs when the notch penetrates the wall (HSS-O deep notch), while
        // excluding inner flat walls of hollow HSS that are never adjacent to feature faces.
        //
        // Only run when feature faces are present (harmless for simple sever cuts).
        if !featureFaceIDs.isEmpty {
            for face in facesData {
                let faceID = getInt(face, "faceID")
                guard endCapFaceIDs.contains(faceID),
                    let wires = face["wires"] as? [[String: Any]]
                else { continue }

                for wire in wires {
                    // Only process outer wires (isInner == false).
                    guard let isInnerWire = wire["isInner"] as? Bool,
                        !isInnerWire,
                        let edges = wire["edges"] as? [[String: Any]]
                    else { continue }

                    var currentWireLoop: [SIMD3<Float>] = []

                    for edge in edges {
                        let adjFaces = getIntArray(edge["adjacentFaceIDs"])
                        guard
                            let pointsData = edge["points"] as? [[String: Any]],
                            !pointsData.isEmpty
                        else { continue }

                        let touchesFeature = adjFaces.contains {
                            oneStepFeatureFaceIDs.contains($0)
                        }
                        guard touchesFeature else { continue }

                        let pts = pointsData.map {
                            SIMD3<Float>(
                                getFloat($0, "x"),
                                getFloat($0, "y"),
                                getFloat($0, "z")
                            )
                        }

                        if currentWireLoop.isEmpty {
                            currentWireLoop.append(contentsOf: pts)
                        } else {
                            let lastPt = currentWireLoop.last!
                            if distance(lastPt, pts.first!) < 1e-3 {
                                currentWireLoop.append(
                                    contentsOf: pts.dropFirst()
                                )
                            } else if distance(lastPt, pts.last!) < 1e-3 {
                                currentWireLoop.append(
                                    contentsOf: pts.reversed().dropFirst()
                                )
                            } else {
                                pass2PartialLoops.append(currentWireLoop)
                                currentWireLoop = pts
                            }
                        }
                    }
                    if !currentWireLoop.isEmpty {
                        pass2PartialLoops.append(currentWireLoop)
                    }
                }
            }
        }

        // =================================================================================
        // TWO-STAGE STITCHING
        //
        // Stage 1: stitch Pass 1 (outer-wall) edges alone.
        //   Any loop that already wraps 360° is a complete sever cut — lock it in and
        //   do NOT feed it to Stage 2.  This prevents the greedy stitcher from taking an
        //   inner-wall "shortcut" through a Pass 2 radial edge, which would bypass the
        //   notch on the outer surface and shatter the endCut into one endCut + two notches.
        //
        // Stage 2: stitch the open Pass 1 fragments together with Pass 2 (end-cap) edges.
        //   Open fragments (partial notch walls, saddle/cope profiles) need the Pass 2
        //   inner-closure arcs to become closed loops.
        // =================================================================================
        // =================================================================================
        // TWO-STAGE STITCHING
        // =================================================================================
        let tubeLength = Float(stockInfo.length)

        // ── Stage 1: Stitch Outer Boundaries ─────────────────────────────────────────────
        let pass1Stitched = ModelLoader.stitch(
            pass1PartialLoops,
            tolerance: 2.0
        )
        var finalLoops3D: [[SIMD3<Float>]] = []
        var openPass1Loops: [[SIMD3<Float>]] = []

        for loop in pass1Stitched {
            // A feature is geometrically closed if its stitched start and end points meet.
            // This is infinitely more robust than trying to calculate 3D angular wrap.
            if let first = loop.first, let last = loop.last,
                distance(first, last) < 2.0
            {
                finalLoops3D.append(loop)  // Complete sever cut, hole, or cutout — locked in.
            } else {
                openPass1Loops.append(loop)  // Open fragment — needs Pass 2 to close.
            }
        }

        // ── Stage 2: Resolve Open Features and Discard Ghosts ────────────────────────────
        if !openPass1Loops.isEmpty {
            let pass2Stitched = ModelLoader.stitch(
                openPass1Loops + pass2PartialLoops,
                tolerance: 2.0
            )

            for loop in pass2Stitched {
                // Ignore anything that didn't successfully close
                guard let first = loop.first, let last = loop.last,
                    distance(first, last) < 2.0
                else { continue }

                // CRITICAL FIX: Filter out Pass 2 "ghosts"
                // If an endCut was locked in Stage 1, its Pass 2 interior closure edges
                // are still floating around in pass2PartialLoops. Stage 2 will stitch them
                // into isolated rings on the inside of the tube.
                // A valid feature MUST contain at least one point from the Pass 1 outer boundary.
                var hasPass1Point = false
                checkPass1: for pt in loop {
                    for openLoop in openPass1Loops {
                        for openPt in openLoop {
                            if distance(pt, openPt) < 1e-3 {
                                hasPass1Point = true
                                break checkPass1
                            }
                        }
                    }
                }

                if hasPass1Point {
                    finalLoops3D.append(loop)
                }
            }
        }

        // Map 3D loops to 2D (axial position, angular position) and classify as features.
        var featureId = 1
        // Axial endpoint tolerance follows the same logic as stitchTolerance: a sever-cut
        // loop reaches the tube end within one discretization step (1 mm). 2 mm gives a
        // 2× safety margin independent of tube length, preventing nearby-end notches from
        // being misclassified as sever cuts on long tubes.
        let axisTol: Float = 2.0

        for loop3D in finalLoops3D {
            var pathPoints2D: [ToolpathPoint] = []
            var loopMinX = Float.greatestFiniteMagnitude
            var loopMaxX = -Float.greatestFiniteMagnitude

            for pos in loop3D {
                let axialProj = dot(pos - center, tubeAxis)
                let axial = axialProj + (tubeLength / 2.0)
                loopMinX = min(loopMinX, axial)
                loopMaxX = max(loopMaxX, axial)

                let centerProj = center + tubeAxis * axialProj
                let radialVec = pos - centerProj
                let u = dot(radialVec, uAxis)
                let vv = dot(radialVec, vAxis)
                var angle = atan2(Double(vv), Double(u)) * 180.0 / .pi
                if angle < 0 { angle += 360.0 }
                pathPoints2D.append(
                    ToolpathPoint(x: CGFloat(axial), a: CGFloat(angle))
                )
            }

            var accumulatedAngle: CGFloat = 0.0
            for i in 0..<pathPoints2D.count {
                let currentA = pathPoints2D[i].a
                let nextA = pathPoints2D[(i + 1) % pathPoints2D.count].a
                var diff = nextA - currentA
                while diff > 180.0 { diff -= 360.0 }
                while diff < -180.0 { diff += 360.0 }
                accumulatedAngle += diff
            }

            let isFullProfile = abs(accumulatedAngle) > 350.0
            let type = ModelLoader.featureType(
                loopMinX: loopMinX,
                loopMaxX: loopMaxX,
                tubeLength: tubeLength,
                isFullProfile: isFullProfile,
                axisTol: axisTol
            )

            let xCenter = CGFloat(loopMinX + loopMaxX) / 2.0
            let width = CGFloat(loopMaxX - loopMinX)

            var unwrappedPath: [ToolpathPoint] = [pathPoints2D[0]]
            for i in 1..<pathPoints2D.count {
                var currentA = pathPoints2D[i].a
                let prevA = unwrappedPath.last!.a
                while currentA - prevA > 180.0 { currentA -= 360.0 }
                while currentA - prevA < -180.0 { currentA += 360.0 }
                unwrappedPath.append(
                    ToolpathPoint(x: pathPoints2D[i].x, a: currentA)
                )
            }

            // Sever cuts (startCut/endCut): keep topological traversal order from the stitcher.
            // Sorting by A here would interleave points from the outer perimeter and the
            // interior closure at overlapping angular ranges (e.g. a hook-shaped sever),
            // producing zig-zag X motion. selectPiercePointSever() in ToolpathPlanner
            // handles reordering to the pierce point, A-continuity re-wrapping, and
            // appending the closing point — no preprocessing needed here.

            let sortedA = unwrappedPath.map { $0.a }.sorted()
            var aCenter = sortedA[sortedA.count / 2]
            while aCenter >= 360.0 { aCenter -= 360.0 }
            while aCenter < 0.0 { aCenter += 360.0 }

            let feature = GeometricFeature(
                id: featureId,
                type: type,
                shape: .rectangle,
                xCenter: xCenter,
                aCenterDeg: aCenter,
                dimensions: ["width": width],
                confidence: 1.0,
                rawPath: unwrappedPath
            )
            stockInfo.features.append(feature)
            featureId += 1
        }
    }
}
