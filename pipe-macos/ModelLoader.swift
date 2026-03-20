import Foundation
import SceneKit

// MARK: - Objective-C Bridge Interface
/// Swift interface for the Objective-C STEPBridgeWrapper
/// Note: STEPBridgeWrapper must be imported via Bridging-Header.h
class STEPBridgeWrapperSwift {
    static func parseSTEPToJSON(_ url: URL) -> String? {
        // Call directly to Objective-C implementation
        // This requires STEPBridgeWrapper to be exposed via bridging header
        do {
            // Swift auto-renames parseSTEPToJSON: to parseSTEP(toJSON:)
            return try STEPBridgeWrapper.parseSTEP(toJSON: url)
        } catch let error as NSError {
            print("OCCT bridge error: \(error.localizedDescription)")
            return nil
        } catch {
            print("OCCT bridge error: \(error)")
            return nil
        }
    }
}

// MARK: - Stock Profile Types

/// Stock profile classification per KB specifications
enum StockProfile: String, Codable {
    case round = "HSS-O"           // Round/oval hollow structural section
    case square = "HSS-Square"     // Square hollow structural section
    case rectangular = "HSS-Rect"  // Rectangular hollow structural section
    case unknown = "UNKNOWN"
}

// MARK: - Shape Dimensions

/// Cylinder dimensions for shape classification
struct CylinderDimensions: Codable {
    var diameter: CGFloat
    var height: CGFloat
}

/// Box dimensions for shape classification
struct BoxDimensions: Codable {
    var width: CGFloat
    var height: CGFloat
    var depth: CGFloat
}

// MARK: - Selected Shape

/// Selected shape for G-code generation
class SelectedShape: Identifiable {
    var id: UUID
    var shapeType: String
    var dimensions: Any?
    var isCuttable: Bool
    weak var node: SCNNode?
    var stockInfo: StockInfo?
    
    init(id: UUID = UUID(), shapeType: String, dimensions: Any? = nil, 
         isCuttable: Bool = true, node: SCNNode? = nil, stockInfo: StockInfo? = nil) {
        self.id = id
        self.shapeType = shapeType
        self.dimensions = dimensions
        self.isCuttable = isCuttable
        self.node = node
        self.stockInfo = stockInfo
    }
}

/// End cut type classification
enum EndCutType: String, Codable {
    case square = "Square"
    case miter = "Miter"
    case compoundMiter = "Compound Miter"
    case custom = "Custom"
}

/// Surface feature type for cutouts, holes, notches, etc.
enum SurfaceFeatureType: String, Codable {
    case hole = "Hole"
    case notch = "Notch"
    //case cope = "Cope"
    //case scallop = "Scallop"
    case cutout = "Cutout"
    case startCut = "StartCut"
    case endCut     = "EndCut"
}

/// Feature shape classification
enum FeatureShape: String, Codable {
    case circle = "Circle"
    case rectangle = "Rectangle"
    case bspline = "BSpline"
    case compound = "Compound"
}

// MARK: - Stock Information Data Structures

/// End cut information with exact miter angles from B-Rep analysis
struct EndCutInfo: Codable {
    var type: EndCutType
    var miterAngleDeg: CGFloat       // Miter angle in degrees
    var miterDirectionDeg: CGFloat   // Direction of miter cut in degrees
    var xAtCenterline: CGFloat       // Position along tube axis
    
    init(type: EndCutType = .square, miterAngleDeg: CGFloat = 0, 
         miterDirectionDeg: CGFloat = 0, xAtCenterline: CGFloat = 0) {
        self.type = type
        self.miterAngleDeg = miterAngleDeg
        self.miterDirectionDeg = miterDirectionDeg
        self.xAtCenterline = xAtCenterline
    }
}

/// Surface feature extracted from B-Rep wire analysis
class SurfaceFeature: Codable, Identifiable {
    var id: Int
    var type: SurfaceFeatureType
    var shape: FeatureShape
    var xCenter: CGFloat           // Position along tube axis
    var aCenterDeg: CGFloat        // Angular position in degrees
    var dimensions: [String: CGFloat]  // Feature-specific dimensions
    var confidence: CGFloat        // Detection confidence (0.0-1.0)
    var end: String?               // "start" or "end" for end features
    var wirePoints: [CGPoint]?     // Sampled points for BSpline features
    var path: [ToolpathPoint] = []
    
    init(id: Int = 0, type: SurfaceFeatureType = .hole, shape: FeatureShape = .circle,
         xCenter: CGFloat = 0, aCenterDeg: CGFloat = 0, 
         dimensions: [String: CGFloat] = [:], confidence: CGFloat = 1.0,
         end: String? = nil, wirePoints: [CGPoint]? = nil) {
        self.id = id
        self.type = type
        self.shape = shape
        self.xCenter = xCenter
        self.aCenterDeg = aCenterDeg
        self.dimensions = dimensions
        self.confidence = confidence
        self.end = end
        self.wirePoints = wirePoints
    }
    
    /// Validate feature against stock constraints per KB Section 12
    func validate(stockInfo: StockInfo) -> (isValid: Bool, errors: [String]) {
        var errors: [String] = []
        
        // Check feature is within stock bounds
        if xCenter < 0 || xCenter > stockInfo.length {
            errors.append("Feature X position outside stock length")
        }
        
        // Check hole diameter vs stock diameter
        if type == .hole, let diameter = dimensions["diameter"] {
            if let stockOD = stockInfo.od {
                if diameter >= stockOD {
                    errors.append("Hole diameter exceeds stock OD")
                }
            }
        }
        
        return (errors.isEmpty, errors)
    }
    
    enum CodingKeys: CodingKey {
        case id, type, shape, xCenter, aCenterDeg, dimensions, confidence, end, wirePoints
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        type = try container.decode(SurfaceFeatureType.self, forKey: .type)
        shape = try container.decode(FeatureShape.self, forKey: .shape)
        xCenter = try container.decode(CGFloat.self, forKey: .xCenter)
        aCenterDeg = try container.decode(CGFloat.self, forKey: .aCenterDeg)
        dimensions = try container.decode([String: CGFloat].self, forKey: .dimensions)
        confidence = try container.decode(CGFloat.self, forKey: .confidence)
        end = try container.decodeIfPresent(String.self, forKey: .end)
        wirePoints = try container.decodeIfPresent([CGPoint].self, forKey: .wirePoints)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(shape, forKey: .shape)
        try container.encode(xCenter, forKey: .xCenter)
        try container.encode(aCenterDeg, forKey: .aCenterDeg)
        try container.encode(dimensions, forKey: .dimensions)
        try container.encode(confidence, forKey: .confidence)
        try container.encodeIfPresent(end, forKey: .end)
        try container.encodeIfPresent(wirePoints, forKey: .wirePoints)
    }
}

/// Complete stock information extracted from STEP B-Rep
class StockInfo: Codable, Identifiable {
    var id: UUID
    var profile: StockProfile
    var od: CGFloat?               // Outer diameter for round tubes
    var odX: CGFloat?              // Outer dimension X for rectangular tubes
    var odY: CGFloat?              // Outer dimension Y for rectangular tubes
    var length: CGFloat            // Total length along axis
    var axis: SIMD3<Float>         // Central axis vector
    var origin: SIMD3<Float>       // Origin point
    var startEndCut: EndCutInfo?   // Start end cut info
    var endEndCut: EndCutInfo?     // End end cut info
    var features: [SurfaceFeature] // Detected surface features
    var cornerFillets: [CornerFillet]? // Corner radii for rectangular tubes
    
    init(id: UUID = UUID(), profile: StockProfile = .unknown,
         od: CGFloat? = nil, odX: CGFloat? = nil, odY: CGFloat? = nil,
         length: CGFloat = 0, axis: SIMD3<Float> = SIMD3<Float>(0, 0, 1),
         origin: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
         startEndCut: EndCutInfo? = nil, endEndCut: EndCutInfo? = nil,
         features: [SurfaceFeature] = [], cornerFillets: [CornerFillet]? = nil) {
        self.id = id
        self.profile = profile
        self.od = od
        self.odX = odX
        self.odY = odY
        self.length = length
        self.axis = axis
        self.origin = origin
        self.startEndCut = startEndCut
        self.endEndCut = endEndCut
        self.features = features
        self.cornerFillets = cornerFillets
    }
    
