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
    var length: CGFloat
    var axis: SIMD3<Float>
    var origin: SIMD3<Float>
    var features: [SurfaceFeature] = []
    
    init(profile: StockProfile, od: CGFloat? = nil, odX: CGFloat? = nil, odY: CGFloat? = nil, length: CGFloat, axis: SIMD3<Float>, origin: SIMD3<Float>) {
        self.profile = profile; self.od = od; self.odX = odX; self.odY = odY; self.length = length; self.axis = axis; self.origin = origin
    }
}

struct ToolpathPoint: Codable { var x: CGFloat; var a: CGFloat }

struct SurfaceFeature: Codable, Identifiable {
    var id: Int
    var type: SurfaceFeatureType
    var shape: FeatureShape
    var xCenter: CGFloat
    var aCenterDeg: CGFloat
    var dimensions: [String: CGFloat]
    var confidence: Float
    var path: [ToolpathPoint]?
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
        let pca = solid["pca"] as? [String: Any]
        var pcaAxis3 = SIMD3<Float>(getFloat(pca, "axis3X"), getFloat(pca, "axis3Y"), getFloat(pca, "axis3Z"))
        
        // Failsafe in case PCA yields singular matrix
        if length(pcaAxis3) < 0.1 { pcaAxis3 = SIMD3<Float>(1, 0, 0) }
        let tubeAxis = normalize(pcaAxis3)
        
        var renderVerts: [SCNVector3] = []
        var renderFaces: [[Int]] = []
        var planarNormals: [(dir: SIMD3<Float>, weight: Int)] = []
        var planeCount = 0
        
        if let facesData = solid["faces"] as? [[String: Any]] {
            for f in facesData {
                let vArr = f["vertices"] as? [[String: Any]] ?? []
                
                if let type = f["surface_type"] as? String, type == "PLANE" {
                    planeCount += 1
                    if let trueNormal = calculateTrueNormal(vertices: vArr) {
                        // Filter out end caps - only keep longitudinal planes
                        if abs(dot(trueNormal, tubeAxis)) < 0.1 {
                            var matched = false
                            for i in 0..<planarNormals.count {
                                if abs(dot(planarNormals[i].dir, trueNormal)) > 0.98 {
                                    planarNormals[i].weight += vArr.count
                                    matched = true
                                    break
                                }
                            }
                            if !matched { planarNormals.append((dir: trueNormal, weight: vArr.count)) }
                        }
                    }
                }
                
                let offset = renderVerts.count
                for v in vArr {
                    renderVerts.append(SCNVector3(CGFloat(getFloat(v, "x")), CGFloat(getFloat(v, "y")), CGFloat(getFloat(v, "z"))))
                }
                let iArr = getIntMatrix(f["indices"])
                for idxs in iArr { renderFaces.append(idxs.map { $0 + offset }) }
            }
        }
        
        // Determine Cross-Section U and V axes from PCA + Normal Clustering
        planarNormals.sort { $0.weight > $1.weight }
        let uAxis = planarNormals.isEmpty ? normalize(cross(tubeAxis, abs(tubeAxis.x) > 0.9 ? SIMD3<Float>(0,1,0) : SIMD3<Float>(1,0,0))) : planarNormals[0].dir
        let vAxis = normalize(cross(tubeAxis, uAxis))
        
        // Extremum Limits (Immune to PCA Center-of-Mass shift)
        var minX: Float = 100000, maxX: Float = -100000
        var maxPosU: Float = -100000, minNegU: Float = 100000
        var maxPosV: Float = -100000, minNegV: Float = 100000
        
        for v in renderVerts {
            let p = SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
            let x = dot(p, tubeAxis)
            let u = dot(p, uAxis)
            let v_val = dot(p, vAxis)
            
            minX = min(minX, x); maxX = max(maxX, x)
            maxPosU = max(maxPosU, u); minNegU = min(minNegU, u)
            maxPosV = max(maxPosV, v_val); minNegV = min(minNegV, v_val)
        }
        
        let trueLength = maxX - minX
        let trueWidth = maxPosU - minNegU
        let trueHeight = maxPosV - minNegV
        
        // Exact Geometric centerline of uncut bounding box
        let trueCenter = tubeAxis * ((minX + maxX) / 2.0) +
                         uAxis * ((maxPosU + minNegU) / 2.0) +
                         vAxis * ((maxPosV + minNegV) / 2.0)
        
        let trueCrossMax = max(trueWidth, trueHeight)
        let trueCrossMin = min(trueWidth, trueHeight)
        let isRectangular = planeCount >= 4
        let profile: StockProfile = isRectangular ? (abs(trueCrossMax - trueCrossMin) < 2.0 ? .square : .rectangular) : .round
        
        let stockInfo = StockInfo(
            profile: profile,
            od: isRectangular ? nil : CGFloat(trueCrossMax),
            odX: isRectangular ? CGFloat(trueCrossMax) : nil,
            odY: isRectangular ? CGFloat(trueCrossMin) : nil,
            length: CGFloat(trueLength),
            axis: tubeAxis,
            origin: trueCenter
        )
        
