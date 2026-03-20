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
fileprivate func getFloat(_ dict: [String: Any], _ key: String) -> Float {
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
        
        for solidData in solids {
            if let (mesh, stockInfo) = try? parseSolidJSON(solidData) {
                let geometry = SCNGeometry(vertices: mesh.vertices, faces: mesh.faces)
                let material = SCNMaterial()
                material.diffuse.contents = NSColor.lightGray
                material.isDoubleSided = true
                geometry.materials = [material]
                
                let node = SCNNode(geometry: geometry)
                let solidId = solidData["solidId"] ?? UUID().uuidString
                node.name = "model_solid_\(solidId)"
                
                // FIX: Center the node physically so SceneKit rotates it properly around 0,0,0
                if let stock = stockInfo {
                    node.pivot = SCNMatrix4MakeTranslation(CGFloat(stock.origin.x), CGFloat(stock.origin.y), CGFloat(stock.origin.z))
                    node.position = SCNVector3(0, 0, 0)
                }
                
                model.rootNode.addChildNode(node)
                model.selectableShapes.append(SelectedShape(node: node, shapeData: mesh.shapeData))
            }
        }
        return model
    }
    
    private static func parseSolidJSON(_ solid: [String: Any]) throws -> (Mesh3D, StockInfo?) {
        guard let bbox = solid["boundingBox"] as? [String: Any] else { throw NSError(domain: "Invalid BBox", code: 0) }
        
        let xMin = getFloat(bbox, "xMin"), xMax = getFloat(bbox, "xMax")
        let yMin = getFloat(bbox, "yMin"), yMax = getFloat(bbox, "yMax")
        let zMin = getFloat(bbox, "zMin"), zMax = getFloat(bbox, "zMax")
        
        var renderVerts: [SCNVector3] = []
        var renderFaces: [[Int]] = []
        var planeCount = 0
        
        var cylinderAxes: [SIMD3<Float>] = []
        
        if let facesData = solid["faces"] as? [[String: Any]] {
            for f in facesData {
                if let type = f["surface_type"] as? String {
                    if type == "PLANE" { planeCount += 1 }
                    // Harvest cylinder axes to find the true longitudinal direction
                    if type == "CYLINDER", let cyl = f["cylinder"] as? [String: Any] {
                        let ax = getFloat(cyl, "axisX"), ay = getFloat(cyl, "axisY"), az = getFloat(cyl, "axisZ")
                        let axis = normalize(SIMD3<Float>(ax, ay, az))
                        cylinderAxes.append(axis)
                    }
                }
                
                if let vArr = f["vertices"] as? [[String: Any]] {
                    let offset = renderVerts.count
                    for v in vArr {
                        renderVerts.append(SCNVector3(CGFloat(getFloat(v, "x")), CGFloat(getFloat(v, "y")), CGFloat(getFloat(v, "z"))))
                    }
                    let iArr = getIntMatrix(f["indices"])
                    for idxs in iArr { renderFaces.append(idxs.map { $0 + offset }) }
                }
            }
        }
        
        // FIX: TRUE AXIS ISOLATION
        let sizeX = xMax - xMin, sizeY = yMax - yMin, sizeZ = zMax - zMin
                
        // 1. Establish the dominant direction of the bounding box (highly reliable for tube length)
        var dominantDir = SIMD3<Float>(1, 0, 0)
        if sizeY >= sizeX && sizeY >= sizeZ { dominantDir = SIMD3<Float>(0, 1, 0) }
        else if sizeZ >= sizeX && sizeZ >= sizeY { dominantDir = SIMD3<Float>(0, 0, 1) }
        
        var tubeAxis = dominantDir
        
        // 2. Find the cylindrical face that aligns with this dominant direction
        if !cylinderAxes.isEmpty {
            var bestAxis = cylinderAxes[0]
            var maxDot: Float = -1.0
            
            for axis in cylinderAxes {
                let alignment = abs(dot(axis, dominantDir))
                if alignment > maxDot {
                    maxDot = alignment
                    bestAxis = axis
                }
            }
            
            // If the best alignment is roughly parallel to the longest side, use it.
            // This safely ignores cross-holes which will have a dot product near 0.
            if maxDot > 0.5 {
                tubeAxis = bestAxis
            }
        }
        
        let normalizedAxis = normalize(tubeAxis)
        var tempUp = SIMD3<Float>(0, 1, 0)
        if abs(normalizedAxis.y) > 0.9 { tempUp = SIMD3<Float>(1, 0, 0) }
        let uVec = normalize(cross(tempUp, normalizedAxis))
        let vVec = normalize(cross(normalizedAxis, uVec))
        
        // Compute precise bounding box independent of AABB rotation
        var minA = Float.greatestFiniteMagnitude, maxA = -Float.greatestFiniteMagnitude
        var minU = Float.greatestFiniteMagnitude, maxU = -Float.greatestFiniteMagnitude
        var minV = Float.greatestFiniteMagnitude, maxV = -Float.greatestFiniteMagnitude
        
        for v in renderVerts {
            let pos = SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
            let a = dot(pos, normalizedAxis), u = dot(pos, uVec), vPos = dot(pos, vVec)
            if a < minA { minA = a }; if a > maxA { maxA = a }
            if u < minU { minU = u }; if u > maxU { maxU = u }
            if vPos < minV { minV = vPos }; if vPos > maxV { maxV = vPos }
        }
        
        let trueLength = maxA - minA
        let trueWidth = maxU - minU
        let trueHeight = maxV - minV
        let trueCrossMax = max(trueWidth, trueHeight)
        let trueCrossMin = min(trueWidth, trueHeight)
        
        let center = SIMD3<Float>((xMin + xMax)/2, (yMin + yMax)/2, (zMin + zMax)/2)
        let isRectangular = planeCount >= 4
        let profile: StockProfile = isRectangular ? (abs(trueCrossMax - trueCrossMin) < 2.0 ? .square : .rectangular) : .round
        
        let stockInfo = StockInfo(
            profile: profile,
            od: isRectangular ? nil : CGFloat(trueCrossMax),
            odX: isRectangular ? CGFloat(trueCrossMax) : nil,
            odY: isRectangular ? CGFloat(trueCrossMin) : nil,
            length: CGFloat(trueLength),
            axis: normalizedAxis,
            origin: center // Anchor geometry logic strictly around the physical center
        )
        
        if let facesData = solid["faces"] as? [[String: Any]] {
            extractFeaturesFromTopology(facesData: facesData, axis: normalizedAxis, center: center, stockInfo: stockInfo)
        }

        let shapeData = ShapeData(type: isRectangular ? .box : .cylinder, dimensions: nil, isCuttable: true, stockInfo: stockInfo)
        return (Mesh3D(vertices: renderVerts, faces: renderFaces, shapeData: shapeData), stockInfo)
    }

    private static func extractFeaturesFromTopology(facesData: [[String: Any]], axis: SIMD3<Float>, center: SIMD3<Float>, stockInfo: StockInfo) {
        
        let normalizedAxis = normalize(axis)
        var tempUp = SIMD3<Float>(0, 1, 0)
        if abs(normalizedAxis.y) > 0.9 { tempUp = SIMD3<Float>(1, 0, 0) }
        let uVec = normalize(cross(tempUp, normalizedAxis))
        let vVec = normalize(cross(normalizedAxis, uVec))
        
        let radiusX = Float(stockInfo.odX ?? stockInfo.od ?? 0) / 2.0
        let radiusY = Float(stockInfo.odY ?? stockInfo.od ?? 0) / 2.0
        
        // 1. Analytical B-Rep Outer Wall Classifier
        var outerWallFaceIDs = Set<Int>()
        
        for face in facesData {
            let faceID = getInt(face, "faceID")
            guard let surfaceType = face["surface_type"] as? String else { continue }
            
            if surfaceType == "PLANE" {
                if let plane = face["plane"] as? [String: Any] {
                    let normal = normalize(SIMD3<Float>(getFloat(plane, "normalX"), getFloat(plane, "normalY"), getFloat(plane, "normalZ")))
                    
                    if abs(dot(normal, normalizedAxis)) < 0.1 { // Parallel to tube axis
                        let location = SIMD3<Float>(getFloat(plane, "locationX"), getFloat(plane, "locationY"), getFloat(plane, "locationZ"))
                        let maxDist = abs(dot(normal, uVec)) * radiusX + abs(dot(normal, vVec)) * radiusY
                        let actualDist = abs(dot(location - center, normal))
                        
                        if actualDist > maxDist - 1.0 { outerWallFaceIDs.insert(faceID) }
                    }
                }
            } else if surfaceType == "CYLINDER" {
                if let cyl = face["cylinder"] as? [String: Any] {
                    let axisDir = normalize(SIMD3<Float>(getFloat(cyl, "axisX"), getFloat(cyl, "axisY"), getFloat(cyl, "axisZ")))
                    let radius = getFloat(cyl, "radius")
                    
                    if abs(dot(axisDir, normalizedAxis)) > 0.9 {
                        if stockInfo.profile == .round {
                            if radius > radiusX - 1.0 { outerWallFaceIDs.insert(faceID) }
                        } else {
                            // FIX: Rectangular tubes have both inner and outer corners.
                            // Isolate the outer corners by checking distance to bounding box edge.
                            let cylLoc = SIMD3<Float>(getFloat(cyl, "locationX"), getFloat(cyl, "locationY"), getFloat(cyl, "locationZ"))
                            let u = dot(cylLoc - center, uVec)
                            let v = dot(cylLoc - center, vVec)
                            
                            // If the extreme edge of this cylinder is within 2mm of the bounding box edge, it's an outer corner
                            if (abs(u) + radius) > Float(radiusX) - 2.0 && (abs(v) + radius) > Float(radiusY) - 2.0 {
                                outerWallFaceIDs.insert(faceID)
                            }
                        }
                    }
                }
            }
        }
        
        // 2. Extract Bridging Cut Edges
        struct CutEdge { var points: [SIMD3<Float>] }
        var rawCutEdges: [CutEdge] = []
        
        for face in facesData {
            let faceID = getInt(face, "faceID")
            guard outerWallFaceIDs.contains(faceID), let wires = face["wires"] as? [[String: Any]] else { continue }
            
            for wire in wires {
                guard let edges = wire["edges"] as? [[String: Any]] else { continue }
                for edge in edges {
                    let adjFaces = getIntArray(edge["adjacentFaceIDs"])
                    guard let pointsData = edge["points"] as? [[String: Any]], !pointsData.isEmpty else { continue }
                    
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
        
        // 4. Process Loops into Toolpaths
        var featureId = 1
        // Zero the axial machine coordinates to the lowest edge of the stock
        var minAxialExtents = Float.greatestFiniteMagnitude
        for loop3D in loops {
            for pos in loop3D { minAxialExtents = min(minAxialExtents, dot(pos, normalizedAxis)) }
        }
        
        let tubeLength = Float(stockInfo.length)
        
        for loop3D in loops {
            var pathPoints2D: [ToolpathPoint] = []
            var loopMinX = Float.greatestFiniteMagnitude, loopMaxX = -Float.greatestFiniteMagnitude
            var loopMinU = Float.greatestFiniteMagnitude, loopMaxU = -Float.greatestFiniteMagnitude
            var loopMinV = Float.greatestFiniteMagnitude, loopMaxV = -Float.greatestFiniteMagnitude
            
            for pos in loop3D {
                let axial = dot(pos, normalizedAxis) - minAxialExtents
                loopMinX = min(loopMinX, axial); loopMaxX = max(loopMaxX, axial)
                
                let centerProj = center + normalizedAxis * dot(pos - center, normalizedAxis)
                let radialVec = pos - centerProj
                let u = dot(radialVec, uVec)
                let v = dot(radialVec, vVec)
                
                loopMinU = min(loopMinU, u); loopMaxU = max(loopMaxU, u)
                loopMinV = min(loopMinV, v); loopMaxV = max(loopMaxV, v)
                
                var angle = atan2(Double(v), Double(u)) * 180.0 / .pi
                if angle < 0 { angle += 360.0 }
                
                pathPoints2D.append(ToolpathPoint(x: CGFloat(axial), a: CGFloat(angle)))
            }
            
            let sortedAngles = pathPoints2D.map { $0.a }.sorted()
            var maxGap: CGFloat = 0
            for i in 0..<sortedAngles.count {
                var gap = sortedAngles[(i + 1) % sortedAngles.count] - sortedAngles[i]
                if gap < 0 { gap += 360.0 }
                if gap > maxGap { maxGap = gap }
            }
            
            let heightDeg = 360.0 - maxGap
            var aCenter = sortedAngles.first!
            for i in 0..<sortedAngles.count {
                var gap = sortedAngles[(i + 1) % sortedAngles.count] - sortedAngles[i]
                if gap < 0 { gap += 360.0 }
                if gap == maxGap {
                    aCenter = sortedAngles[(i + 1) % sortedAngles.count] + heightDeg / 2.0
                    if aCenter >= 360.0 { aCenter -= 360.0 }
                    break
                }
            }
            
            let xCenter = CGFloat(loopMinX + loopMaxX) / 2.0
            let width = CGFloat(loopMaxX - loopMinX)
            
            let touchesStart = loopMinX <= 3.0
            let touchesEnd = loopMaxX >= tubeLength - 3.0
            
            // FIX: Robust Full Profile detection (handles missing vertices on flat rectangular faces)
            // A profile is "Full" if it physically closes on itself AND spans the width/height of the tube.
            let isClosed = distance(loop3D.first!, loop3D.last!) < 5.0
            let spansU = (loopMaxU - loopMinU) > (Float(radiusX) * 1.5)
            let spansV = (loopMaxV - loopMinV) > (Float(radiusY) * 1.5)
            let isFullProfile = isClosed && spansU && spansV
            
            var type: SurfaceFeatureType
            if isFullProfile && touchesStart { type = .startCut }
            else if isFullProfile && touchesEnd { type = .endCut }
            else if touchesStart || touchesEnd { type = .notch }
            else { type = .cutout }
            
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
                // Ensure the path closes exactly a full 360 degrees from the start point
                if let firstPt = unwrappedPath.first {
                    unwrappedPath.append(ToolpathPoint(x: firstPt.x, a: firstPt.a + 360.0))
                }
            }
            
            var dimensions: [String: CGFloat] = ["width": width, "angle": heightDeg]
            let transverseWidth = CGFloat(max(loopMaxU - loopMinU, loopMaxV - loopMinV))
            if type == .cutout && abs(width - transverseWidth) < 5.0 {
                type = .hole
                dimensions["diameter"] = width
            }
            
            let feature = SurfaceFeature(id: featureId, type: type, shape: .rectangle, xCenter: xCenter, aCenterDeg: aCenter, dimensions: dimensions, confidence: 1.0, path: unwrappedPath)
            stockInfo.features.append(feature)
            featureId += 1
        }
    }
}