    enum CodingKeys: CodingKey {
        case id, profile, od, odX, odY, length, axis, origin, startEndCut, endEndCut, features, cornerFillets
    }
    
    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        profile = try container.decode(StockProfile.self, forKey: .profile)
        od = try container.decodeIfPresent(CGFloat.self, forKey: .od)
        odX = try container.decodeIfPresent(CGFloat.self, forKey: .odX)
        odY = try container.decodeIfPresent(CGFloat.self, forKey: .odY)
        length = try container.decode(CGFloat.self, forKey: .length)
        let axisData = try container.decode([Float].self, forKey: .axis)
        axis = SIMD3<Float>(axisData[0], axisData[1], axisData[2])
        let originData = try container.decode([Float].self, forKey: .origin)
        origin = SIMD3<Float>(originData[0], originData[1], originData[2])
        startEndCut = try container.decodeIfPresent(EndCutInfo.self, forKey: .startEndCut)
        endEndCut = try container.decodeIfPresent(EndCutInfo.self, forKey: .endEndCut)
        features = try container.decode([SurfaceFeature].self, forKey: .features)
        cornerFillets = try container.decodeIfPresent([CornerFillet].self, forKey: .cornerFillets)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(profile, forKey: .profile)
        try container.encodeIfPresent(od, forKey: .od)
        try container.encodeIfPresent(odX, forKey: .odX)
        try container.encodeIfPresent(odY, forKey: .odY)
        try container.encode(length, forKey: .length)
        try container.encode([axis.x, axis.y, axis.z], forKey: .axis)
        try container.encode([origin.x, origin.y, origin.z], forKey: .origin)
        try container.encodeIfPresent(startEndCut, forKey: .startEndCut)
        try container.encodeIfPresent(endEndCut, forKey: .endEndCut)
        try container.encode(features, forKey: .features)
        try container.encodeIfPresent(cornerFillets, forKey: .cornerFillets)
    }
}

/// Corner fillet information for rectangular tubes (TCP compensation)
struct CornerFillet: Codable {
    var index: Int                 // Corner index (0-3)
    var radius: CGFloat            // Fillet radius
    var center: SIMD3<Float>       // Center point of fillet arc
    var axis: SIMD3<Float>         // Fillet axis
    var startAngle: CGFloat        // Start angle in degrees
    var endAngle: CGFloat          // End angle in degrees
}

// MARK: - 3D Model Structure

/// Mesh with optional shape classification data
struct Mesh3D {
    var vertices: [SCNVector3]
    var faces: [[Int]]
    var normals: [SCNVector3]
    var shapeData: ShapeData?
}

/// Shape classification for mesh subsets
struct ShapeData {
    enum ShapeType: String {
        case cylinder
        case box
        case custom
    }
    
    var type: ShapeType
    var dimensions: Any?
    var isCuttable: Bool
    var stockInfo: StockInfo?
}

/// Complete 3D model with stock classification
class Model3D {
    var name: String
    var meshes: [Mesh3D]
    var stockInfo: StockInfo?      // Full model stock classification
    var sourceURL: URL?
    
    var vertexCount: Int {
        meshes.reduce(0) { $0 + $1.vertices.count }
    }
    
    var faceCount: Int {
        meshes.reduce(0) { $0 + $1.faces.count }
    }
    
    init(name: String, meshes: [Mesh3D] = [], stockInfo: StockInfo? = nil, sourceURL: URL? = nil) {
        self.name = name
        self.meshes = meshes
        self.stockInfo = stockInfo
        self.sourceURL = sourceURL
    }
}

// MARK: - C++ Bridge Interface for OpenCASCADE
// The STEPBridge class is defined in Bridge/STEPBridge.h (Objective-C++)

/// Cylinder surface parameters from OCCT Geom_Cylinder
struct CylinderSurface {
    var radius: CGFloat
    var location: SIMD3<Float>
    var axis: SIMD3<Float>
}

/// Plane surface parameters from OCCT Geom_Plane
struct PlaneSurface {
    var location: SIMD3<Float>
    var normal: SIMD3<Float>
}

// MARK: - Errors

enum STEPError: LocalizedError {
    case fileNotFound
    case invalidFormat
    case notImplemented
    case kernelError(String)
    case noSolidsFound
    case classificationFailed
    
    var errorDescription: String? {
        switch self {
        case .fileNotFound: return "STEP file not found"
        case .invalidFormat: return "Invalid STEP file format"
        case .notImplemented: return "STEP parsing not yet implemented"
        case .kernelError(let msg): return "OpenCASCADE error: \(msg)"
        case .noSolidsFound: return "No solid bodies found in STEP file"
        case .classificationFailed: return "Stock classification failed"
        }
    }
}

enum ModelLoaderError: LocalizedError {
    case unsupportedFormat(String)
    case invalidGeometry
    case classificationFailed
    
    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let fmt): return "Unsupported file format: \(fmt)"
        case .invalidGeometry: return "Invalid geometry data"
        case .classificationFailed: return "Stock classification failed"
        }
    }
}

// MARK: - Model Loader

/// Model loader supporting STEP, STL, and OBJ formats
class ModelLoader {
    
    // MARK: - Public API
    
    /// Load a STEP model from file URL
    static func load(url: URL) throws -> Model3D {
        let ext = url.pathExtension.lowercased()
        
        switch ext {
        case "step", "stp":
            return try loadSTEP(url: url)
        default:
            throw ModelLoaderError.unsupportedFormat(ext)
        }
    }
    