        if let facesData = solid["faces"] as? [[String: Any]] {
            extractFeaturesFromTopology(
                facesData: facesData, tubeAxis: tubeAxis, uAxis: uAxis, vAxis: vAxis,
                center: trueCenter, maxPosU: maxPosU, minNegU: minNegU, maxPosV: maxPosV, minNegV: minNegV,
                stockInfo: stockInfo
            )
        }

        let shapeData = ShapeData(type: isRectangular ? .box : .cylinder, dimensions: nil, isCuttable: true, stockInfo: stockInfo)
        return (Mesh3D(vertices: renderVerts, faces: renderFaces, shapeData: shapeData), stockInfo)
    }

    // MARK: - AAG + PCA Feature Extractor
    private static func extractFeaturesFromTopology(
        facesData: [[String: Any]], tubeAxis: SIMD3<Float>, uAxis: SIMD3<Float>, vAxis: SIMD3<Float>,
        center: SIMD3<Float>, maxPosU: Float, minNegU: Float, maxPosV: Float, minNegV: Float, stockInfo: StockInfo
    ) {
        var outerWallFaceIDs = Set<Int>()
        
        // 1. Identify the Outer Hull mathematically using Extremum Verification
        for face in facesData {
            let faceID = getInt(face, "faceID")
            guard let vArr = face["vertices"] as? [[String: Any]], !vArr.isEmpty else { continue }
            
            if let type = face["surface_type"] as? String {
                if type == "PLANE" {
                    guard let trueNormal = calculateTrueNormal(vertices: vArr) else { continue }
                    
                    // Outer walls MUST run along the extrusion axis
                    if abs(dot(trueNormal, tubeAxis)) > 0.1 { continue }
                    
                    let p = SIMD3<Float>(getFloat(vArr[0], "x"), getFloat(vArr[0], "y"), getFloat(vArr[0], "z"))
                    let u = dot(p, uAxis)
                    let v_val = dot(p, vAxis)
                    
                    // If normal aligns with +U or -U, verify its extremity
                    if abs(dot(trueNormal, uAxis)) > 0.9 {
                        if abs(u - maxPosU) < 1.0 || abs(u - minNegU) < 1.0 { outerWallFaceIDs.insert(faceID) }
                    }
                    // If normal aligns with +V or -V
                    else if abs(dot(trueNormal, vAxis)) > 0.9 {
                        if abs(v_val - maxPosV) < 1.0 || abs(v_val - minNegV) < 1.0 { outerWallFaceIDs.insert(faceID) }
                    }
                }
                else if type == "CYLINDER", let cyl = face["cylinder"] as? [String: Any] {
                    let cAxis = normalize(SIMD3<Float>(getFloat(cyl, "axisX"), getFloat(cyl, "axisY"), getFloat(cyl, "axisZ")))
                    // Fillets and outer round hulls are strictly longitudinal
                    if abs(dot(cAxis, tubeAxis)) > 0.9 {
                        let cLoc = SIMD3<Float>(getFloat(cyl, "locationX"), getFloat(cyl, "locationY"), getFloat(cyl, "locationZ"))
                        let radius = getFloat(cyl, "radius")
                        
                        // Distance from tube center plus radius. Verifies if it's sitting on the bounding limit
                        let u = abs(dot(cLoc - center, uAxis))
                        let v_val = abs(dot(cLoc - center, vAxis))
                        if u + radius >= abs(maxPosU) - 1.0 || v_val + radius >= abs(maxPosV) - 1.0 {
                            outerWallFaceIDs.insert(faceID)
                        }
                    }
                }
            }
        }
        
        // 2. AAG Topology Edge Traversal (Bridging)
        struct CutEdge { var points: [SIMD3<Float>] }
        var rawCutEdges: [CutEdge] = []
        
        for face in facesData {
            let faceID = getInt(face, "faceID")
            // Iterate outward from the confirmed Outer Hull
            guard outerWallFaceIDs.contains(faceID), let wires = face["wires"] as? [[String: Any]] else { continue }
            
            for wire in wires {
                guard let edges = wire["edges"] as? [[String: Any]] else { continue }
                for edge in edges {
                    let adjFaces = getIntArray(edge["adjacentFaceIDs"])
                    guard let pointsData = edge["points"] as? [[String: Any]], !pointsData.isEmpty else { continue }
                    
                    // AAG Core Logic: An edge is a feature boundary if it connects an Outer Hull to an Inner Cut Wall
                    // (Or if it connects to nothing, which represents an open notch or start/end cut)
                    let touchesInnerWall = adjFaces.contains { !outerWallFaceIDs.contains($0) } || adjFaces.count == 1
                    
                    if touchesInnerWall {
                        var pts: [SIMD3<Float>] = []
                        for p in pointsData { pts.append(SIMD3<Float>(getFloat(p, "x"), getFloat(p, "y"), getFloat(p, "z"))) }
                        rawCutEdges.append(CutEdge(points: pts))
                    }
                }
            }
        }
        
        // 3. Chain Edges into Closed Loops
        var loops: [[SIMD3<Float>]] = []
        var unvisited = rawCutEdges
        let stitchTolerance: Float = 2.5
        
        while !unvisited.isEmpty {
            var currentLoop = unvisited.removeFirst().points
            var added = true
            
            while added {
                added = false
                for (i, edge) in unvisited.enumerated() {
                    let loopStart = currentLoop.first!, loopEnd = currentLoop.last!
                    let edgeStart = edge.points.first!, edgeEnd = edge.points.last!
                    
                    if distance(loopEnd, edgeStart) < stitchTolerance {
                        currentLoop.append(contentsOf: edge.points.dropFirst())
                        unvisited.remove(at: i); added = true; break
                    } else if distance(loopEnd, edgeEnd) < stitchTolerance {
                        currentLoop.append(contentsOf: edge.points.reversed().dropFirst())
                        unvisited.remove(at: i); added = true; break
                    } else if distance(loopStart, edgeEnd) < stitchTolerance {
                        currentLoop.insert(contentsOf: edge.points.dropLast(), at: 0)
                        unvisited.remove(at: i); added = true; break
                    } else if distance(loopStart, edgeStart) < stitchTolerance {
                        currentLoop.insert(contentsOf: edge.points.reversed().dropLast(), at: 0)
                        unvisited.remove(at: i); added = true; break
                    }
                }
            }
            if currentLoop.count > 5 { loops.append(currentLoop) }
        }
        
        // 4. Wrap to 2D Domain & Build Features
        var featureId = 1
        let tubeLength = Float(stockInfo.length)
        
        for loop3D in loops {
            var pathPoints2D: [ToolpathPoint] = []
            var loopMinX = Float.greatestFiniteMagnitude, loopMaxX = -Float.greatestFiniteMagnitude
            
            for pos in loop3D {
                // Determine absolute axial position anchored strictly by the PCA geometric center
                let axialProj = dot(pos - center, tubeAxis)
                let axial = axialProj + (tubeLength / 2.0)
                
                loopMinX = min(loopMinX, axial); loopMaxX = max(loopMaxX, axial)
                
                let centerProj = center + tubeAxis * axialProj
                let radialVec = pos - centerProj
                let u = dot(radialVec, uAxis)
                let v_val = dot(radialVec, vAxis)
                
                var angle = atan2(Double(v_val), Double(u)) * 180.0 / .pi
                if angle < 0 { angle += 360.0 }
                
                pathPoints2D.append(ToolpathPoint(x: CGFloat(axial), a: CGFloat(angle)))
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
            let touchesStart = loopMinX <= 3.0
            let touchesEnd = loopMaxX >= tubeLength - 3.0
            
            var type: SurfaceFeatureType
            if isFullProfile && touchesStart { type = .startCut }
            else if isFullProfile && touchesEnd { type = .endCut }
            else if touchesStart || touchesEnd { type = .notch }
            else { type = .cutout }
            
            let xCenter = CGFloat(loopMinX + loopMaxX) / 2.0
            let width = CGFloat(loopMaxX - loopMinX)
            
            var unwrappedPath: [ToolpathPoint] = [pathPoints2D[0]]
            for i in 1..<pathPoints2D.count {
                var currentA = pathPoints2D[i].a
                let prevA = unwrappedPath.last!.a
                while currentA - prevA > 180.0 { currentA -= 360.0 }
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
            while aCenter < 0.0 { aCenter += 360.0 }
            
            let feature = SurfaceFeature(id: featureId, type: type, shape: .rectangle, xCenter: xCenter, aCenterDeg: aCenter, dimensions: ["width": width], confidence: 1.0, path: unwrappedPath)
            stockInfo.features.append(feature)
            featureId += 1
        }
    }
    
    // MARK: - World Space Normal Extractor
    private static func calculateTrueNormal(vertices: [[String: Any]]) -> SIMD3<Float>? {
        guard vertices.count >= 3 else { return nil }
        var nx: Float = 0, ny: Float = 0, nz: Float = 0
        
        for i in 0..<vertices.count {
            let curr = vertices[i]
            let next = vertices[(i + 1) % vertices.count]
            let cx = getFloat(curr, "x"), cy = getFloat(curr, "y"), cz = getFloat(curr, "z")
            let nx_v = getFloat(next, "x"), ny_v = getFloat(next, "y"), nz_v = getFloat(next, "z")
            
            nx += (cy - ny_v) * (cz + nz_v)
            ny += (cz - nz_v) * (cx + nx_v)
            nz += (cx - nx_v) * (cy + ny_v)
        }
        
        let len = sqrt(nx*nx + ny*ny + nz*nz)
        return len > 0.001 ? normalize(SIMD3<Float>(nx, ny, nz)) : nil
    }
}