    /// Generates StockInfo dynamically for a single selected SCNNode using the global profile as a template
    static func classifyNode(_ node: SCNNode, baseStock: StockInfo) -> StockInfo? {
        guard let geometry = node.geometry else { return nil }
        
        // Extract raw local vertices. These are the TRUE physical coordinates
        // from the STEP file. Do NOT apply node.worldTransform, because that
        // contains viewport scaling for SceneKit rendering!
        let physicalVertices = geometry.getVertices()
        guard !physicalVertices.isEmpty else { return nil }
        
        // Find the specific physical bounding box of THIS part
        var minBounds = SCNVector3(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maxBounds = SCNVector3(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        
        for v in physicalVertices {
            minBounds.x = min(minBounds.x, v.x)
            minBounds.y = min(minBounds.y, v.y)
            minBounds.z = min(minBounds.z, v.z)
            maxBounds.x = max(maxBounds.x, v.x)
            maxBounds.y = max(maxBounds.y, v.y)
            maxBounds.z = max(maxBounds.z, v.z)
        }
        
        let size = SCNVector3(maxBounds.x - minBounds.x, maxBounds.y - minBounds.y, maxBounds.z - minBounds.z)
        let maxDim = max(size.x, max(size.y, size.z))
        
        // Determine the primary axis (length) for THIS specific tube
        // (Just in case it was rotated differently in Fusion 360)
        var localAxis = SIMD3<Float>(0, 0, 1) // Default Z
        if maxDim == size.x { localAxis = SIMD3<Float>(1, 0, 0) }
        else if maxDim == size.y { localAxis = SIMD3<Float>(0, 1, 0) }
        
        // Create a new independent StockInfo based on the global dimensions
        let localStock = StockInfo(
            profile: baseStock.profile,
            od: baseStock.od,
            odX: baseStock.odX,
            odY: baseStock.odY,
            length: CGFloat(maxDim), // Use the unscaled physical length of THIS part
            axis: localAxis,         // Use the unscaled axis of THIS part
            origin: SIMD3<Float>(Float(minBounds.x), Float(minBounds.y), Float(minBounds.z))
        )
        
       
        return localStock
    }
    
    /// Computes the true physical cross-section of a prismatic part by finding the pair of
    /// perpendicular face normals whose vertex projections span the SMALLEST distance.
    /// True side walls span only the tube's cross-section (~38mm); miter faces, end caps,
    /// and tube-axis directions span much larger distances and are naturally excluded.
    private static func computeTrueCrossSection(vertices: [SCNVector3], normals: [SCNVector3]) -> (width: CGFloat, height: CGFloat)? {
        // Collect distinct normals (round + half-space fold to merge opposite faces)
        var normalCounts: [SIMD3<Float>: Int] = [:]

        for vNormal in normals {
            let nx = Float(vNormal.x)
            let ny = Float(vNormal.y)
            let nz = Float(vNormal.z)

            var rx = round(nx * 10) / 10
            var ry = round(ny * 10) / 10
            var rz = round(nz * 10) / 10

            let len = sqrt(rx*rx + ry*ry + rz*rz)
            guard len > 0.1 else { continue }
            rx /= len; ry /= len; rz /= len

            var axis = SIMD3<Float>(rx, ry, rz)
            if axis.x < 0 || (axis.x == 0 && axis.y < 0) || (axis.x == 0 && axis.y == 0 && axis.z < 0) {
                axis = -axis
            }
            axis.x = round(axis.x * 10) / 10
            axis.y = round(axis.y * 10) / 10
            axis.z = round(axis.z * 10) / 10

            normalCounts[axis, default: 0] += 1
        }

        let allNormals = normalCounts.map { (axis: $0.key, count: $0.value) }.sorted { $0.count > $1.count }

        print("      Total distinct normals: \(allNormals.count)")
        if allNormals.count <= 10 {
            for (i, n) in allNormals.enumerated() {
                print("        [\(i)] axis=(\(n.axis.x), \(n.axis.y), \(n.axis.z)), count=\(n.count)")
            }
        }

        // For each distinct normal, compute how far the vertices project onto it.
        // Side wall normals span the tube cross-section (~38 mm).
        // Miter / end-cap / tube-axis normals span much larger distances.
        var normalRanges: [(axis: SIMD3<Float>, range: Float)] = []
        for n in allNormals {
            var minP = Float.greatestFiniteMagnitude
            var maxP = -Float.greatestFiniteMagnitude
            for v in vertices {
                let px = Float(v.x)
                let py = Float(v.y)
                let pz = Float(v.z)
                let proj = px * n.axis.x + py * n.axis.y + pz * n.axis.z
                if proj < minP { minP = proj }
                if proj > maxP { maxP = proj }
            }
            normalRanges.append((axis: n.axis, range: maxP - minP))
        }

        // Sort ascending by range — true side-wall normals bubble to the top
        let sortedByRange = normalRanges.sorted { $0.range < $1.range }

        print("      Normals by projection range (smallest first):")
        for (i, n) in sortedByRange.prefix(6).enumerated() {
            print("        [\(i)] axis=(\(n.axis.x), \(n.axis.y), \(n.axis.z)), range=\(n.range)")
        }

        // Find the two perpendicular normals whose max(range1, range2) is minimised.
        // The correct cross-section pair wins because miter/axis projections are much larger.
        var bestScore = Float.greatestFiniteMagnitude
        var bestA1: SIMD3<Float>? = nil
        var bestA2: SIMD3<Float>? = nil
        var bestDim1: Float = 0
        var bestDim2: Float = 0

        for i in 0..<sortedByRange.count {
            for j in (i+1)..<sortedByRange.count {
                let ni = sortedByRange[i]
                let nj = sortedByRange[j]
                let dotVal = abs(dot(ni.axis, nj.axis))
                guard dotVal < 0.15 else { continue }

                let score = max(ni.range, nj.range)
                if score < bestScore {
                    bestScore = score
                    bestA1 = ni.axis
                    bestA2 = nj.axis
                    bestDim1 = ni.range
                    bestDim2 = nj.range
                }
            }
        }

        guard let a1 = bestA1, let a2 = bestA2 else {
            print("      ⚠️ Failed to find two orthogonal side-wall axes")
            return nil
        }

        print("      Dominant side-wall axes: a1=(\(a1.x), \(a1.y), \(a1.z)), a2=(\(a2.x), \(a2.y), \(a2.z))")

        let dim1 = CGFloat(bestDim1)
        let dim2 = CGFloat(bestDim2)
        return (width: min(dim1, dim2), height: max(dim1, dim2))
    }
    
   
    // MARK: - STEP File Loading
    
    /// Load STEP file using OpenCASCADE kernel
    static func loadSTEP(url: URL) throws -> Model3D {
        print("=== Loading STEP File ===")
        print("  URL: \(url.path)")
        print("  File exists: \(FileManager.default.fileExists(atPath: url.path))")
        
        // Verify file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("  ❌ File not found at path")
            throw STEPError.fileNotFound
        }
        
        // Attempt to use OpenCASCADE bridge
        do {
            print("  Calling OCCT bridge...")
            
            // Call OCCT bridge and get JSON directly
            guard let jsonString = STEPBridgeWrapperSwift.parseSTEPToJSON(url) else {
                print("  ❌ OCCT bridge returned nil")
                throw STEPError.kernelError("OCCT bridge returned nil")
            }
            
            print("  ✅ STEP parsing succeeded via OCCT bridge")
            print("  JSON length: \(jsonString.count) characters")
            
            return try parseSTEPResult(jsonString: jsonString, url: url)
        } catch let error as STEPError {
            print("  ❌ OCCT bridge error: \(error.localizedDescription)")
            print("  Using fallback mesh approximation")
            return createSTEPPlaceholder(url: url)
        } catch {
            print("  ❌ Unexpected error: \(error.localizedDescription)")
            print("  Using fallback mesh approximation")
            return createSTEPPlaceholder(url: url)
        }
    }
    
    /// Parse STEP result from OCCT bridge
    private static func parseSTEPResult(jsonString: String, url: URL) throws -> Model3D {
        print("  Parsing STEP result JSON...")
        
        guard let data = jsonString.data(using: .utf8) else {
            print("  ❌ Failed to convert JSON string to data")
            throw STEPError.invalidFormat
        }
        
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("  ❌ Failed to parse JSON")
            print("  JSON preview: \(jsonString.prefix(200))...")
            throw STEPError.invalidFormat
        }
        
        print("  ✅ JSON parsed successfully")
        
        let modelName = url.deletingPathExtension().lastPathComponent
        var meshes: [Mesh3D] = []
        var stockInfos: [StockInfo] = []
        
        // Parse solids from STEP assembly
        if let solids = json["solids"] as? [[String: Any]] {
            print("  Found \(solids.count) solid(s) in STEP file")
            
            for (index, solidData) in solids.enumerated() {
                print("  Processing solid \(index + 1)/\(solids.count)...")
                
                do {
                    let (mesh, stockInfo) = try parseSolid(solidData, index: index)
                    meshes.append(mesh)
                    if let stock = stockInfo {
                        stockInfos.append(stock)
                        print("    ✅ Classified as \(stock.profile.rawValue)")
                    }
                } catch {
                    print("    ⚠️  Failed to parse solid: \(error.localizedDescription)")
                }
            }
        } else {
            print("  ⚠️  No 'solids' array found in JSON")
        }
        
        if meshes.isEmpty {
            print("  ❌ No meshes created from STEP data")
            throw STEPError.noSolidsFound
        }
        
        // Use first stock info as primary, or combine if multiple
        let primaryStock = stockInfos.first
        
        print("  ✅ Created model with \(meshes.count) mesh(es)")
        
        return Model3D(name: modelName, meshes: meshes, stockInfo: primaryStock, sourceURL: url)
    }
    
    
    
    /// Parse face from STEP B-Rep
    private static func parseFace(_ faceData: [String: Any],
                                   vertexOffset: Int) throws -> ([SCNVector3], [[Int]], [SCNVector3]) {
        if let vertsArray = faceData["vertices"] as? [Double],
           let indicesArray = faceData["indices"] as? [Int] {
            
            var vertices: [SCNVector3] = []
            for i in stride(from: 0, to: vertsArray.count, by: 3) {
                vertices.append(SCNVector3(Float(vertsArray[i]), Float(vertsArray[i+1]), Float(vertsArray[i+2])))
            }
            
            var indices: [[Int]] = []
            for i in stride(from: 0, to: indicesArray.count, by: 3) {
                indices.append([
                    indicesArray[i] + vertexOffset,
                    indicesArray[i+1] + vertexOffset,
                    indicesArray[i+2] + vertexOffset
                ])
            }
            
            var normals: [SCNVector3] = []
            if let normalsArray = faceData["normals"] as? [Double], normalsArray.count == vertsArray.count {
                for i in stride(from: 0, to: normalsArray.count, by: 3) {
                    normals.append(SCNVector3(Float(normalsArray[i]), Float(normalsArray[i+1]), Float(normalsArray[i+2])))
                }
            } else {
                // Generates flat normals if OCCT didn't provide them
                let faceNormal = computeFaceNormal(vertices)
                normals = Array(repeating: faceNormal, count: vertices.count)
            }
            
            return (vertices, indices, normals)
        }

        var vertices: [SCNVector3] = []
        var indices: [[Int]] = []
        var normals: [SCNVector3] = []
        
        // Parse wires (boundary loops)
        guard let wires = faceData["wires"] as? [[String: Any]] else {
            return (vertices, indices, normals)
        }
        
        // Collect all wire loops
        var wireLoops: [[SCNVector3]] = []
        
        for wire in wires {
            var wireVerts: [SCNVector3] = []
            
            if let pointsValue = wire["points"] {
                if let pointsFlat = pointsValue as? [NSNumber] {
                    let numPoints = pointsFlat.count / 3
                    for i in 0..<numPoints {
                        wireVerts.append(SCNVector3(
                            pointsFlat[i * 3].floatValue,
                            pointsFlat[i * 3 + 1].floatValue,
                            pointsFlat[i * 3 + 2].floatValue
                        ))
                    }
                } else if let pointsFlat = pointsValue as? [Float] {
                    let numPoints = pointsFlat.count / 3
                    for i in 0..<numPoints {
                        wireVerts.append(SCNVector3(
                            pointsFlat[i * 3],
                            pointsFlat[i * 3 + 1],
                            pointsFlat[i * 3 + 2]
                        ))
                    }
                } else if let pointsArray = pointsValue as? [[Float]] {
                    for point in pointsArray where point.count >= 3 {
                        wireVerts.append(SCNVector3(point[0], point[1], point[2]))
                    }
                }
            }
            
            if !wireVerts.isEmpty {
                wireLoops.append(wireVerts)
            }
        }
        
        guard !wireLoops.isEmpty else {
            return (vertices, indices, normals)
        }
        
        // Assume first wire is outer boundary, rest are holes
        let outerWire = wireLoops[0]
        let holes = Array(wireLoops.dropFirst())
        
        // Add all vertices
        vertices.append(contentsOf: outerWire)
        var holeStartIndices: [Int] = []
        for hole in holes {
            holeStartIndices.append(vertices.count)
            vertices.append(contentsOf: hole)
        }
        
        // Triangulate
        if holes.isEmpty {
            // Simple convex fan
            for i in 1..<(outerWire.count - 1) {
                indices.append([0, i, i + 1])
            }
        } else {
            // Merge outer and holes into single polygon via bridges
            var mergedLoop: [Int] = Array(0..<outerWire.count)
            
            for (holeIdx, holeStart) in holeStartIndices.enumerated() {
                let hole = holes[holeIdx]
                let holeIndices = Array(holeStart..<(holeStart + hole.count))
                
                // Find closest point on outer to hole
                var minDist = Float.infinity
                var bridgeOuter = 0
                let bridgeHole = holeIndices[0]
                
                for outerIdx in mergedLoop {
                    let d = distance(vertices[outerIdx], vertices[bridgeHole])
                    if d < minDist {
                        minDist = d
                        bridgeOuter = outerIdx
                    }
                }
                
                // Insert hole into merged loop at bridge point
                if let insertPos = mergedLoop.firstIndex(of: bridgeOuter) {
                    var bridgeSegment = holeIndices
                    bridgeSegment.append(bridgeHole)
                    bridgeSegment.append(bridgeOuter)
                    mergedLoop.insert(contentsOf: bridgeSegment, at: insertPos + 1)
                }
            }
            
            // Fan triangulation of merged loop
            let firstVertex = mergedLoop[0]
            for i in 1..<(mergedLoop.count - 1) {
                let v1 = mergedLoop[i]
                let v2 = mergedLoop[i + 1]
                indices.append([firstVertex, v1, v2])
            }
        }
        
        // Generate normals
        let faceNormal = computeFaceNormal(outerWire)
        normals = Array(repeating: faceNormal, count: vertices.count)
        
        // Adjust indices by offset
        var adjustedIndices: [[Int]] = []
        for triangle in indices {
            let adjusted = [triangle[0] + vertexOffset, triangle[1] + vertexOffset, triangle[2] + vertexOffset]
            adjustedIndices.append(adjusted)
        }
        
        return (vertices, adjustedIndices, normals)
    }
    
    private static func distance(_ a: SCNVector3, _ b: SCNVector3) -> Float {
        let dx = a.x - b.x
        let dy = a.y - b.y
        let dz = a.z - b.z
        let dxSquared = dx * dx
        let dySquared = dy * dy
        let dzSquared = dz * dz
        let sumOfSquares = dxSquared + dySquared + dzSquared
        return Float(sqrt(sumOfSquares))
    }
    
    /// Compute face normal from vertices
    private static func computeFaceNormal(_ vertices: [SCNVector3]) -> SCNVector3 {
        guard vertices.count >= 3 else { return SCNVector3(0, 0, 1) }
        
        let v0 = vertices[0]
        let v1 = vertices[1]
        let v2 = vertices[2]
        
        let e1x = v1.x - v0.x
        let e1y = v1.y - v0.y
        let e1z = v1.z - v0.z
        let edge1 = SCNVector3(e1x, e1y, e1z)
        
        let e2x = v2.x - v0.x
        let e2y = v2.y - v0.y
        let e2z = v2.z - v0.z
        let edge2 = SCNVector3(e2x, e2y, e2z)
        
        // Cross product
        let nx = edge1.y * edge2.z - edge1.z * edge2.y
        let ny = edge1.z * edge2.x - edge1.x * edge2.z
        let nz = edge1.x * edge2.y - edge1.y * edge2.x
        let normal = SCNVector3(nx, ny, nz)
        
        // Normalize
        let lenSq = normal.x * normal.x + normal.y * normal.y + normal.z * normal.z
        let len = sqrt(lenSq)
        if len > 0 {
            return SCNVector3(normal.x / len, normal.y / len, normal.z / len)
        }
        
        return SCNVector3(0, 0, 1)
    }
    
    /// Create placeholder for STEP files when OCCT is not available
    private static func createSTEPPlaceholder(url: URL) -> Model3D {
        print("  Creating STEP placeholder model")
        
        // Try to parse STEP file for bounding box
        let (minBounds, maxBounds) = parseSTEPBounds(url: url)
        let size = SCNVector3(maxBounds.x - minBounds.x, maxBounds.y - minBounds.y, maxBounds.z - minBounds.z)
        let center = SCNVector3((minBounds.x + maxBounds.x) / 2, (minBounds.y + maxBounds.y) / 2, (minBounds.z + maxBounds.z) / 2)
        
        // Determine if round or rectangular based on cross-section
        let crossSection1 = abs(size.y - size.z)
        let crossSection2 = abs(size.x - size.z)
        let crossSection3 = abs(size.x - size.y)
        
        let isRound = crossSection1 < 10 || crossSection2 < 10 || crossSection3 < 10
        let diameter = isRound ? max(size.y, size.z) : min(size.y, size.z)
        let length = max(size.x, size.y, size.z)
        
        // Create appropriate geometry
        let geometry: SCNGeometry
        if isRound {
            let cylinder = SCNCylinder(radius: CGFloat(diameter) / 2, height: CGFloat(length))
            cylinder.radialSegmentCount = 36
            geometry = cylinder
        } else {
            let box = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0)
            geometry = box
        }

        var vertices: [SCNVector3] = []
        var faces: [[Int]] = []

        // Extract vertices from geometry sources
        if let source = geometry.sources.first {
            let vertexCount = source.vectorCount
            let data = source.data

            data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                let floatPtr = baseAddress.assumingMemoryBound(to: Float.self)

                for i in 0..<vertexCount {
                    var x = floatPtr[i * 3]
                    var y = floatPtr[i * 3 + 1]
                    var z = floatPtr[i * 3 + 2]
                    // Translate to center
                    x += Float(center.x)
                    y += Float(center.y)
                    z += Float(center.z)
                    vertices.append(SCNVector3(x, y, z))
                }
            }
        }

        // Extract faces from geometry elements
        if let element = geometry.elements.first {
            let indexCount = element.primitiveCount * 3
            let indexData = element.data

            indexData.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return }

                if element.bytesPerIndex == 2 {
                    let indices = baseAddress.assumingMemoryBound(to: UInt16.self)
                    for i in 0..<indexCount {
                        faces.append([Int(indices[i])])
                    }
                } else {
                    let indices = baseAddress.assumingMemoryBound(to: Int32.self)
                    for i in 0..<indexCount {
                        faces.append([Int(indices[i])])
                    }
                }
            }
        }

        // Generate normals
        let normals = generateNormals(vertices: vertices, faces: faces)
        
        // Create shape data
        let shapeData: ShapeData
        if isRound {
            shapeData = ShapeData(
                type: .cylinder,
                dimensions: CylinderDimensions(diameter: diameter, height: length),
                isCuttable: true
            )
        } else {
            shapeData = ShapeData(
                type: .box,
                dimensions: BoxDimensions(width: size.x, height: size.y, depth: size.z),
                isCuttable: true
            )
        }
        
        let mesh = Mesh3D(vertices: vertices, faces: faces, normals: normals, shapeData: shapeData)

        // Create stock info
        let stockInfo: StockInfo
        if isRound {
            stockInfo = StockInfo(
                profile: .round,
                od: diameter,
                length: length,
                axis: SIMD3<Float>(1, 0, 0)
            )
        } else {
            let isSquare = abs(size.x - size.y) < 5
            stockInfo = StockInfo(
                profile: isSquare ? .square : .rectangular,
                odX: size.x,
                odY: size.y,
                length: size.z,
                axis: SIMD3<Float>(0, 0, 1)
            )
        }

        return Model3D(
            name: url.deletingPathExtension().lastPathComponent,
            meshes: [mesh],
            stockInfo: stockInfo,
            sourceURL: url
        )
    }
    
    /// Parse STEP file to extract bounding box
    private static func parseSTEPBounds(url: URL) -> (SCNVector3, SCNVector3) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return (SCNVector3(-25, -25, -50), SCNVector3(25, 25, 50))
        }
        
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minY = Float.greatestFiniteMagnitude, maxY = -Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude
        
        // Look for CARTESIAN_POINT entities in STEP file
        // Format: #147=VERTEX_POINT('',#510); where #510=CARTESIAN_POINT('',(x,y,z))
        let lines = content.components(separatedBy: .newlines)
        
        // First, build a map of entity IDs to coordinates
        var pointMap: [String: [Float]] = [:]
        
        for line in lines {
            // Match CARTESIAN_POINT('',(x,y,z))
            if line.contains("CARTESIAN_POINT") {
                // Extract entity number: #147=
                if let idRange = line.range(of: "#[0-9]+="),
                   let coordRange = line.range(of: "\\(([^)]+)\\)", options: .regularExpression, range: line.endIndex..<line.endIndex, locale: nil) ?? line.range(of: "\\(([^)]+)\\)") {
                    
                    let entityId = String(line[idRange]).replacingOccurrences(of: "=", with: "")
                    let coordStr = String(line[coordRange])
                        .replacingOccurrences(of: "(", with: "")
                        .replacingOccurrences(of: ")", with: "")
                    
                    let coords = coordStr.components(separatedBy: ",")
                        .compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
                    
                    if coords.count >= 3 {
                        pointMap[entityId] = coords
                    }
                }
            }
        }
        
        // Now find all VERTEX_POINT references and look up their coordinates
        for line in lines {
            if line.contains("VERTEX_POINT") {
                // Extract the point reference: #510
                if let refRange = line.range(of: "#[0-9]+\\)") {
                    let refStr = String(line[refRange]).replacingOccurrences(of: ")", with: "")
                    if let coords = pointMap[refStr] {
                        minX = min(minX, coords[0])
                        maxX = max(maxX, coords[0])
                        minY = min(minY, coords[1])
                        maxY = max(maxY, coords[1])
                        minZ = min(minZ, coords[2])
                        maxZ = max(maxZ, coords[2])
                    }
                }
            }
        }
        
        // If no points found, try direct search for all coordinate tuples
        if minX == Float.greatestFiniteMagnitude {
            for line in lines {
                // Look for any (x,y,z) coordinate patterns
                if let range = line.range(of: "\\(([^,)]+),([^,)]+),([^)]+)\\)") {
                    let coordStr = String(line[range])
                        .replacingOccurrences(of: "(", with: "")
                        .replacingOccurrences(of: ")", with: "")
                    let coords = coordStr.components(separatedBy: ",")
                        .compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
                    
                    if coords.count >= 3 && abs(coords[0]) < 10000 && abs(coords[1]) < 10000 && abs(coords[2]) < 10000 {
                        minX = min(minX, coords[0])
                        maxX = max(maxX, coords[0])
                        minY = min(minY, coords[1])
                        maxY = max(maxY, coords[1])
                        minZ = min(minZ, coords[2])
                        maxZ = max(maxZ, coords[2])
                    }
                }
            }
        }
        
        // If still no points found, return default bounds
        if minX == Float.greatestFiniteMagnitude {
            return (SCNVector3(-25, -25, -50), SCNVector3(25, 25, 50))
        }
        
        return (SCNVector3(minX, minY, minZ), SCNVector3(maxX, maxY, maxZ))
    }

    // MARK: - STL File Loading
    
    static func loadSTL(url: URL) throws -> Model3D {
        print("=== Loading STL File ===")
        print("  URL: \(url.path)")
        
        let data = try Data(contentsOf: url)
        let (vertices, faces, normals) = try parseSTLData(data)
        
        let mesh = Mesh3D(vertices: vertices, faces: faces, normals: normals, shapeData: nil)
        let stockInfo = classifyStock(vertices: vertices, faces: faces, normals: normals)
        
        return Model3D(
            name: url.deletingPathExtension().lastPathComponent,
            meshes: [mesh],
            stockInfo: stockInfo,
            sourceURL: url
        )
    }
    
    private static func parseSTLData(_ data: Data) throws -> ([SCNVector3], [[Int]], [SCNVector3]) {
        var vertices: [SCNVector3] = []
        var faces: [[Int]] = []
        var normals: [SCNVector3] = []
        
        // Check if ASCII or binary
        let header = String(data: data.prefix(80), encoding: .ascii) ?? ""
        
        if header.contains("solid") && data.count > 800 {
            // ASCII STL
            try parseASCIISTL(data, vertices: &vertices, faces: &faces, normals: &normals)
        } else {
            // Binary STL
            try parseBinarySTL(data, vertices: &vertices, faces: &faces, normals: &normals)
        }
        
        return (vertices, faces, normals)
    }
    
    private static func parseASCIISTL(_ data: Data, vertices: inout [SCNVector3], 
                                       faces: inout [[Int]], normals: inout [SCNVector3]) throws {
        guard let content = String(data: data, encoding: .ascii) else {
            throw ModelLoaderError.invalidGeometry
        }
        
        let lines = content.components(separatedBy: .newlines)
        var vertexOffset = 0
        
        for i in 0..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            
            if line.hasPrefix("facet normal") {
                // Parse normal
                let components = line.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                if components.count >= 5 {
                    let nx = Float(components[2]) ?? 0
                    let ny = Float(components[3]) ?? 0
                    let nz = Float(components[4]) ?? 0
                    let normal = SCNVector3(nx, ny, nz)
                    
                    // Parse 3 vertices
                    var faceVertices: [SCNVector3] = []
                    var vertexIndex = i + 2  // Skip "facet normal" and "outer loop"
                    
                    while vertexIndex < lines.count && faceVertices.count < 3 {
                        let vertexLine = lines[vertexIndex].trimmingCharacters(in: .whitespaces)
                        if vertexLine.hasPrefix("vertex") {
                            let vComponents = vertexLine.components(separatedBy: .whitespaces)
                                .filter { !$0.isEmpty }
                            if vComponents.count >= 4 {
                                let x = Float(vComponents[1]) ?? 0
                                let y = Float(vComponents[2]) ?? 0
                                let z = Float(vComponents[3]) ?? 0
                                faceVertices.append(SCNVector3(x, y, z))
                            }
                        }
                        vertexIndex += 1
                    }
                    
                    // Add vertices and face
                    for v in faceVertices {
                        vertices.append(v)
                    }
                    faces.append([vertexOffset, vertexOffset + 1, vertexOffset + 2])
                    for _ in 0..<3 {
                        normals.append(normal)
                    }
                    vertexOffset += 3
                }
            }
        }
    }
    
    private static func parseBinarySTL(_ data: Data, vertices: inout [SCNVector3],
                                        faces: inout [[Int]], normals: inout [SCNVector3]) throws {
        guard data.count >= 84 else {
            throw ModelLoaderError.invalidGeometry
        }
        
        // Skip 80-byte header, read triangle count
        let triangleCount = data.subdata(in: 80..<84).withUnsafeBytes {
            $0.load(as: UInt32.self)
        }
        
        var offset = 84
        var vertexOffset = 0
        
        for _ in 0..<triangleCount {
            guard offset + 50 <= data.count else { break }
            
            // Read normal (12 bytes)
            let normalData = data.subdata(in: offset..<offset+12)
            let normal = normalData.withUnsafeBytes { ptr -> SCNVector3 in
                let floats = ptr.bindMemory(to: Float.self)
                return SCNVector3(floats[0], floats[1], floats[2])
            }
            offset += 12
            
            // Read 3 vertices (36 bytes each)
            var faceVertices: [SCNVector3] = []
            for _ in 0..<3 {
                let vertexData = data.subdata(in: offset..<offset+12)
                let vertex = vertexData.withUnsafeBytes { ptr -> SCNVector3 in
                    let floats = ptr.bindMemory(to: Float.self)
                    return SCNVector3(floats[0], floats[1], floats[2])
                }
                faceVertices.append(vertex)
                offset += 12
            }
            
            // Skip attribute byte count (2 bytes)
            offset += 2
            
            // Add to arrays
            for v in faceVertices {
                vertices.append(v)
            }
            faces.append([vertexOffset, vertexOffset + 1, vertexOffset + 2])
            for _ in 0..<3 {
                normals.append(normal)
            }
            vertexOffset += 3
        }
    }
    
    // MARK: - OBJ File Loading
    
    static func loadOBJ(url: URL) throws -> Model3D {
        print("=== Loading OBJ File ===")
        print("  URL: \(url.path)")
        
        let content = try String(contentsOf: url, encoding: .utf8)
        let (vertices, faces, normals) = try parseOBJData(content)
        
        let mesh = Mesh3D(vertices: vertices, faces: faces, normals: normals, shapeData: nil)
        let stockInfo = classifyStock(vertices: vertices, faces: faces, normals: normals)
        
        return Model3D(
            name: url.deletingPathExtension().lastPathComponent,
            meshes: [mesh],
            stockInfo: stockInfo,
            sourceURL: url
        )
    }
    
    private static func parseOBJData(_ content: String) throws -> ([SCNVector3], [[Int]], [SCNVector3]) {
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var faces: [[Int]] = []
        
        let lines = content.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.hasPrefix("v ") {
                // Vertex
                let components = trimmed.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                if components.count >= 4 {
                    let x = Float(components[1]) ?? 0
                    let y = Float(components[2]) ?? 0
                    let z = Float(components[3]) ?? 0
                    vertices.append(SCNVector3(x, y, z))
                }
            } else if trimmed.hasPrefix("vn ") {
                // Normal
                let components = trimmed.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                if components.count >= 4 {
                    let x = Float(components[1]) ?? 0
                    let y = Float(components[2]) ?? 0
                    let z = Float(components[3]) ?? 0
                    normals.append(SCNVector3(x, y, z))
                }
            } else if trimmed.hasPrefix("f ") {
                // Face
                let components = trimmed.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                
                var faceIndices: [Int] = []
                for comp in components.dropFirst() {
                    // Parse "v/vt/vn" format
                    let parts = comp.components(separatedBy: "/")
                    if let vIndex = Int(parts[0]) {
                        // OBJ uses 1-based indexing
                        faceIndices.append(vIndex - 1)
                    }
                }
                
                // Convert to triangles (triangle fan for polygons)
                if faceIndices.count >= 3 {
                    for i in 1..<(faceIndices.count - 1) {
                        faces.append([faceIndices[0], faceIndices[i], faceIndices[i + 1]])
                    }
                }
            }
        }
        
        // Generate normals if not provided
        if normals.isEmpty {
            normals = generateNormals(vertices: vertices, faces: faces)
        }
        
        return (vertices, faces, normals)
    }
    
    private static func generateNormals(vertices: [SCNVector3], faces: [[Int]]) -> [SCNVector3] {
        var normals = Array(repeating: SCNVector3(0, 0, 1), count: vertices.count)
        
        for face in faces {
            guard face.count >= 3 else { continue }
            
            let v0 = vertices[face[0]]
            let v1 = vertices[face[1]]
            let v2 = vertices[face[2]]
            
            let e1x = v1.x - v0.x
            let e1y = v1.y - v0.y
            let e1z = v1.z - v0.z
            let edge1 = SCNVector3(e1x, e1y, e1z)
            
            let e2x = v2.x - v0.x
            let e2y = v2.y - v0.y
            let e2z = v2.z - v0.z
            let edge2 = SCNVector3(e2x, e2y, e2z)
            
            let nx = edge1.y * edge2.z - edge1.z * edge2.y
            let ny = edge1.z * edge2.x - edge1.x * edge2.z
            let nz = edge1.x * edge2.y - edge1.y * edge2.x
            let normal = SCNVector3(nx, ny, nz)
            
            // Accumulate normals for each vertex
            for index in face {
                let existing = normals[index]
                let accX = existing.x + normal.x
                let accY = existing.y + normal.y
                let accZ = existing.z + normal.z
                normals[index] = SCNVector3(accX, accY, accZ)
            }
        }
        
        // Normalize
        for i in 0..<normals.count {
            let n = normals[i]
            let lenSq = n.x * n.x + n.y * n.y + n.z * n.z
            let len = sqrt(lenSq)
            if len > 0 {
                normals[i] = SCNVector3(n.x / len, n.y / len, n.z / len)
            }
        }
        
        return normals
    }
    
    // MARK: - Normal Analysis for Classification
    
    private struct NormalAnalysis {
        var isCylindrical: Bool
        var isPlanar: Bool
        var averageRadius: CGFloat
        var planeNormals: [SCNVector3]
    }
    
    private static func analyzeNormals(_ normals: [SCNVector3]) -> NormalAnalysis {
        guard !normals.isEmpty else {
            return NormalAnalysis(isCylindrical: false, isPlanar: false,
                                 averageRadius: 0, planeNormals: [])
        }
        
        var planeNormals: [SCNVector3] = []
        let directionThreshold: Float = 0.1
        
        for normal in normals {
            var foundGroup = false
            for i in 0..<planeNormals.count {
                let existing = planeNormals[i]
                let dot = normal.x * existing.x + normal.y * existing.y + normal.z * existing.z
                if abs(CGFloat(dot)) > 1.0 - CGFloat(directionThreshold) {
                    foundGroup = true
                    break
                }
            }
            if !foundGroup {
                planeNormals.append(normal)
            }
        }
        
        // FIX: Rectangular tubes have 4 (open ends) or 6 (closed ends) distinct flat normals.
        // Cylinders will have many distinct normals (typically > 6).
        let isPlanar = planeNormals.count >= 3 && planeNormals.count <= 6
        let isCylindrical = planeNormals.count > 6
        
        return NormalAnalysis(
            isCylindrical: isCylindrical,
            isPlanar: isPlanar,
            averageRadius: 25,
            planeNormals: planeNormals
        )
    }
    
    private static func classifyRectangularDimensions(size: SCNVector3,
                                                       normalAnalysis: NormalAnalysis)
    -> (isSquare: Bool, odX: CGFloat, odY: CGFloat) {
        let dims = [CGFloat(size.x), CGFloat(size.y), CGFloat(size.z)].sorted()
        let odX = dims[1]  // Middle dimension
        let odY = dims[0]  // Smallest dimension (assuming Z is length)

        // Check if square (within tolerance)
        let tolerance: CGFloat = 2.0  // mm
        let isSquare = abs(odX - odY) < tolerance

        return (isSquare, odX, odY)
    }
    
    // MARK: - End Cut Detection
    
    private static func getAxialVariation(_ axialPositions: [CGFloat], 
                                           axis: SIMD3<Float>, 
                                           vertices: [SCNVector3]) -> CGFloat? {
        guard !axialPositions.isEmpty else { return nil }
        
        guard let minVal = axialPositions.min(),
              let maxVal = axialPositions.max() else { return nil }
        
        return maxVal - minVal
    }
    
    /// Classify stock from mesh data (fallback for non-STEP formats)
        static func classifyStock(vertices: [SCNVector3], faces: [[Int]],
                                  normals: [SCNVector3]) -> StockInfo? {
            guard !vertices.isEmpty, !faces.isEmpty else { return nil }
            
            // Compute bounding box
            var minPoint = SCNVector3(Float.greatestFiniteMagnitude,
                                       Float.greatestFiniteMagnitude,
                                       Float.greatestFiniteMagnitude)
            var maxPoint = SCNVector3(-Float.greatestFiniteMagnitude,
                                       -Float.greatestFiniteMagnitude,
                                       -Float.greatestFiniteMagnitude)
            
            for v in vertices {
                minPoint.x = min(minPoint.x, v.x)
                minPoint.y = min(minPoint.y, v.y)
                minPoint.z = min(minPoint.z, v.z)
                maxPoint.x = max(maxPoint.x, v.x)
                maxPoint.y = max(maxPoint.y, v.y)
                maxPoint.z = max(maxPoint.z, v.z)
            }
            
            let size = SCNVector3(maxPoint.x - minPoint.x,
                                  maxPoint.y - minPoint.y,
                                  maxPoint.z - minPoint.z)
            
            // Determine primary axis
            let maxDim = Swift.max(size.x, Swift.max(size.y, size.z))
            var axis: SIMD3<Float>
            
            if size.x == maxDim {
                axis = SIMD3<Float>(1, 0, 0)
            } else if size.y == maxDim {
                axis = SIMD3<Float>(0, 1, 0)
            } else {
                axis = SIMD3<Float>(0, 0, 1)
            }
            
            let normalAnalysis = analyzeNormals(normals)
            let stockInfo: StockInfo
            
            if normalAnalysis.isCylindrical {
                let avgRadius = normalAnalysis.averageRadius
                stockInfo = StockInfo(
                    profile: .round,
                    od: CGFloat(avgRadius) * 2,
                    length: CGFloat(maxDim),
                    axis: axis,
                    origin: SIMD3<Float>(Float(minPoint.x), Float(minPoint.y), Float(minPoint.z))
                )
            } else if normalAnalysis.isPlanar {
                let dims = classifyRectangularDimensions(size: size, normalAnalysis: normalAnalysis)
                stockInfo = StockInfo(
                    profile: dims.isSquare ? .square : .rectangular,
                    odX: dims.odX,
                    odY: dims.odY,
                    length: CGFloat(maxDim),
                    axis: axis,
                    origin: SIMD3<Float>(Float(minPoint.x), Float(minPoint.y), Float(minPoint.z))
                )
            } else {
                return nil
            }
            
            // Use nil for isCutTriangle to trigger the fallback raw mesh analyzer
            detectFeatures(vertices: vertices, faces: faces,
                           axis: axis, stockInfo: stockInfo)
            
            return stockInfo
        }
        private static func parseSolid(_ solidData: [String: Any], index: Int) throws -> (Mesh3D, StockInfo?) {
            var stepFaces: [(verts: [SCNVector3], indices: [[Int]], norms: [SCNVector3])] = []
            var rawVertices: [SCNVector3] = []

            var maxCylinderRadius: CGFloat = 0
            var planarFacesCount = 0

            if let facesData = solidData["faces"] as? [[String: Any]] {
                for faceData in facesData {
                    if let surfaceType = faceData["surface_type"] as? String {
                        if surfaceType == "CYLINDER" {
                            if let cylData = faceData["cylinder"] as? [String: Any],
                               let radius = cylData["radius"] as? Double {
                                maxCylinderRadius = max(maxCylinderRadius, CGFloat(radius))
                            }
                        } else if surfaceType == "PLANE" {
                            planarFacesCount += 1
                        }
                    }

                    let (faceVerts, faceIndices, faceNormals) = try parseFace(faceData, vertexOffset: rawVertices.count)
                    stepFaces.append((faceVerts, faceIndices, faceNormals))
                    rawVertices.append(contentsOf: faceVerts)
                }
            }

            var minBounds = SCNVector3(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
            var maxBounds = SCNVector3(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
            for v in rawVertices {
                minBounds.x = min(minBounds.x, v.x); minBounds.y = min(minBounds.y, v.y); minBounds.z = min(minBounds.z, v.z)
                maxBounds.x = max(maxBounds.x, v.x); maxBounds.y = max(maxBounds.y, v.y); maxBounds.z = max(maxBounds.z, v.z)
            }
            
            let sizeX = CGFloat(maxBounds.x - minBounds.x)
            let sizeY = CGFloat(maxBounds.y - minBounds.y)
            let sizeZ = CGFloat(maxBounds.z - minBounds.z)
            let sortedDims = [sizeX, sizeY, sizeZ].sorted()
            let crossSectionMin = sortedDims[0]
            let crossSectionMax = sortedDims[1]
            let length = sortedDims[2]

            var axis = SIMD3<Float>(0, 0, 1)
            if sizeX == length { axis = SIMD3<Float>(1, 0, 0) }
            else if sizeY == length { axis = SIMD3<Float>(0, 1, 0) }
            
            var flattenedFaces: [[Int]] = []
            var flattenedNormals: [SCNVector3] = []
            for sf in stepFaces {
                flattenedFaces.append(contentsOf: sf.indices)
                flattenedNormals.append(contentsOf: sf.norms)
            }
            
            var stockInfo = classifyStock(vertices: rawVertices, faces: flattenedFaces, normals: flattenedNormals)
            if stockInfo == nil {
                stockInfo = StockInfo(profile: .unknown, length: length, axis: axis, origin: SIMD3<Float>(Float(minBounds.x), Float(minBounds.y), Float(minBounds.z)))
            }
            
            if let stock = stockInfo {
                let cylinderDiameter = maxCylinderRadius * 2
                let isMainBodyCylinder = (cylinderDiameter > 0) && (cylinderDiameter >= crossSectionMax * 0.8)
                let isRoundFallback = (planarFacesCount < 4) && (abs(crossSectionMax - crossSectionMin) < 2.0)
                
                if isMainBodyCylinder || isRoundFallback {
                    stock.profile = .round
                    stock.od = isMainBodyCylinder ? cylinderDiameter : crossSectionMax
                    stock.odX = nil; stock.odY = nil
                } else if planarFacesCount >= 4 {
                    var trueDimX = crossSectionMax; var trueDimY = crossSectionMin
                    if let trueCross = computeTrueCrossSection(vertices: rawVertices, normals: flattenedNormals) {
                        trueDimX = trueCross.height; trueDimY = trueCross.width
                    }
                    stock.profile = abs(trueDimX - trueDimY) < 2.0 ? .square : .rectangular
                    stock.odX = trueDimX; stock.odY = trueDimY; stock.od = nil
                }
                
                stock.length = length; stock.axis = axis
                stock.origin = SIMD3<Float>(Float(minBounds.x), Float(minBounds.y), Float(minBounds.z))
                
                // Clean extraction
                stock.features.removeAll()
                detectFeatures(vertices: rawVertices, faces: flattenedFaces, axis: stock.axis, stockInfo: stock)
            }

            let shapeData: ShapeData?
            if let stock = stockInfo {
                switch stock.profile {
                case .round: shapeData = ShapeData(type: .cylinder, dimensions: CylinderDimensions(diameter: stock.od ?? 0, height: stock.length), isCuttable: true, stockInfo: stock)
                case .square, .rectangular: shapeData = ShapeData(type: .box, dimensions: BoxDimensions(width: stock.odX ?? 0, height: stock.odY ?? 0, depth: stock.length), isCuttable: true, stockInfo: stock)
                case .unknown: shapeData = ShapeData(type: .custom, dimensions: nil, isCuttable: false)
                }
            } else {
                shapeData = ShapeData(type: .custom, dimensions: nil, isCuttable: false)
            }

            return (Mesh3D(vertices: rawVertices, faces: flattenedFaces, normals: flattenedNormals, shapeData: shapeData), stockInfo)
        }

    private static func detectFeatures(vertices: [SCNVector3], faces: [[Int]],
                                           axis: SIMD3<Float>, stockInfo: StockInfo) {
            
            let normalizedAxis = normalize(axis)
            var tempUp = SIMD3<Float>(0, 1, 0)
            if abs(normalizedAxis.y) > 0.9 { tempUp = SIMD3<Float>(1, 0, 0) }
            let uVec = normalize(cross(tempUp, normalizedAxis))
            let vVec = normalize(cross(normalizedAxis, uVec))

            // 1. Vertex Merging (Heals STEP Seams)
            struct HashablePoint: Hashable {
                let x: Int, y: Int, z: Int
                init(_ v: SCNVector3) {
                    self.x = Int(round(v.x * 1000)); self.y = Int(round(v.y * 1000)); self.z = Int(round(v.z * 1000))
                }
            }
            
            var uniqueVertices: [SCNVector3] = []
            var vertexMap: [Int] = Array(repeating: 0, count: vertices.count)
            var pointToIndex: [HashablePoint: Int] = [:]
            
            for (i, v) in vertices.enumerated() {
                let hp = HashablePoint(v)
                if let existing = pointToIndex[hp] {
                    vertexMap[i] = existing
                } else {
                    let newIdx = uniqueVertices.count
                    uniqueVertices.append(v)
                    pointToIndex[hp] = newIdx
                    vertexMap[i] = newIdx
                }
            }
            
            var mergedFaces: [[Int]] = []
            for face in faces {
                let mapped = face.map { vertexMap[$0] }
                if mapped.count >= 3 && mapped[0] != mapped[1] && mapped[1] != mapped[2] && mapped[2] != mapped[0] {
                    mergedFaces.append(mapped)
                }
            }

            // 2. Find Core Geometry Center & True Physical Bounds
            var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
            var minU = Float.greatestFiniteMagnitude, maxU = -Float.greatestFiniteMagnitude
            var minV = Float.greatestFiniteMagnitude, maxV = -Float.greatestFiniteMagnitude
            
            for v in uniqueVertices {
                let pos = SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
                let axial = dot(pos, normalizedAxis)
                let u = dot(pos, uVec); let vPos = dot(pos, vVec)
                if axial < minX { minX = axial }; if axial > maxX { maxX = axial }
                if u < minU { minU = u }; if u > maxU { maxU = u }
                if vPos < minV { minV = vPos }; if vPos > maxV { maxV = vPos }
            }
            
            let centerU = (minU + maxU) / 2.0; let centerV = (minV + maxV) / 2.0
            let tubeLength = maxX - minX
            
            // Dynamically derived boundaries directly from the mesh
            let maxAbsU = (maxU - minU) / 2.0
            let maxAbsV = (maxV - minV) / 2.0

            // 3. Identify Outer Wall Triangles universally
            var isOuterWall = Array(repeating: false, count: mergedFaces.count)
            
            for (i, face) in mergedFaces.enumerated() {
                let v0 = uniqueVertices[face[0]]
                let v1 = uniqueVertices[face[1]]
                let v2 = uniqueVertices[face[2]]
                
                let centerX = (v0.x + v1.x + v2.x) / 3.0
                let centerY = (v0.y + v1.y + v2.y) / 3.0
                let centerZ = (v0.z + v1.z + v2.z) / 3.0
                let center = SIMD3<Float>(Float(centerX), Float(centerY), Float(centerZ))
                
                let e1x = v1.x - v0.x
                let e1y = v1.y - v0.y
                let e1z = v1.z - v0.z
                
                let e2x = v2.x - v0.x
                let e2y = v2.y - v0.y
                let e2z = v2.z - v0.z
                
                let nx = e1y * e2z - e1z * e2y
                let ny = e1z * e2x - e1x * e2z
                let nz = e1x * e2y - e1y * e2x
                
                let lenSquared = nx * nx + ny * ny + nz * nz
                let len = sqrt(lenSquared)
                let faceNormal = len > 1e-6 ? SIMD3<Float>(Float(nx/len), Float(ny/len), Float(nz/len)) : SIMD3<Float>(0, 0, 1)
                
                let axialComponent = abs(dot(faceNormal, normalizedAxis))
                
                if axialComponent < 0.3 {
                    let u = dot(center, uVec) - centerU
                    let vPos = dot(center, vVec) - centerV
                    let normU = dot(faceNormal, uVec)
                    let normV = dot(faceNormal, vVec)
                    
                    // outwardDot isolates inner walls/cut faces from outer faces
                    let outwardDot = u * normU + vPos * normV
                    
                    if outwardDot > 2.0 {
                        if stockInfo.profile == .round {
                            if outwardDot > maxAbsU - 5.0 { isOuterWall[i] = true }
                        } else {
                            // Mathematically maps the exact dimensions of the rectangular box
                            let maxTheoreticalDot = maxAbsU * abs(normU) + maxAbsV * abs(normV)
                            
                            // Corner radii cause the dot product to drop slightly off theoretical max
                            let isCornerNormal = abs(normU) > 0.15 && abs(normV) > 0.15
                            let tolerance: Float = isCornerNormal ? 15.0 : 2.5
                            
                            if outwardDot > maxTheoreticalDot - tolerance {
                                isOuterWall[i] = true
                            }
                        }
                    }
                }
            }

            // 4. Extract Boundary Edges Topologically
            struct Edge: Hashable {
                let a: Int, b: Int
                init(_ v1: Int, _ v2: Int) { self.a = min(v1, v2); self.b = max(v1, v2) }
            }
            
            var edgeCount: [Edge: Int] = [:]
            for (i, face) in mergedFaces.enumerated() where isOuterWall[i] {
                let edges = [Edge(face[0], face[1]), Edge(face[1], face[2]), Edge(face[2], face[0])]
                for e in edges { edgeCount[e, default: 0] += 1 }
            }
            
            var adjacency: [Int: [Int]] = [:]
            for (e, count) in edgeCount where count == 1 {
                adjacency[e.a, default: []].append(e.b)
                adjacency[e.b, default: []].append(e.a)
            }

            // 5. Chain Edges into Closed Feature Loops
            var visitedVertices = Set<Int>()
            var loops: [[Int]] = []
            
            for startVertex in adjacency.keys {
                if visitedVertices.contains(startVertex) { continue }
                
                var loop: [Int] = []
                var current = startVertex
                var previous = -1
                
                while true {
                    loop.append(current)
                    visitedVertices.insert(current)
                    
                    let neighbors = adjacency[current] ?? []
                    var next = -1
                    for n in neighbors where n != previous && !visitedVertices.contains(n) {
                        next = n
                        break
                    }
                    
                    if next == -1 { break }
                    previous = current
                    current = next
                }
                if loop.count >= 3 { loops.append(loop) }
            }

            // 6. Process Loops into Classified Features
            var featureId = 1
            stockInfo.features.removeAll()
            
            for loopIndices in loops {
                var pathPoints2D: [ToolpathPoint] = []
                var loopMinX = Float.greatestFiniteMagnitude, loopMaxX = -Float.greatestFiniteMagnitude
                var loopMinU = Float.greatestFiniteMagnitude, loopMaxU = -Float.greatestFiniteMagnitude
                var loopMinV = Float.greatestFiniteMagnitude, loopMaxV = -Float.greatestFiniteMagnitude
                
                for idx in loopIndices {
                    let pos = uniqueVertices[idx]
                    let axial = dot(SIMD3<Float>(Float(pos.x), Float(pos.y), Float(pos.z)), normalizedAxis) - minX
                    if axial < loopMinX { loopMinX = axial }; if axial > loopMaxX { loopMaxX = axial }
                    
                    let u = dot(SIMD3<Float>(Float(pos.x), Float(pos.y), Float(pos.z)), uVec) - centerU
                    let vPos = dot(SIMD3<Float>(Float(pos.x), Float(pos.y), Float(pos.z)), vVec) - centerV
                    if u < loopMinU { loopMinU = u }; if u > loopMaxU { loopMaxU = u }
                    if vPos < loopMinV { loopMinV = vPos }; if vPos > loopMaxV { loopMaxV = vPos }
                    
                    var angle = atan2(Double(vPos), Double(u)) * 180.0 / .pi
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
                
                // Replaces the non-linear unwrapped angle arc length calculation
                let transverseWidth = CGFloat(max(loopMaxU - loopMinU, loopMaxV - loopMinV))
                
                let touchesStart = loopMinX <= 5.0
                let touchesEnd = loopMaxX >= Float(tubeLength) - 5.0
                let isFullProfile = heightDeg > 340.0
                
                var type: SurfaceFeatureType
                let shape: FeatureShape = .rectangle
                
                if isFullProfile && touchesStart { type = .startCut }
                else if isFullProfile && touchesEnd { type = .endCut }
                else if touchesStart || touchesEnd { type = .notch }
                else { type = .cutout }
                
                var unwrappedPath: [ToolpathPoint] = []
                
                if type == .startCut || type == .endCut {
                    var profileDict: [Int: CGFloat] = [:]
                    for pt in pathPoints2D {
                        let deg = Int(round(pt.a)) % 360
                        let currentX = profileDict[deg]
                        if type == .startCut {
                            profileDict[deg] = currentX == nil ? pt.x : max(currentX!, pt.x)
                        } else {
                            profileDict[deg] = currentX == nil ? pt.x : min(currentX!, pt.x)
                        }
                    }
                    unwrappedPath = profileDict.keys.sorted().map { ToolpathPoint(x: profileDict[$0]!, a: CGFloat($0)) }
                    if !unwrappedPath.isEmpty { unwrappedPath.append(ToolpathPoint(x: unwrappedPath[0].x, a: 360.0)) }
                    
                } else {
                    unwrappedPath.append(pathPoints2D[0])
                    for i in 1..<pathPoints2D.count {
                        var currentA = pathPoints2D[i].a
                        let prevA = unwrappedPath.last!.a
                        while currentA - prevA > 180.0 { currentA -= 360.0 }
                        while currentA - prevA < -180.0 { currentA += 360.0 }
                        unwrappedPath.append(ToolpathPoint(x: pathPoints2D[i].x, a: currentA))
                    }
                    var firstA = pathPoints2D[0].a
                    let lastA = unwrappedPath.last!.a
                    while firstA - lastA > 180.0 { firstA -= 360.0 }
                    while firstA - lastA < -180.0 { firstA += 360.0 }
                    unwrappedPath.append(ToolpathPoint(x: pathPoints2D[0].x, a: firstA))
                }
                
                var dimensions: [String: CGFloat] = ["width": width, "angle": heightDeg]
                
                // True generic hole check: Validates 3D physical width vs height without unwrapping errors
                if type == .cutout && abs(width - transverseWidth) < 5.0 {
                    type = .hole
                    dimensions["diameter"] = width
                }
                
                let feature = SurfaceFeature(id: featureId, type: type, shape: shape, xCenter: xCenter, aCenterDeg: aCenter, dimensions: dimensions, confidence: 1.0)
                feature.path = unwrappedPath
                stockInfo.features.append(feature)
                featureId += 1
            }
        }
    
        private static func groupFeatureVertices(_ vertices: [(vertex: SCNVector3, axialPos: CGFloat, angle: CGFloat)])
        -> [[(vertex: SCNVector3, axialPos: CGFloat, angle: CGFloat)]] {
            var groups: [[(vertex: SCNVector3, axialPos: CGFloat, angle: CGFloat)]] = []
            
            for item in vertices {
                var assignedToGroup = -1
                
                for (groupIdx, group) in groups.enumerated() {
                    for existing in group {
                        let axialDist = abs(item.axialPos - existing.axialPos)
                        let angleDist = min(abs(item.angle - existing.angle), 360 - abs(item.angle - existing.angle))
                        
                        // Group vertices that are close together (forms the perimeter of the cut)
                        if axialDist < 15 && angleDist < 20 {
                            assignedToGroup = groupIdx
                            break
                        }
                    }
                    if assignedToGroup >= 0 { break }
                }
                
                if assignedToGroup >= 0 {
                    groups[assignedToGroup].append(item)
                } else {
                    groups.append([item])
                }
            }
            
            return groups
        }
   
}

// MARK: - Helper Extensions

extension SCNVector3 {
    static func + (lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 {
        let x = lhs.x + rhs.x
        let y = lhs.y + rhs.y
        let z = lhs.z + rhs.z
        return SCNVector3(x, y, z)
    }

    static func - (lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 {
        let x = lhs.x - rhs.x
        let y = lhs.y - rhs.y
        let z = lhs.z - rhs.z
        return SCNVector3(x, y, z)
    }
}

func * (lhs: SCNVector3, rhs: Float) -> SCNVector3 {
    let x = Float(lhs.x) * rhs
    let y = Float(lhs.y) * rhs
    let z = Float(lhs.z) * rhs
    return SCNVector3(x, y, z)
}

func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    return a.x * b.x + a.y * b.y + a.z * b.z
}

func length(_ v: SIMD3<Float>) -> Float {
    return sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
}

// MARK: - SceneKit Geometry Extraction Helpers
extension SCNGeometry {
    func getVertices() -> [SCNVector3] {
        guard let source = self.sources(for: .vertex).first else { return [] }
        return source.extractSCNVector3()
    }
    
    func getNormals() -> [SCNVector3] {
        guard let source = self.sources(for: .normal).first else { return [] }
        return source.extractSCNVector3()
    }
}

extension SCNGeometrySource {
    func extractSCNVector3() -> [SCNVector3] {
        var vectors = [SCNVector3]()
        let stride = self.dataStride
        let offset = self.dataOffset
        let bytesPerComponent = self.bytesPerComponent
        
        self.data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let baseAddress = buffer.baseAddress else { return }
            for i in 0..<self.vectorCount {
                let vectorData = baseAddress.advanced(by: i * stride + offset)
                let x = vectorData.load(as: Float.self)
                let y = vectorData.advanced(by: bytesPerComponent).load(as: Float.self)
                let z = vectorData.advanced(by: bytesPerComponent * 2).load(as: Float.self)
                vectors.append(SCNVector3(x, y, z))
            }
        }
        return vectors
    }
}
