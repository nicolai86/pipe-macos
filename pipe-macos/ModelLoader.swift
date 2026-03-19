import Foundation
import SceneKit
import simd

// MARK: - Data Structures

struct Model3D {
    var name: String
    var meshes: [Mesh]
    var vertexCount: Int
    var faceCount: Int
    var stockInfo: StockInfo?  // Added stock classification info
}

struct Mesh {
    var vertices: [SCNVector3]
    var faces: [[Int]]
    var normals: [SCNVector3]?  // Added face normals
    var color: NSColor
    var shapeData: ShapeData?
}

struct ShapeData {
    enum ShapeType: String {
        case cylinder
        case box
        case unknown
    }

    var type: ShapeType
    var dimensions: Any?
    var isCuttable: Bool
}

struct CylinderDimensions {
    var diameter: CGFloat
    var height: CGFloat
    var axis: SCNVector3
}

struct BoxDimensions {
    var width: CGFloat
    var height: CGFloat
    var depth: CGFloat
}

struct SelectedShape {
    var shapeType: String
    var dimensions: Any?
    var isCuttable: Bool
    var node: SCNNode?
}

// MARK: - Stock Classification (per KB Section 2)

/// Stock profile classification output
struct StockInfo {
    enum ProfileType: String {
        case round
        case rectangular
        case square
        case unknown
    }
    
    var profile: ProfileType
    var od: CGFloat?           // Outer diameter (round tubes)
    var odX: CGFloat?          // Outer width (rectangular/square)
    var odY: CGFloat?          // Outer height (rectangular/square)
    var wallThickness: CGFloat?
    var length: CGFloat
    var axisVector: SCNVector3  // Normalized tube axis in STL space
    var centroid: SCNVector3    // Cross-section centroid
    var stlToMachineTransform: matrix_float4x4  // Transform to machine coordinates
    
    // Inner/Outer surface detection for hollow tubes
    var outerRadius: CGFloat?   // Actual detected outer radius (for filtering features)
    var innerRadius: CGFloat?   // Actual detected inner radius (nil for solid tubes)
    
    // End cut information (KB Section 3)
    var startEndCut: EndCutInfo?
    var endEndCut: EndCutInfo?
    
    // Detected features (KB Section 4)
    var features: [SurfaceFeature] = []
}

/// End cut classification (KB Section 3)
struct EndCutInfo {
    enum CutType: String {
        case square
        case miter
        case compoundMiter
    }
    
    var end: String             // "start" or "end"
    var type: CutType
    var miterAngleDeg: CGFloat  // 0 for square cut
    var miterDirectionDeg: CGFloat  // Angular orientation (round tubes)
    var xAtCenterline: CGFloat  // Where cut plane intersects tube axis
}

/// Surface feature classification (KB Section 4)
struct SurfaceFeature {
    enum FeatureType: String {
        case hole
        case notch
        case cope
        case scallop
    }
    
    enum Shape: String {
        case round
        case rectangular
        case custom
    }
    
    var id: Int
    var type: FeatureType
    var shape: Shape
    var xCenter: CGFloat        // Position along tube axis
    var aCenterDeg: CGFloat     // Angular position (degrees)
    var dimensions: [String: CGFloat]  // diameter, width, height, depth, etc.
    var normalAngleDeg: CGFloat // Hole normal angle (for angled holes)
    var end: String?            // For notches: "start" or "end"
    var confidence: CGFloat = 1.0  // Detection confidence 0-1
    var warnings: [String] = []    // Validation warnings
    
    /// Validate feature per KB Section 12
    func validate(stockInfo: StockInfo) -> (isValid: Bool, errors: [String]) {
        var errors: [String] = []
        
        // Check hole diameter vs wall thickness
        if type == .hole, shape == .round {
            if let diameter = dimensions["diameter"], let wall = stockInfo.wallThickness {
                if diameter < wall * 2 {
                    errors.append("Hole diameter (\(String(format: "%.1f", diameter))mm) < 2× wall thickness - may not cut cleanly")
                }
            }
        }
        
        // Check distance to tube end
        let tubeLength = stockInfo.length
        let distToStart = abs(xCenter)
        let distToEnd = abs(xCenter - tubeLength)
        
        if type == .hole {
            if let diameter = dimensions["diameter"] {
                let radius = diameter / 2
                if distToStart < radius + 5 || distToEnd < radius + 5 {
                    errors.append("Hole too close to end (< radius + 5mm) - may interfere with end cut")
                }
            }
        }
        
        // Check miter angle limits
        if type == .notch, let angle = dimensions["angle"] {
            if angle > 75 {
                errors.append("Notch angle (\(String(format: "%.1f", angle))°) > 75° - impractical for plasma cutting")
            }
        }
        
        return (errors.isEmpty, errors)
    }
}

// MARK: - Mesh Quality

struct MeshQualityReport {
    var isWatertight: Bool
    var hasConsistentNormals: Bool
    var degenerateTriangles: Int
    var totalTriangles: Int
    var warnings: [String]
}

enum ModelLoadError: Error {
    case unsupportedFormat
    case fileNotFound
    case parseError(String)
    case meshQualityError(String)
}

class ModelLoader {
    // MARK: - Public API
    
    static func load(url: URL) throws -> Model3D {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "stl":
            return try loadSTL(from: url)
        case "obj":
            return try loadOBJ(from: url)
        case "step", "stp":
            return try loadSTEP(from: url)
        default:
            // Try STL as fallback
            return try loadSTL(from: url)
        }
    }

    // MARK: - STL Loading
    
    private static func loadSTL(from url: URL) throws -> Model3D {
        print("Loading STL file: \(url.path)")
        let data = try Data(contentsOf: url)
        let content = String(data: data, encoding: .utf8) ?? ""

        print("  File size: \(data.count) bytes")
        print("  Content preview: \(content.prefix(100))")

        var vertices: [SCNVector3] = []
        var faces: [[Int]] = []
        var normals: [SCNVector3] = []  // Store face normals

        // Check if ASCII STL (first 5 chars should be "solid")
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let binary = isBinarySTL(data: data)
        print("  Is binary: \(binary)")

        if trimmedContent.hasPrefix("solid") && !binary {
            // Parse ASCII STL
            print("Parsing ASCII STL...")
            try parseAsciiSTL(content: content, vertices: &vertices, faces: &faces, normals: &normals)
        } else {
            // Parse binary STL
            print("Parsing binary STL...")
            try parseBinarySTL(data: data, vertices: &vertices, faces: &faces, normals: &normals)
        }

        // Mesh quality checks (KB Section 5)
        print("  Running mesh quality checks...")
        let qualityReport = checkMeshQuality(vertices: vertices, faces: faces, normals: normals)
        print("  Watertight: \(qualityReport.isWatertight)")
        print("  Degenerate triangles: \(qualityReport.degenerateTriangles)/\(qualityReport.totalTriangles)")
        
        if !qualityReport.warnings.isEmpty {
            for warning in qualityReport.warnings {
                print("  WARNING: \(warning)")
            }
        }
        
        if qualityReport.degenerateTriangles > qualityReport.totalTriangles / 10 {
            throw ModelLoadError.meshQualityError("Too many degenerate triangles: \(qualityReport.degenerateTriangles)")
        }

        // Segment mesh into connected components
        let segmentedMeshes = segmentMesh(vertices: vertices, faces: faces, normals: normals)

        print("  Segmented into \(segmentedMeshes.count) separate meshes")
        
        // Stock classification pipeline (KB Section 2 & 5)
        var stockInfo: StockInfo? = nil
        if let firstMesh = segmentedMeshes.first {
            stockInfo = classifyStock(vertices: firstMesh.vertices, faces: firstMesh.faces, normals: firstMesh.normals ?? [])
            if let info = stockInfo {
                print("  Stock classification: \(info.profile.rawValue) tube")
                print("  OD: \(info.od ?? 0) mm, Length: \(info.length) mm")
                print("  Axis: (\(info.axisVector.x), \(info.axisVector.y), \(info.axisVector.z))")
            }
        }

        return Model3D(
            name: url.deletingPathExtension().lastPathComponent,
            meshes: segmentedMeshes,
            vertexCount: vertices.count,
            faceCount: faces.count,
            stockInfo: stockInfo
        )
    }
    
    /// Parse ASCII STL with normal vectors
    private static func parseAsciiSTL(content: String, vertices: inout [SCNVector3], faces: inout [[Int]], normals: inout [SCNVector3]) throws {
        let lines = content.components(separatedBy: .newlines)
        var currentNormal: SCNVector3?
        var vertexIndices: [Int] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("facet normal") {
                // Parse face normal
                let components = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if components.count >= 4 {
                    let nx = CGFloat(Double(components[1]) ?? 0)
                    let ny = CGFloat(Double(components[2]) ?? 0)
                    let nz = CGFloat(Double(components[3]) ?? 0)
                    currentNormal = SCNVector3(nx, ny, nz)
                }
            } else if trimmed.hasPrefix("vertex") {
                // Parse vertex
                let components = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if components.count >= 4 {
                    let x = CGFloat(Double(components[1]) ?? 0)
                    let y = CGFloat(Double(components[2]) ?? 0)
                    let z = CGFloat(Double(components[3]) ?? 0)
                    vertices.append(SCNVector3(x, y, z))
                    vertexIndices.append(vertices.count - 1)
                }
            } else if trimmed.hasPrefix("endfacet") {
                // End of facet - create face
                if vertexIndices.count >= 3 {
                    faces.append([vertexIndices[0], vertexIndices[1], vertexIndices[2]])
                    normals.append(currentNormal ?? SCNVector3(0, 0, 1))
                }
                vertexIndices = []
                currentNormal = nil
            }
        }
        
        print("  Loaded \(vertices.count) vertices, \(faces.count) faces")
    }

    /// Segment a mesh into connected components based on vertex proximity
    private static func segmentMesh(vertices: [SCNVector3], faces: [[Int]], normals: [SCNVector3]) -> [Mesh] {
        guard !faces.isEmpty else { return [] }

        let epsilon: CGFloat = 0.001

        // Build a spatial lookup
        var vertexGrid: [String: [Int]] = [:]

        func gridKey(for vertex: SCNVector3) -> String {
            let gx = Int(vertex.x / epsilon)
            let gy = Int(vertex.y / epsilon)
            let gz = Int(vertex.z / epsilon)
            return "\(gx),\(gy),\(gz)"
        }

        for (i, v) in vertices.enumerated() {
            let key = gridKey(for: v)
            vertexGrid[key, default: []].append(i)
        }

        func nearbyVertices(for vertex: SCNVector3) -> [Int] {
            let gx = Int(vertex.x / epsilon)
            let gy = Int(vertex.y / epsilon)
            let gz = Int(vertex.z / epsilon)

            var nearby: [Int] = []
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        let key = "\(gx + dx),\(gy + dy),\(gz + dz)"
                        nearby.append(contentsOf: vertexGrid[key] ?? [])
                    }
                }
            }
            return nearby
        }

        // Union-Find for faces
        var parent = Array(0..<faces.count)

        func find(_ x: Int) -> Int {
            if parent[x] != x {
                parent[x] = find(parent[x])
            }
            return parent[x]
        }

        func union(_ x: Int, _ y: Int) {
            let px = find(x)
            let py = find(y)
            if px != py {
                parent[px] = py
            }
        }

        // Build vertex-to-face mapping
        var vertexToFaces: [Int: [Int]] = [:]
        for (faceIdx, face) in faces.enumerated() {
            for vertexIdx in face {
                vertexToFaces[vertexIdx, default: []].append(faceIdx)
            }
        }

        // Union faces that share nearby vertices
        for (faceIdx, face) in faces.enumerated() {
            for vertexIdx in face {
                let vertex = vertices[vertexIdx]
                let nearby = nearbyVertices(for: vertex)

                for nearbyVertexIdx in nearby {
                    guard nearbyVertexIdx != vertexIdx else { continue }

                    let otherVertex = vertices[nearbyVertexIdx]
                    let dist = sqrt(pow(vertex.x - otherVertex.x, 2) +
                                   pow(vertex.y - otherVertex.y, 2) +
                                   pow(vertex.z - otherVertex.z, 2))

                    if dist < epsilon {
                        if let connectedFaces = vertexToFaces[nearbyVertexIdx] {
                            for otherFaceIdx in connectedFaces {
                                if otherFaceIdx > faceIdx {
                                    union(faceIdx, otherFaceIdx)
                                }
                            }
                        }
                    }
                }
            }
        }

        // Group faces by root
        var componentFaces: [Int: [Int]] = [:]
        for faceIdx in 0..<faces.count {
            let root = find(faceIdx)
            componentFaces[root, default: []].append(faceIdx)
        }

        print("  Found \(componentFaces.count) connected components")

        // Create meshes
        var meshes: [Mesh] = []
        for faceIndices in componentFaces.values {
            var vertexSet = Set<Int>()
            for faceIdx in faceIndices {
                for vertexIdx in faces[faceIdx] {
                    vertexSet.insert(vertexIdx)
                }
            }

            var vertexMap: [Int: Int] = [:]
            var newVertices: [SCNVector3] = []
            var newNormals: [SCNVector3] = []
            for oldIdx in vertexSet {
                vertexMap[oldIdx] = newVertices.count
                newVertices.append(vertices[oldIdx])
            }

            var newFaces: [[Int]] = []
            for oldFaceIdx in faceIndices {
                var newFace: [Int] = []
                for oldVertexIdx in faces[oldFaceIdx] {
                    newFace.append(vertexMap[oldVertexIdx]!)
                }
                newFaces.append(newFace)
                newNormals.append(normals[oldFaceIdx])
            }

            let shapeData = analyzeShape(vertices: newVertices, faces: newFaces)

            let mesh = Mesh(
                vertices: newVertices,
                faces: newFaces,
                normals: newNormals,
                color: NSColor.systemBlue,
                shapeData: shapeData
            )
            meshes.append(mesh)
        }

        return meshes
    }
    
    /// Check if STL file is binary (not ASCII)
    private static func isBinarySTL(data: Data) -> Bool {
        // Binary STL files have an 80-byte header + 4-byte triangle count
        // If the file contains null bytes in the first 80 bytes, it's binary
        if data.count < 84 { return true }
        
        let header = data.subdata(in: 0..<80)
        for byte in header {
            if byte == 0 { return true }
        }
        
        // Also check if "solid" is followed by binary data
        if let firstLine = String(data: header, encoding: .utf8),
           firstLine.hasPrefix("solid") {
            // Check if there are non-printable characters
            for byte in header {
                if byte < 32 && byte != 0 && byte != 9 && byte != 10 && byte != 13 {
                    return true
                }
            }
        }
        
        return false
    }
    
    private static func parseBinarySTL(data: Data, vertices: inout [SCNVector3], faces: inout [[Int]], normals: inout [SCNVector3]) throws {
        guard data.count >= 84 else {
            throw ModelLoadError.parseError("Invalid binary STL file")
        }

        let header = data.subdata(in: 0..<80)
        let numTriangles = data.subdata(in: 80..<84).withUnsafeBytes { $0.load(as: UInt32.self) }

        print("  Binary STL with \(numTriangles) triangles")

        var vertexOffset = 84
        let faceSize = 50 // 12 (normal) + 36 (3 vertices * 12) + 2 (attribute)

        for i in 0..<numTriangles {
            if vertexOffset + faceSize > data.count {
                print("  Warning: Unexpected end of file at triangle \(i)")
                break
            }

            let faceData = data.subdata(in: vertexOffset..<(vertexOffset + faceSize))

            // Read normal vector (12 bytes)
            let nx = faceData.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: Float.self) }
            let ny = faceData.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: Float.self) }
            let nz = faceData.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: Float.self) }
            normals.append(SCNVector3(CGFloat(nx), CGFloat(ny), CGFloat(nz)))
            
            // Read 3 vertices (36 bytes)
            for j in 0..<3 {
                let offset = 12 + (j * 12)
                let x = faceData.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: Float.self) }
                let y = faceData.subdata(in: (offset + 4)..<(offset + 8)).withUnsafeBytes { $0.load(as: Float.self) }
                let z = faceData.subdata(in: (offset + 8)..<(offset + 12)).withUnsafeBytes { $0.load(as: Float.self) }
                vertices.append(SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z)))
            }

            // Create face
            let baseIndex = vertices.count - 3
            faces.append([baseIndex, baseIndex + 1, baseIndex + 2])

            vertexOffset += faceSize
        }

        print("  Loaded \(vertices.count) vertices, \(faces.count) faces")
    }
    
    private static func loadOBJ(from url: URL) throws -> Model3D {
        print("Parsing OBJ file...")
        let content = try String(contentsOf: url, encoding: .utf8)
        var vertices: [SCNVector3] = []
        var faces: [[Int]] = []
        var vertexCount = 0
        var faceCount = 0

        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("v ") {
                // Parse vertex - handle various formats:
                // v x y z
                // v x y z w
                let components = trimmed.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }

                if components.count >= 4 {
                    let x = CGFloat(Double(components[1]) ?? 0)
                    let y = CGFloat(Double(components[2]) ?? 0)
                    let z = CGFloat(Double(components[3]) ?? 0)
                    vertices.append(SCNVector3(x, y, z))
                    vertexCount += 1
                }
            } else if trimmed.hasPrefix("f ") {
                // Parse face - handle various formats:
                // f v1 v2 v3
                // f v1/vt1 v2/vt2 v3/vt3
                // f v1/vt1/vn1 v2/vt2/vn2 v3/vt3/vn3
                // f v1//vn1 v2//vn2 v3//vn3
                let components = trimmed.components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }

                var face: [Int] = []
                for i in 1..<components.count {
                    let vertexPart = components[i]
                    // Extract vertex index (before first /)
                    let indexString = vertexPart.components(separatedBy: "/")[0]
                    if let index = Int(indexString) {
                        // OBJ uses 1-based indexing, convert to 0-based
                        // Handle negative indices (relative to current position)
                        if index < 0 {
                            face.append(vertices.count + index)
                        } else {
                            face.append(index - 1)
                        }
                    }
                }

                // Triangulate polygon if it has more than 3 vertices
                if face.count >= 3 {
                    if face.count == 3 {
                        faces.append(face)
                        faceCount += 1
                    } else {
                        // Create triangle fan for polygons with > 3 vertices
                        for i in 1..<(face.count - 1) {
                            faces.append([face[0], face[i], face[i + 1]])
                            faceCount += 1
                        }
                    }
                }
            }
        }

        print("  Loaded \(vertexCount) vertices, \(faceCount) faces")

        let shapeData = analyzeShape(vertices: vertices, faces: faces)

        let mesh = Mesh(
            vertices: vertices,
            faces: faces,
            color: NSColor.systemGreen,
            shapeData: shapeData
        )

        return Model3D(
            name: url.deletingPathExtension().lastPathComponent,
            meshes: [mesh],
            vertexCount: vertices.count,
            faceCount: faces.count
        )
    }
    
    private static func loadSTEP(from url: URL) throws -> Model3D {
        // STEP AP214/242 B-Rep parser
        // Parses MANIFOLD_SOLID_BREP with FACE/EDGE/VERTEX topology
        
        let content = try String(contentsOf: url, encoding: .utf8)
        
        // First pass: extract all CARTESIAN_POINT entities
        // Format: #1216=CARTESIAN_POINT('',#1095,(25.7316904011157,0.,21.082));
        // or: #1216=CARTESIAN_POINT('',(25.7316904011157,0.,21.082));
        var pointMap: [Int: SCNVector3] = [:]
        
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Match CARTESIAN_POINT with entity ID
            if trimmed.hasPrefix("#") && trimmed.contains("CARTESIAN_POINT") {
                // Extract entity ID
                guard let eqIndex = trimmed.firstIndex(of: "="),
                      let id = Int(String(trimmed[trimmed.index(after: trimmed.startIndex)..<eqIndex])) else {
                    continue
                }
                
                // Find the coordinate tuple - look for pattern (x,y,z) at the end
                // The coordinates are in the last set of parentheses
                if let lastOpen = trimmed.lastIndex(of: "("),
                   let lastClose = trimmed.lastIndex(of: ")"),
                   lastOpen < lastClose {
                    let coordString = String(trimmed[trimmed.index(after: lastOpen)..<lastClose])
                    let components = coordString.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    
                    if components.count >= 3,
                       let x = Double(components[0]),
                       let y = Double(components[1]),
                       let z = Double(components[2]) {
                        pointMap[id] = SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z))
                    }
                }
            }
        }
        
        print("  Found \(pointMap.count) CARTESIAN_POINT entities")
        
        // Second pass: extract VERTEX_POINT entities and map to Cartesian points
        // Format: #343=VERTEX_POINT('',#1206);
        var vertexToPointMap: [Int: Int] = [:]
        let vertexPattern = #"#(\d+)=VERTEX_POINT\s*\([^,]+,#(\d+)\)"#
        
        if let regex = try? NSRegularExpression(pattern: vertexPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            
            for match in matches {
                guard let idRange = Range(match.range(at: 1), in: content),
                      let pointRefRange = Range(match.range(at: 2), in: content) else {
                    continue
                }
                
                let vertexId = Int(String(content[idRange])) ?? 0
                let pointRefId = Int(String(content[pointRefRange])) ?? 0
                vertexToPointMap[vertexId] = pointRefId
            }
        }
        
        // Third pass: extract EDGE_CURVE entities
        // Format: #419=EDGE_CURVE('',#343,#345,#43,.T.);
        var edgeToVerticesMap: [Int: (Int, Int)] = [:]
        let edgePattern = #"#(\d+)=EDGE_CURVE\s*\([^,]+,#(\d+),#(\d+)"#
        
        if let regex = try? NSRegularExpression(pattern: edgePattern, options: .caseInsensitive) {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            
            for match in matches {
                guard let idRange = Range(match.range(at: 1), in: content),
                      let v1Range = Range(match.range(at: 2), in: content),
                      let v2Range = Range(match.range(at: 3), in: content) else {
                    continue
                }
                
                let edgeId = Int(String(content[idRange])) ?? 0
                let v1Id = Int(String(content[v1Range])) ?? 0
                let v2Id = Int(String(content[v2Range])) ?? 0
                edgeToVerticesMap[edgeId] = (v1Id, v2Id)
            }
        }
        
        // Fourth pass: extract ORIENTED_EDGE entities from EDGE_LOOP
        // Format: #527=ORIENTED_EDGE('',*,*,#415,.T.);
        // We need to find which edges are referenced by loops
        var loopEdges: [Int: [(edgeId: Int, orientation: Bool)]] = [:]
        let orientedEdgePattern = #"#(\d+)=ORIENTED_EDGE\s*\([^,]+,\*,\*,#(\d+),\.([TF])\.\)"#
        
        if let regex = try? NSRegularExpression(pattern: orientedEdgePattern, options: .caseInsensitive) {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            
            for match in matches {
                guard let loopIdRange = Range(match.range(at: 1), in: content),
                      let edgeIdRange = Range(match.range(at: 2), in: content),
                      let orientRange = Range(match.range(at: 3), in: content) else {
                    continue
                }
                
                let loopId = Int(String(content[loopIdRange])) ?? 0
                let edgeId = Int(String(content[edgeIdRange])) ?? 0
                let orientation = String(content[orientRange]) == "T"
                
                if loopEdges[loopId] == nil {
                    loopEdges[loopId] = []
                }
                loopEdges[loopId]?.append((edgeId, orientation))
            }
        }
        
        // Fifth pass: extract EDGE_LOOP references
        // Format: #275=EDGE_LOOP('',(#527,#528,#529,#530));
        var faceToLoopsMap: [Int: [Int]] = [:]
        let loopRefPattern = #"#(\d+)=EDGE_LOOP\s*\([^,]+,\(([^)]*)\)\)"#
        
        if let regex = try? NSRegularExpression(pattern: loopRefPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            
            for match in matches {
                guard let loopIdRange = Range(match.range(at: 1), in: content),
                      let refsRange = Range(match.range(at: 2), in: content) else {
                    continue
                }
                
                let loopId = Int(String(content[loopIdRange])) ?? 0
                let refsString = String(content[refsRange])
                
                // Parse edge references like #527,#528,#529,#530
                let edgeRefs = refsString.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .compactMap { ref -> Int? in
                        if ref.hasPrefix("#") {
                            return Int(String(ref.dropFirst()))
                        }
                        return nil
                    }
                
                // Store the edge IDs directly - these are ORIENTED_EDGE IDs
                faceToLoopsMap[loopId] = edgeRefs
            }
        }
        
        // Sixth pass: extract FACE_OUTER_BOUND
        // Format: #227=FACE_OUTER_BOUND('',#271,.T.);
        var faceToBoundsMap: [Int: Int] = [:]
        let faceBoundPattern = #"#(\d+)=FACE_OUTER_BOUND\s*\([^,]+,#(\d+)"#
        
        if let regex = try? NSRegularExpression(pattern: faceBoundPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            
            for match in matches {
                guard let faceIdRange = Range(match.range(at: 1), in: content),
                      let boundIdRange = Range(match.range(at: 2), in: content) else {
                    continue
                }
                
                let faceId = Int(String(content[faceIdRange])) ?? 0
                let boundId = Int(String(content[boundIdRange])) ?? 0
                faceToBoundsMap[faceId] = boundId
            }
        }
        
        // Now build the mesh by traversing the topology
        var vertices: [SCNVector3] = []
        var faces: [[Int]] = []
        
        // Helper to find or add vertex (using approximate equality)
        func findOrAddVertex(_ vertex: SCNVector3) -> Int {
            for (i, v) in vertices.enumerated() {
                if abs(v.x - vertex.x) < 0.001 && 
                   abs(v.y - vertex.y) < 0.001 && 
                   abs(v.z - vertex.z) < 0.001 {
                    return i
                }
            }
            vertices.append(vertex)
            return vertices.count - 1
        }
        
        // Get all faces from MANIFOLD_SOLID_BREP
        // Format: #39=MANIFOLD_SOLID_BREP('...',#807);
        // #807=CLOSED_SHELL('',(#227,#228,...));
        let shellPattern = #"#(\d+)=CLOSED_SHELL\s*\([^,]+,\(([^)]*)\)\)"#
        var shellFaces: [Int] = []
        
        if let regex = try? NSRegularExpression(pattern: shellPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            
            for match in matches {
                guard let refsRange = Range(match.range(at: 2), in: content) else {
                    continue
                }
                
                let refsString = String(content[refsRange])
                shellFaces = refsString.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .compactMap { ref -> Int? in
                        if ref.hasPrefix("#") {
                            return Int(String(ref.dropFirst()))
                        }
                        return nil
                    }
            }
        }
        
        // Process each face
        for faceId in shellFaces {
            guard let boundId = faceToBoundsMap[faceId],
                  let edgeRefs = faceToLoopsMap[boundId] else {
                continue
            }
            
            // Build face vertices from edges
            var faceVertices: [SCNVector3] = []
            
            for orientedEdgeId in edgeRefs {
                guard let (edgeId, orientation) = loopEdges[orientedEdgeId]?.first ??
                          loopEdges[faceToLoopsMap[boundId]?.first ?? 0]?.first,
                      let (v1Id, v2Id) = edgeToVerticesMap[edgeId],
                      let point1Id = vertexToPointMap[v1Id],
                      let point2Id = vertexToPointMap[v2Id],
                      let point1 = pointMap[point1Id],
                      let point2 = pointMap[point2Id] else {
                    continue
                }
                
                let startVertex = orientation ? point1 : point2
                let endVertex = orientation ? point2 : point1
                
                // Add start vertex
                if faceVertices.isEmpty || distance(faceVertices.last!, startVertex) > 0.001 {
                    faceVertices.append(startVertex)
                }
                
                // Add end vertex
                if distance(faceVertices.last ?? startVertex, endVertex) > 0.001 {
                    faceVertices.append(endVertex)
                }
            }
            
            // Convert face vertices to indices and create faces (triangle fan)
            if faceVertices.count >= 3 {
                var faceIndices: [Int] = []
                
                for vertex in faceVertices {
                    let index = findOrAddVertex(vertex)
                    faceIndices.append(index)
                }
                
                // Create triangle fan
                for i in 1..<(faceIndices.count - 1) {
                    faces.append([faceIndices[0], faceIndices[i], faceIndices[i + 1]])
                }
            }
        }
        
        // If no faces were created, fall back to creating geometry from points
        if faces.isEmpty && !pointMap.isEmpty {
            print("  No faces created from B-Rep, falling back to \(pointMap.count) points")
            vertices = Array(pointMap.values)
            
            // Calculate bounding box for scaling
            var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
            var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
            var minZ = CGFloat.greatestFiniteMagnitude, maxZ = -CGFloat.greatestFiniteMagnitude
            
            for v in vertices {
                minX = min(minX, v.x); maxX = max(maxX, v.x)
                minY = min(minY, v.y); maxY = max(maxY, v.y)
                minZ = min(minZ, v.z); maxZ = max(maxZ, v.z)
            }
            
            let size = SCNVector3(maxX - minX, maxY - minY, maxZ - minZ)
            let center = SCNVector3((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
            
            // Create a bounding box wireframe to visualize the model extent
            let boxSize: CGFloat = 1.0
            let boxVertices: [SCNVector3] = [
                // Bottom face
                SCNVector3(-boxSize/2 + center.x, -boxSize/2 + center.y, -boxSize/2 + center.z),
                SCNVector3(boxSize/2 + center.x, -boxSize/2 + center.y, -boxSize/2 + center.z),
                SCNVector3(boxSize/2 + center.x, boxSize/2 + center.y, -boxSize/2 + center.z),
                SCNVector3(-boxSize/2 + center.x, boxSize/2 + center.y, -boxSize/2 + center.z),
                // Top face
                SCNVector3(-boxSize/2 + center.x, -boxSize/2 + center.y, boxSize/2 + center.z),
                SCNVector3(boxSize/2 + center.x, -boxSize/2 + center.y, boxSize/2 + center.z),
                SCNVector3(boxSize/2 + center.x, boxSize/2 + center.y, boxSize/2 + center.z),
                SCNVector3(-boxSize/2 + center.x, boxSize/2 + center.y, boxSize/2 + center.z),
            ]
            
            // For now, create simple triangles from point triplets
            // This won't be accurate but will show SOMETHING
            var tempVertices: [SCNVector3] = []
            for point in pointMap.values {
                tempVertices.append(point)
            }
            
            // Create faces from consecutive triplets
            for i in stride(from: 0, to: tempVertices.count - 2, by: 3) {
                faces.append([i, i + 1, i + 2])
            }
            
            vertices = tempVertices
            print("  Created \(faces.count) fallback triangles from \(vertices.count) vertices")
            print("  Bounding box: \(size.x) x \(size.y) x \(size.z)")
        }

        print("  STEP parsing complete: \(vertices.count) vertices, \(faces.count) faces")

        let shapeData = analyzeShape(vertices: vertices, faces: faces)

        let mesh = Mesh(
            vertices: vertices,
            faces: faces,
            color: NSColor.systemPurple,
            shapeData: shapeData
        )

        return Model3D(
            name: url.deletingPathExtension().lastPathComponent,
            meshes: [mesh],
            vertexCount: vertices.count,
            faceCount: faces.count
        )
    }
    
    private static func parseSTEPNumber(_ string: String) -> CGFloat {
        let cleaned = string.trimmingCharacters(in: .whitespaces)
        // Handle STEP scientific notation (e.g., 1.23E+02)
        if let value = Double(cleaned) {
            return CGFloat(value)
        }
        return 0
    }
    
    private static func distance(_ v1: SCNVector3, _ v2: SCNVector3) -> CGFloat {
        return sqrt(pow(v2.x - v1.x, 2) + pow(v2.y - v1.y, 2) + pow(v2.z - v1.z, 2))
    }

    // MARK: - Mesh Quality Checks (KB Section 5)
    
    /// Check mesh quality: watertightness, normal consistency, degenerate triangles
    private static func checkMeshQuality(vertices: [SCNVector3], faces: [[Int]], normals: [SCNVector3]) -> MeshQualityReport {
        var warnings: [String] = []
        var degenerateCount = 0
        let minTriangleArea: CGFloat = 0.001
        
        // Check triangle count
        if faces.count < 500 {
            warnings.append("Low triangle count (\(faces.count)) - may be too coarse for accurate feature detection")
        }
        
        // Build edge map for watertight check
        // Each edge should be shared by exactly 2 triangles
        var edgeMap: [String: Int] = [:]
        
        func edgeKey(_ v1: Int, _ v2: Int) -> String {
            return v1 < v2 ? "\(v1)-\(v2)" : "\(v2)-\(v1)"
        }
        
        for face in faces {
            guard face.count == 3 else { continue }
            
            // Check for degenerate triangles (zero area)
            let v0 = vertices[face[0]]
            let v1 = vertices[face[1]]
            let v2 = vertices[face[2]]
            
            // Compute triangle area using cross product
            let edge1 = SCNVector3(v1.x - v0.x, v1.y - v0.y, v1.z - v0.z)
            let edge2 = SCNVector3(v2.x - v0.x, v2.y - v0.y, v2.z - v0.z)
            let cross = SCNVector3(
                edge1.y * edge2.z - edge1.z * edge2.y,
                edge1.z * edge2.x - edge1.x * edge2.z,
                edge1.x * edge2.y - edge1.y * edge2.x
            )
            let area = 0.5 * sqrt(cross.x * cross.x + cross.y * cross.y + cross.z * cross.z)
            
            if area < minTriangleArea {
                degenerateCount += 1
            }
            
            // Count edges
            for i in 0..<3 {
                let key = edgeKey(face[i], face[(i + 1) % 3])
                edgeMap[key, default: 0] += 1
            }
        }
        
        // Check watertightness
        var nonManifoldEdges = 0
        var boundaryEdges = 0
        for (_, count) in edgeMap {
            if count == 1 {
                boundaryEdges += 1  // Open boundary
            } else if count > 2 {
                nonManifoldEdges += 1  // Non-manifold
            }
        }
        
        let isWatertight = (boundaryEdges == 0 && nonManifoldEdges == 0)
        
        if boundaryEdges > 0 {
            warnings.append("Mesh has \(boundaryEdges) boundary edges (not watertight)")
        }
        if nonManifoldEdges > 0 {
            warnings.append("Mesh has \(nonManifoldEdges) non-manifold edges")
        }
        
        // Check normal consistency
        var hasConsistentNormals = true
        if normals.count >= 2 {
            // Check if most normals point in similar direction (outward)
            // For a closed mesh, normals should generally point away from centroid
            let centroid = SCNVector3(
                vertices.reduce(0) { $0 + $1.x } / CGFloat(vertices.count),
                vertices.reduce(0) { $0 + $1.y } / CGFloat(vertices.count),
                vertices.reduce(0) { $0 + $1.z } / CGFloat(vertices.count)
            )
            
            var inwardCount = 0
            for (i, face) in faces.enumerated() {
                if i >= normals.count { break }
                guard face.count == 3 else { continue }
                
                let faceCenter = SCNVector3(
                    (vertices[face[0]].x + vertices[face[1]].x + vertices[face[2]].x) / 3,
                    (vertices[face[0]].y + vertices[face[1]].y + vertices[face[2]].y) / 3,
                    (vertices[face[0]].z + vertices[face[1]].z + vertices[face[2]].z) / 3
                )
                
                let toCenter = SCNVector3(centroid.x - faceCenter.x, centroid.y - faceCenter.y, centroid.z - faceCenter.z)
                let normal = normals[i]
                
                // Dot product should be positive if normal points outward
                let dot = toCenter.x * normal.x + toCenter.y * normal.y + toCenter.z * normal.z
                if dot < 0 {
                    inwardCount += 1
                }
            }
            
            if inwardCount > faces.count / 4 {
                hasConsistentNormals = false
                warnings.append("\(inwardCount) normals point inward (>25%)")
            }
        }
        
        return MeshQualityReport(
            isWatertight: isWatertight,
            hasConsistentNormals: hasConsistentNormals,
            degenerateTriangles: degenerateCount,
            totalTriangles: faces.count,
            warnings: warnings
        )
    }

    // MARK: - Stock Classification (KB Section 2)
    
    /// Classify stock from mesh using the new STLPipeline
    /// Uses: 1) Half-Edge segmentation, 2) EGI+PCA classification, 3) Least-squares fitting
    static func classifyStock(vertices: [SCNVector3], faces: [[Int]], normals: [SCNVector3]) -> StockInfo? {
        guard vertices.count > 10, faces.count > 0 else { return nil }
        
        print("  === NEW STL PIPELINE ===")
        
        // Use new pipeline for segmentation and classification
        do {
            let bodies = try STLPipeline.process(vertices: vertices, faces: faces, normals: normals)
            
            // For now, use the largest body (primary tube)
            guard let primaryBody = bodies.first else { return nil }
            
            // Detect inner/outer surfaces for hollow tubes
            print("  Analyzing surface boundaries...")
            let centroid = computeCentroid(vertices: vertices)
            let surfaceBoundaries = detectSurfaceBoundaries(vertices: vertices, axis: primaryBody.axis, centroid: centroid, profile: mapProfile(primaryBody.dimensions.profile))
            
            // Detect end cuts
            let startEndCut = detectEndCut(vertices: vertices, faces: faces, normals: normals, axis: primaryBody.axis, end: .start, length: primaryBody.dimensions.length)
            let endEndCut = detectEndCut(vertices: vertices, faces: faces, normals: normals, axis: primaryBody.axis, end: .end, length: primaryBody.dimensions.length)
            
            // Create StockInfo with all values
            var stockInfo = StockInfo(
                profile: mapProfile(primaryBody.dimensions.profile),
                od: primaryBody.dimensions.outerDiameter,
                odX: primaryBody.dimensions.width,
                odY: primaryBody.dimensions.height,
                wallThickness: surfaceBoundaries.inner != nil ? (surfaceBoundaries.outer.0 - surfaceBoundaries.inner!.0) : nil,
                length: primaryBody.dimensions.length,
                axisVector: primaryBody.axis,
                centroid: centroid,
                stlToMachineTransform: matrix_identity_float4x4,
                outerRadius: surfaceBoundaries.outer.0,
                innerRadius: surfaceBoundaries.inner?.0,
                startEndCut: startEndCut,
                endEndCut: endEndCut,
                features: []
            )
            
            // Detect features
            stockInfo.features = detectSurfaceFeatures(vertices: vertices, faces: faces, normals: normals, stockInfo: stockInfo)
            
            return stockInfo
            
        } catch {
            print("  Pipeline error: \(error)")
            return nil
        }
    }
    
    private static func mapProfile(_ profile: BodyDimensions.Profile) -> StockInfo.ProfileType {
        switch profile {
        case .round: return .round
        case .square: return .square
        case .rectangular: return .rectangular
        case .unknown: return .unknown
        }
    }
    
    // Legacy classifyStock function kept for compatibility

    /// Fit a circle to 2D points using Kåsa least-squares method
    /// Returns (centerX, centerY, radius) or nil if fit fails
    private static func fitCircle2D(points: [(x: CGFloat, y: CGFloat)]) -> (x: CGFloat, y: CGFloat, r: CGFloat)? {
        guard points.count >= 3 else { return nil }
        
        // Compute averages
        let sumX = points.reduce(0) { $0 + $1.x }
        let sumY = points.reduce(0) { $0 + $1.y }
        let n = CGFloat(points.count)
        let avgX = sumX / n
        let avgY = sumY / n
        
        // Compute covariance matrix components for Kåsa fit
        var sumXX: CGFloat = 0, sumYY: CGFloat = 0, sumXY: CGFloat = 0
        var sumXXX: CGFloat = 0, sumXYY: CGFloat = 0, sumYXX: CGFloat = 0, sumYYY: CGFloat = 0
        
        for p in points {
            let dx = p.x - avgX
            let dy = p.y - avgY
            sumXX += dx * dx
            sumYY += dy * dy
            sumXY += dx * dy
            sumXXX += dx * dx * dx
            sumXYY += dx * dy * dy
            sumYXX += dy * dx * dx
            sumYYY += dy * dy * dy
        }
        
        // Solve normal equations for Kåsa fit
        let det = sumXX * sumYY - sumXY * sumXY
        if abs(det) < 0.0001 { return nil }  // Points are collinear
        
        let B = (sumXX * (sumXXX + sumXYY) - sumXY * (sumYXX + sumYYY)) / (2 * det)
        let A = (sumYY * (sumYXX + sumYYY) - sumXY * (sumXXX + sumXYY)) / (2 * det)
        
        let centerX = avgX + A
        let centerY = avgY + B
        
        // Compute radius as average distance from center
        var sumR: CGFloat = 0
        for p in points {
            let dx = p.x - centerX
            let dy = p.y - centerY
            sumR += sqrt(dx * dx + dy * dy)
        }
        let radius = sumR / n
        
        return (centerX, centerY, radius)
    }

    /// Fit a cylinder to 3D vertices using least-squares
    /// Returns the cylinder radius, or nil if fit fails
    private static func fitCylinder(vertices: [SCNVector3], axis: SCNVector3) -> CGFloat? {
        guard vertices.count >= 10 else { return nil }
        
        // Project vertices onto plane perpendicular to axis
        var projectedPoints: [(x: CGFloat, y: CGFloat)] = []
        
        // Create orthonormal basis for the cross-section plane
        let axisNorm = sqrt(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z)
        let ax = axis.x / axisNorm
        let ay = axis.y / axisNorm
        let az = axis.z / axisNorm
        
        // Find two orthogonal vectors perpendicular to axis
        var u: SCNVector3, v: SCNVector3
        if abs(ax) < 0.9 {
            u = SCNVector3(ay, -ax, 0)
        } else {
            u = SCNVector3(0, az, -ay)
        }
        let uNorm = sqrt(u.x * u.x + u.y * u.y + u.z * u.z)
        u = SCNVector3(u.x / uNorm, u.y / uNorm, u.z / uNorm)
        
        v = SCNVector3(
            ay * az - ax * 0,  // cross product component
            ax * 0 - az * ax,
            ax * ay - ay * ax
        )
        // Simplified: v = axis × u
        v = SCNVector3(
            ay * u.z - az * u.y,
            az * u.x - ax * u.z,
            ax * u.y - ay * u.x
        )
        
        // Project each vertex
        for vertex in vertices {
            let x = vertex.x * u.x + vertex.y * u.y + vertex.z * u.z
            let y = vertex.x * v.x + vertex.y * v.y + vertex.z * v.z
            projectedPoints.append((x: x, y: y))
        }
        
        // Fit circle to projected points
        guard let circle = fitCircle2D(points: projectedPoints) else { return nil }
        
        return circle.r
    }

    /// Classify profile using NORMAL VECTOR HISTOGRAM (KB Section 1 - Geometric Primitive Recovery)
    /// Round tubes: normals form continuous gradient around axis (high entropy)
    /// Rectangular tubes: normals cluster in 4 orthogonal directions (low entropy, discrete bins)
    private static func classifyProfileUsingNormals(vertices: [SCNVector3], faces: [[Int]], normals: [SCNVector3], axis: SCNVector3, size: SCNVector3) -> (profile: StockInfo.ProfileType, od: CGFloat?, odX: CGFloat?, odY: CGFloat?, wallThickness: CGFloat?) {
        guard normals.count > 0 else {
            // Fallback to bounding box if no normals
            return classifyProfileFromBoundingBox(size: size)
        }

        print("  Normal vector analysis: \(normals.count) normals")

        // Compute angle of each normal relative to tube axis
        // For round tubes: angles form continuous distribution [0, 360)
        // For rectangular tubes: angles cluster at 4 discrete values
        var angles: [CGFloat] = []

        for (i, normal) in normals.enumerated() {
            // Skip normals that are nearly parallel to axis (end caps)
            let dotWithAxis = abs(normal.x * axis.x + normal.y * axis.y + normal.z * axis.z)
            if dotWithAxis > 0.9 {
                continue  // End cap, skip
            }

            // Project normal onto plane perpendicular to axis
            let perpX = normal.x - dotWithAxis * axis.x
            let perpY = normal.y - dotWithAxis * axis.y
            let perpZ = normal.z - dotWithAxis * axis.z

            // Compute angle in cross-section plane
            let angle: CGFloat
            if abs(axis.x) > 0.9 {
                angle = atan2(perpZ, perpY)  // YZ plane
            } else if abs(axis.y) > 0.9 {
                angle = atan2(perpZ, perpX)  // XZ plane
            } else {
                angle = atan2(perpY, perpX)  // XY plane
            }

            // Normalize to [0, 360)
            let angleDeg = angle * 180 / .pi
            angles.append(angleDeg < 0 ? angleDeg + 360 : angleDeg)
        }

        print("    Surface normals (excluding end caps): \(angles.count)")

        if angles.count < 10 {
            print("    Too few surface normals, using bounding box fallback")
            return classifyProfileFromBoundingBox(size: size)
        }

        // Create histogram with 36 bins (10° each)
        let binCount = 36
        var histogram: [Int] = Array(repeating: 0, count: binCount)
        for angle in angles {
            let binIndex = min(Int(angle / 10), binCount - 1)
            histogram[binIndex] += 1
        }

        // Count occupied bins and find peaks
        let occupiedBins = histogram.filter { $0 > 0 }.count
        let totalNormals = angles.count
        let threshold = totalNormals / 20  // 5% of total

        var peaks: [(bin: Int, count: Int)] = []
        for i in 1..<(binCount - 1) {
            if histogram[i] > histogram[i - 1] && histogram[i] > histogram[i + 1] && histogram[i] > threshold {
                peaks.append((i, histogram[i]))
            }
        }

        print("    Occupied bins: \(occupiedBins)/\(binCount)")
        print("    Peaks found: \(peaks.count)")

        // KB Section 1: If >90% of normals occupy <10 discrete bins → RECTANGULAR
        // Otherwise → ROUND (continuous gradient)
        let topPeaks = peaks.sorted { $0.count > $1.count }.prefix(4)
        let topPeakCount = topPeaks.reduce(0) { $0 + $1.count }
        let concentrationRatio = CGFloat(topPeakCount) / CGFloat(totalNormals)

        // Also check bounding box aspect ratio for rectangular/square detection
        // Use ONLY the cross-section dimensions (perpendicular to tube axis)
        let crossSectionWidth: CGFloat
        let crossSectionHeight: CGFloat
        if abs(axis.x) > 0.9 {
            // Tube along X-axis: cross-section is YZ plane
            crossSectionWidth = size.y
            crossSectionHeight = size.z
        } else if abs(axis.y) > 0.9 {
            // Tube along Y-axis: cross-section is XZ plane
            crossSectionWidth = size.x
            crossSectionHeight = size.z
        } else {
            // Tube along Z-axis: cross-section is XY plane
            crossSectionWidth = size.x
            crossSectionHeight = size.y
        }
        let aspectRatio = max(crossSectionWidth, crossSectionHeight) / min(crossSectionWidth, crossSectionHeight)
        let isSquareAspect = aspectRatio < 1.1  // Within 10% of square

        print("    Cross-section: \(String(format: "%.1f", crossSectionWidth)) x \(String(format: "%.1f", crossSectionHeight))mm (aspect=\(String(format: "%.2f", aspectRatio)))")

        // Rectangular/Square detection:
        // Primary indicator: bounding box aspect ratio
        // Secondary indicator: normal concentration (when available)
        
        // Very square aspect ratio (<1.05) is strong evidence of square tube
        let isVerySquareAspect = aspectRatio < 1.05
        
        // Moderate square/rectangular aspect (<1.3) with some normal concentration
        let hasModerateAspect = aspectRatio < 1.3
        let hasSomeConcentration = concentrationRatio > 0.2 || peaks.count > 0
        
        if isVerySquareAspect {
            // Very square bounding box → SQUARE (trust geometry over normals for coarse meshes)
            print("    → SQUARE (aspect=\(String(format: "%.2f", aspectRatio)), very square bounding box)")
            return (.square, nil, crossSectionWidth, crossSectionHeight, nil)
        } else if hasModerateAspect && hasSomeConcentration {
            // Rectangular aspect with some normal concentration → RECTANGULAR
            print("    → RECTANGULAR (concentration=\(String(format: "%.1f", concentrationRatio * 100))%, peaks=\(peaks.count), aspect=\(String(format: "%.2f", aspectRatio)))")
            return (.rectangular, nil, crossSectionWidth, crossSectionHeight, nil)
        } else {
            // Round: continuous normal distribution OR aspect ratio not rectangular
            print("    → ROUND (concentration=\(String(format: "%.1f", concentrationRatio * 100))%, occupied=\(occupiedBins), aspect=\(String(format: "%.2f", aspectRatio)))")

            // Use Least-Squares Cylinder Fit for accurate OD (KB Section 3 - Precision Recovery)
            // This is more accurate than bounding box methods which underestimate radius
            let fittedRadius = fitCylinder(vertices: vertices, axis: axis)
            
            if let radius = fittedRadius {
                // Apply chord correction factor for tessellated geometry
                // R_true = R_fitted / cos(π/n) where n is facets around circumference
                // For typical meshes, n ≈ 20-50, so correction is small (1-2%)
                let estimatedFacets = totalNormals / 4  // Rough estimate
                let chordCorrection = 1.0 / cos(.pi / max(CGFloat(estimatedFacets), 10))
                let correctedRadius = radius * min(chordCorrection, 1.05)  // Cap at 5% correction
                
                print("    Least-squares fit radius: \(String(format: "%.2f", radius))mm, corrected: \(String(format: "%.2f", correctedRadius))mm")
                return (.round, correctedRadius * 2, nil, nil, nil)
            } else {
                // Fallback to bounding box method if fit fails
                print("    ⚠️ Cylinder fit failed, using bounding box fallback")
                var maxRadius: CGFloat = 0
                let centroid = computeCentroid(vertices: vertices)
                for v in vertices {
                    let dx = v.x - centroid.x
                    let dy = v.y - centroid.y
                    let dz = v.z - centroid.z
                    let r: CGFloat
                    if abs(axis.x) > 0.9 {
                        r = sqrt(dy * dy + dz * dz)
                    } else if abs(axis.y) > 0.9 {
                        r = sqrt(dx * dx + dz * dz)
                    } else {
                        r = sqrt(dx * dx + dy * dy)
                    }
                    maxRadius = max(maxRadius, r)
                }
                return (.round, maxRadius * 2, nil, nil, nil)
            }
        }
    }

    private static func computeCentroid(vertices: [SCNVector3]) -> SCNVector3 {
        guard !vertices.isEmpty else { return SCNVector3(0, 0, 0) }
        return SCNVector3(
            vertices.reduce(0) { $0 + $1.x } / CGFloat(vertices.count),
            vertices.reduce(0) { $0 + $1.y } / CGFloat(vertices.count),
            vertices.reduce(0) { $0 + $1.z } / CGFloat(vertices.count)
        )
    }

    private static func classifyProfileFromBoundingBox(size: SCNVector3) -> (profile: StockInfo.ProfileType, od: CGFloat?, odX: CGFloat?, odY: CGFloat?, wallThickness: CGFloat?) {
        // Fallback when normal analysis fails
        let crossSectionSizes = [size.y, size.z, size.x].sorted(by: >)
        let width = crossSectionSizes[0]
        let height = crossSectionSizes[1]

        if abs(width - height) / max(width, height) < 0.05 {
            return (.square, nil, width, height, nil)
        } else {
            return (.rectangular, nil, width, height, nil)
        }
    }

    // MARK: - Inner/Outer Surface Detection

    /// Detect inner and outer surface boundaries for hollow tubes
    /// Returns (outerRadius, innerRadius) or nil for innerRadius if solid
    /// Uses histogram analysis to find distinct radius peaks
    private static func detectSurfaceBoundaries(vertices: [SCNVector3], axis: SCNVector3, centroid: SCNVector3, profile: StockInfo.ProfileType) -> (outer: (CGFloat, CGFloat?), inner: (CGFloat, CGFloat?)?) {

        // Compute radial distances from centroid in cross-section plane
        var radialDistances: [CGFloat] = []

        for v in vertices {
            let dx = v.x - centroid.x
            let dy = v.y - centroid.y
            let dz = v.z - centroid.z

            // Project onto plane perpendicular to axis
            let axialComponent = dx * axis.x + dy * axis.y + dz * axis.z
            let perpX = dx - axialComponent * axis.x
            let perpY = dy - axialComponent * axis.y
            let perpZ = dz - axialComponent * axis.z
            let radialDist = sqrt(perpX * perpX + perpY * perpY + perpZ * perpZ)

            radialDistances.append(radialDist)
        }

        // Sort and analyze distribution
        let sorted = radialDistances.sorted()
        guard !sorted.isEmpty else {
            print("    ⚠️ WARNING: No vertices for radius detection - defaulting to hollow tube assumption")
            return ((20, nil), (15, nil))  // Fallback assumption for plasma cutting
        }

        let minDist = sorted.first!
        let maxDist = sorted.last!
        let range = maxDist - minDist

        // IMPORTANT: CNC plasma cutting ONLY works on hollow tubes
        // Solid stock is too thick to cut through with plasma
        // If we don't detect clear inner/outer surfaces, something is wrong with the model

        // Create histogram with 20 bins
        let binCount = 20
        let binSize = range / max(CGFloat(binCount), 0.001)
        var histogram: [Int] = Array(repeating: 0, count: binCount)

        for dist in radialDistances {
            let binIndex = min(Int((dist - minDist) / binSize), binCount - 1)
            histogram[binIndex] += 1
        }

        // Find peaks in histogram (local maxima)
        var peaks: [(binIndex: Int, count: Int)] = []
        for i in 1..<(binCount - 1) {
            if histogram[i] > histogram[i - 1] && histogram[i] > histogram[i + 1] {
                peaks.append((i, histogram[i]))
            }
        }

        // Sort peaks by count (most vertices)
        peaks.sort { $0.count > $1.count }

        if peaks.count >= 2 {
            // Check if two peaks are significantly separated
            let peak1BinCenter = minDist + (CGFloat(peaks[0].binIndex) + 0.5) * binSize
            let peak2BinCenter = minDist + (CGFloat(peaks[1].binIndex) + 0.5) * binSize

            let separation = abs(peak2BinCenter - peak1BinCenter)

            // Require at least 2mm separation between peaks
            let totalVertices = radialDistances.count
            let peak1Count = peaks[0].count
            let peak2Count = peaks[1].count
            let bothPeaksSignificant = peak1Count > totalVertices / 10 && peak2Count > totalVertices / 10

            if separation > 2.0 && bothPeaksSignificant {
                let innerRadius = min(peak1BinCenter, peak2BinCenter)
                let outerRadius = max(peak1BinCenter, peak2BinCenter)

                print("    ✓ Detected HOLLOW tube: inner radius ≈ \(String(format: "%.1f", innerRadius))mm, outer radius ≈ \(String(format: "%.1f", outerRadius))mm")
                print("    Wall thickness: \(String(format: "%.1f", outerRadius - innerRadius))mm")

                return ((outerRadius, nil), (innerRadius, nil))
            }
        }

        // Fallback: use min/max of distribution
        let innerRadius = sorted[sorted.count / 4]
        let outerRadius = sorted[(sorted.count * 3) / 4]

        print("    → Estimated hollow tube: inner ≈ \(String(format: "%.1f", innerRadius))mm, outer ≈ \(String(format: "%.1f", outerRadius))mm")

        return ((outerRadius, nil), (innerRadius, nil))
    }

    /// Extract cross-section vertices near a position along the axis
    /// CRITICAL: For coarse meshes, use face-based extraction as primary method
    private static func extractCrossSection(vertices: [SCNVector3], faces: [[Int]], axis: SCNVector3, position: CGFloat, tolerance: CGFloat) -> [SCNVector3] {
        var result: [SCNVector3] = []

        // First, try vertex-based extraction
        var minProj = CGFloat.greatestFiniteMagnitude
        var maxProj = -CGFloat.greatestFiniteMagnitude
        var projections: [CGFloat] = []

        for v in vertices {
            let proj = v.x * axis.x + v.y * axis.y + v.z * axis.z
            projections.append(proj)
            minProj = min(minProj, proj)
            maxProj = max(maxProj, proj)
        }

        // If position is outside the actual range, adjust it to midpoint
        let actualMidpoint = (minProj + maxProj) / 2
        let actualPosition = (position < minProj || position > maxProj) ? actualMidpoint : position

        // Try vertex-based first with adaptive tolerance
        for (i, v) in vertices.enumerated() {
            let proj = projections[i]
            if abs(proj - actualPosition) < tolerance {
                result.append(v)
            }
        }

        // For coarse meshes, vertex-based often fails - use face-based extraction
        // This intersects faces with the cutting plane
        if result.count < 8 {
            print("    Vertex-based extraction found only \(result.count) vertices, using face-based extraction")
            result = extractCrossSectionFromFaces(vertices: vertices, faces: faces, axis: axis, position: actualPosition, tolerance: tolerance)
            print("    Face-based extraction returned \(result.count) vertices")
        }

        // If still insufficient, try multiple slices
        if result.count < 8 {
            print("    Face-based extraction also failed, trying multi-slice approach")
            result.removeAll()
            
            // Sample at multiple positions within tolerance range
            let samplePositions = [
                actualPosition - tolerance,
                actualPosition - tolerance/2,
                actualPosition,
                actualPosition + tolerance/2,
                actualPosition + tolerance
            ]
            
            for samplePos in samplePositions {
                for (i, v) in vertices.enumerated() {
                    let proj = projections[i]
                    if abs(proj - samplePos) < tolerance/2 {
                        // Check if we already have a nearby vertex
                        let isDuplicate = result.contains { existing in
                            let dist = sqrt(pow(existing.x - v.x, 2) + pow(existing.y - v.y, 2) + pow(existing.z - v.z, 2))
                            return dist < 0.1
                        }
                        if !isDuplicate {
                            result.append(v)
                        }
                    }
                }
            }
        }

        return result
    }
    
    /// Extract cross-section by finding faces that intersect the cutting plane
    /// This works when vertices are sparse but faces cross the plane
    /// CRITICAL: Properly intersect face EDGES with the plane, not just face centers
    private static func extractCrossSectionFromFaces(vertices: [SCNVector3], faces: [[Int]], axis: SCNVector3, position: CGFloat, tolerance: CGFloat) -> [SCNVector3] {
        var result: [SCNVector3] = []
        var edgePoints: [SCNVector3] = []

        // For each face, check if it intersects the plane at position
        for face in faces {
            guard face.count == 3 else { continue }

            let v0 = vertices[face[0]]
            let v1 = vertices[face[1]]
            let v2 = vertices[face[2]]

            // Project vertices onto axis
            let p0 = v0.x * axis.x + v0.y * axis.y + v0.z * axis.z
            let p1 = v1.x * axis.x + v1.y * axis.y + v1.z * axis.z
            let p2 = v2.x * axis.x + v2.y * axis.y + v2.z * axis.z

            // Find edge-plane intersections
            // Edge 0-1
            if (p0 <= position && p1 >= position) || (p0 >= position && p1 <= position) {
                let t = abs(p1 - p0) < 0.0001 ? 0.5 : (position - p0) / (p1 - p0)
                if t >= 0 && t <= 1 {
                    let point = SCNVector3(
                        v0.x + t * (v1.x - v0.x),
                        v0.y + t * (v1.y - v0.y),
                        v0.z + t * (v1.z - v0.z)
                    )
                    edgePoints.append(point)
                }
            }
            
            // Edge 1-2
            if (p1 <= position && p2 >= position) || (p1 >= position && p2 <= position) {
                let t = abs(p2 - p1) < 0.0001 ? 0.5 : (position - p1) / (p2 - p1)
                if t >= 0 && t <= 1 {
                    let point = SCNVector3(
                        v1.x + t * (v2.x - v1.x),
                        v1.y + t * (v2.y - v1.y),
                        v1.z + t * (v2.z - v1.z)
                    )
                    edgePoints.append(point)
                }
            }
            
            // Edge 2-0
            if (p2 <= position && p0 >= position) || (p2 >= position && p0 <= position) {
                let t = abs(p0 - p2) < 0.0001 ? 0.5 : (position - p2) / (p0 - p2)
                if t >= 0 && t <= 1 {
                    let point = SCNVector3(
                        v2.x + t * (v0.x - v2.x),
                        v2.y + t * (v0.y - v2.y),
                        v2.z + t * (v0.z - v2.z)
                    )
                    edgePoints.append(point)
                }
            }
        }

        // Remove duplicate points (within 0.1mm)
        for point in edgePoints {
            let isDuplicate = result.contains { existing in
                let dist = sqrt(pow(existing.x - point.x, 2) + pow(existing.y - point.y, 2) + pow(existing.z - point.z, 2))
                return dist < 0.1
            }
            if !isDuplicate {
                result.append(point)
            }
        }

        print("    Face-based edge intersection found \(result.count) points")
        return result
    }
    
    /// Classify cross-section profile as round, rectangular, or square
    private static func classifyProfile(vertices: [SCNVector3], centroid: SCNVector3, axis: SCNVector3) -> (profile: StockInfo.ProfileType, od: CGFloat?, odX: CGFloat?, odY: CGFloat?, wallThickness: CGFloat?) {
        guard !vertices.isEmpty else {
            print("    classifyProfile: NO VERTICES - returning unknown")
            return (.unknown, nil, nil, nil, nil)
        }

        print("    classifyProfile: analyzing \(vertices.count) vertices")
        print("    Centroid: (\(centroid.x), \(centroid.y), \(centroid.z))")
        print("    Axis: (\(axis.x), \(axis.y), \(axis.z))")

        // Compute radii from centroid IN THE CROSS-SECTION PLANE (perpendicular to axis)
        // For a tube aligned with Z-axis, we only measure distance in XY plane
        var radii: [CGFloat] = []
        for v in vertices {
            let dx = v.x - centroid.x
            let dy = v.y - centroid.y
            let dz = v.z - centroid.z

            // Project distance onto plane perpendicular to tube axis
            // If axis is (0,0,1), we want sqrt(dx² + dy²)
            // If axis is (1,0,0), we want sqrt(dy² + dz²)
            // If axis is (0,1,0), we want sqrt(dx² + dz²)
            let r: CGFloat
            if abs(axis.z) > 0.9 {
                // Z-axis tube: measure in XY plane
                r = sqrt(dx * dx + dy * dy)
            } else if abs(axis.x) > 0.9 {
                // X-axis tube: measure in YZ plane
                r = sqrt(dy * dy + dz * dz)
            } else if abs(axis.y) > 0.9 {
                // Y-axis tube: measure in XZ plane
                r = sqrt(dx * dx + dz * dz)
            } else {
                // General case: project onto perpendicular plane
                // Distance = |v - centroid - ((v - centroid) · axis) * axis|
                let vRel = SCNVector3(dx, dy, dz)
                let proj = dx * axis.x + dy * axis.y + dz * axis.z
                let perpX = dx - proj * axis.x
                let perpY = dy - proj * axis.y
                let perpZ = dz - proj * axis.z
                r = sqrt(perpX * perpX + perpY * perpY + perpZ * perpZ)
            }

            radii.append(r)
        }

        let meanR = radii.reduce(0, +) / CGFloat(radii.count)
        let variance = radii.reduce(0) { $0 + pow($1 - meanR, 2) }
        let stddevR = sqrt(variance / CGFloat(radii.count))
        let cv = meanR > 0 ? stddevR / meanR : 999

        print("    Radii: mean=\(String(format: "%.2f", meanR)), stddev=\(String(format: "%.4f", stddevR)), CV=\(String(format: "%.4f", cv))")
        print("    Min radius=\(String(format: "%.2f", radii.min() ?? 0)), Max radius=\(String(format: "%.2f", radii.max() ?? 0))")

        // Round tube detection: stddev/mean < 0.02 (KB Section 2 Step 3)
        if meanR > 0 && cv < 0.02 {
            let od = 2 * meanR  // STL already in mm (Fusion 360 default)
            print("    → ROUND tube detected, OD=\(String(format: "%.2f", od))mm")
            return (.round, od, nil, nil, nil)  // Wall thickness requires inner surface detection
        }

        // Rectangular tube detection: check convex hull edge angles
        // Simplified: use bounding box in cross-section plane
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude

        for v in vertices {
            minX = min(minX, v.x); maxX = max(maxX, v.x)
            minY = min(minY, v.y); maxY = max(maxY, v.y)
        }

        let width = maxX - minX
        let height = maxY - minY
        let odX = width  // STL already in mm (Fusion 360 default)
        let odY = height  // STL already in mm (Fusion 360 default)

        print("    Bounding box: \(String(format: "%.2f", width)) x \(String(format: "%.2f", height))mm")

        // Square if width ≈ height (within 1%)
        if abs(width - height) / max(width, height) < 0.01 {
            print("    → SQUARE tube detected")
            return (.square, nil, odX, odY, nil)
        }

        print("    → RECTANGULAR tube detected")
        return (.rectangular, nil, odX, odY, nil)
    }
    
    // MARK: - Inner/Outer Surface Detection
    
    /// Detect inner and outer surface boundaries for hollow tubes
    /// Returns (outerRadius, innerRadius) or nil for innerRadius if solid
    /// Uses histogram analysis to find distinct radius peaks
    /// NOTE: CNC plasma cutting only works on HOLLOW tubes (solid stock is too thick to cut)
    private static func detectSurfaceBoundaries(vertices: [SCNVector3], axis: SCNVector3, centroid: SCNVector3, profile: StockInfo.ProfileType) -> (outer: (CGFloat, CGFloat?), inner: (CGFloat, CGFloat?)?) {
        
        // Compute radial distances from centroid in cross-section plane
        var radialDistances: [CGFloat] = []
        
        for v in vertices {
            let dx = v.x - centroid.x
            let dy = v.y - centroid.y
            let dz = v.z - centroid.z
            
            // Project onto plane perpendicular to axis
            let axialComponent = dx * axis.x + dy * axis.y + dz * axis.z
            let perpX = dx - axialComponent * axis.x
            let perpY = dy - axialComponent * axis.y
            let perpZ = dz - axialComponent * axis.z
            let radialDist = sqrt(perpX * perpX + perpY * perpY + perpZ * perpZ)
            
            radialDistances.append(radialDist)
        }
        
        // Sort and analyze distribution
        let sorted = radialDistances.sorted()
        guard !sorted.isEmpty else {
            print("    ⚠️ WARNING: No vertices for radius detection - defaulting to hollow tube assumption")
            return ((20, nil), (15, nil))  // Fallback assumption for plasma cutting
        }
        
        let minDist = sorted.first!
        let maxDist = sorted.last!
        let range = maxDist - minDist
        
        // IMPORTANT: CNC plasma cutting ONLY works on hollow tubes
        // Solid stock is too thick to cut through with plasma
        // If we don't detect clear inner/outer surfaces, something is wrong with the model
        
        // Create histogram with 20 bins
        let binCount = 20
        let binSize = range / max(CGFloat(binCount), 0.001)
        var histogram: [Int] = Array(repeating: 0, count: binCount)
        
        for dist in radialDistances {
            let binIndex = min(Int((dist - minDist) / binSize), binCount - 1)
            histogram[binIndex] += 1
        }
        
        // Debug: print histogram
        print("    Radial distance histogram:")
        for (i, count) in histogram.enumerated() {
            let binCenter = minDist + (CGFloat(i) + 0.5) * binSize
            let bar = String(repeating: "█", count: min(count / 10, 50))
            print(String(format: "      %.1fmm: %@  (%d)", binCenter, bar, count))
        }
        
        // Find peaks in histogram (local maxima)
        var peaks: [(binIndex: Int, count: Int)] = []
        for i in 1..<(binCount - 1) {
            if histogram[i] > histogram[i - 1] && histogram[i] > histogram[i + 1] {
                peaks.append((i, histogram[i]))
            }
        }
        
        // Also check bin 0 and last bin (edge cases)
        if binCount > 1 && histogram[0] > histogram[1] {
            peaks.append((0, histogram[0]))
        }
        if binCount > 1 && histogram[binCount - 1] > histogram[binCount - 2] {
            peaks.append((binCount - 1, histogram[binCount - 1]))
        }
        
        // Sort peaks by count (most vertices)
        peaks.sort { $0.count > $1.count }
        
        print("    Found \(peaks.count) peaks in histogram")
        for (i, peak) in peaks.prefix(3).enumerated() {
            let binCenter = minDist + (CGFloat(peak.binIndex) + 0.5) * binSize
            print("      Peak \(i + 1): radius ≈ \(String(format: "%.1f", binCenter))mm (\(peak.count) vertices)")
        }
        
        if peaks.count >= 2 {
            // Check if two peaks are significantly separated
            let peak1BinCenter = minDist + (CGFloat(peaks[0].binIndex) + 0.5) * binSize
            let peak2BinCenter = minDist + (CGFloat(peaks[1].binIndex) + 0.5) * binSize
            
            let separation = abs(peak2BinCenter - peak1BinCenter)
            
            // Require at least 2mm separation between peaks (was 5mm - too strict for thin walls!)
            // Also require the two peaks to be significant (each has >10% of total vertices)
            let totalVertices = radialDistances.count
            let peak1Count = peaks[0].count
            let peak2Count = peaks[1].count
            let bothPeaksSignificant = peak1Count > totalVertices / 10 && peak2Count > totalVertices / 10
            
            if separation > 2.0 && bothPeaksSignificant {
                let innerRadius = min(peak1BinCenter, peak2BinCenter)
                let outerRadius = max(peak1BinCenter, peak2BinCenter)
                
                print("    ✓ Detected HOLLOW tube: inner radius ≈ \(String(format: "%.1f", innerRadius))mm, outer radius ≈ \(String(format: "%.1f", outerRadius))mm")
                print("    Wall thickness: \(String(format: "%.1f", outerRadius - innerRadius))mm")
                
                return ((outerRadius, nil), (innerRadius, nil))
            } else {
                print("    ⚠️ WARNING: Peaks too close (\(String(format: "%.1f", separation))mm) or insignificant")
                print("    → CNC plasma cutting requires HOLLOW tubes - using closest peaks as approximation")
                
                // Even if peaks are close, plasma cutting requires hollow tubes
                // Use the two largest peaks as best guess
                let innerRadius = min(peak1BinCenter, peak2BinCenter)
                let outerRadius = max(peak1BinCenter, peak2BinCenter)
                
                print("    → Assuming hollow tube: inner ≈ \(String(format: "%.1f", innerRadius))mm, outer ≈ \(String(format: "%.1f", outerRadius))mm")
                
                return ((outerRadius, nil), (innerRadius, nil))
            }
        } else {
            // Only one peak detected - but plasma cutting still requires hollow tubes!
            // Use min/max of distribution as inner/outer bounds
            print("    ⚠️ WARNING: Only \(peaks.count) peak(s) detected - mesh may be low quality")
            print("    → CNC plasma cutting requires HOLLOW tubes - estimating bounds from distribution")
            
            // Use 25th and 75th percentile as inner/outer approximations
            let q1Index = sorted.count / 4
            let q3Index = (sorted.count * 3) / 4
            let innerRadius = sorted[q1Index]
            let outerRadius = sorted[q3Index]
            
            print("    → Estimated hollow tube: inner ≈ \(String(format: "%.1f", innerRadius))mm, outer ≈ \(String(format: "%.1f", outerRadius))mm")
            print("    → Wall thickness estimate: \(String(format: "%.1f", outerRadius - innerRadius))mm")
            
            return ((outerRadius, nil), (innerRadius, nil))
        }
    }
    
    /// Detect end cut type (square, miter, compound miter) per KB Section 3
    private static func detectEndCut(vertices: [SCNVector3], faces: [[Int]], normals: [SCNVector3], axis: SCNVector3, end: End, length: CGFloat) -> EndCutInfo? {
        // Find faces at the specified end
        let endPosition: CGFloat
        let axisCoord: (SCNVector3) -> CGFloat

        switch end {
        case .start:
            endPosition = 0
            axisCoord = { v in
                if axis.x == 1 || axis.x == -1 { return v.x }
                if axis.y == 1 || axis.y == -1 { return v.y }
                return v.z
            }
        case .end:
            endPosition = length
            axisCoord = { v in
                if axis.x == 1 || axis.x == -1 { return v.x }
                if axis.y == 1 || axis.y == -1 { return v.y }
                return v.z
            }
        }

        // Collect faces at the end (using face centers, not just vertices)
        let endThreshold = length * 0.15  // 15% of length from end
        var endFaceCenters: [SCNVector3] = []
        var endFaceNormals: [SCNVector3] = []

        for (i, face) in faces.enumerated() {
            guard face.count == 3, i < normals.count else { continue }

            let faceCenter = SCNVector3(
                (vertices[face[0]].x + vertices[face[1]].x + vertices[face[2]].x) / 3,
                (vertices[face[0]].y + vertices[face[1]].y + vertices[face[2]].y) / 3,
                (vertices[face[0]].z + vertices[face[1]].z + vertices[face[2]].z) / 3
            )

            let proj = axisCoord(faceCenter)
            let isInEnd = (end == .start) ? (proj < endPosition + endThreshold) : (proj > endPosition - endThreshold)

            if isInEnd {
                // Check if normal points roughly toward the end (not inward)
                let normalDotEnd = end == .start ? -normals[i].x * axis.x : normals[i].x * axis.x
                if normalDotEnd > -0.5 {  // Accept normals that aren't pointing strongly inward
                    endFaceCenters.append(faceCenter)
                    endFaceNormals.append(normals[i])
                }
            }
        }

        // If still no faces, try a wider threshold
        if endFaceCenters.isEmpty {
            let wideThreshold = length * 0.25
            for (i, face) in faces.enumerated() {
                guard face.count == 3, i < normals.count else { continue }

                let faceCenter = SCNVector3(
                    (vertices[face[0]].x + vertices[face[1]].x + vertices[face[2]].x) / 3,
                    (vertices[face[0]].y + vertices[face[1]].y + vertices[face[2]].y) / 3,
                    (vertices[face[0]].z + vertices[face[1]].z + vertices[face[2]].z) / 3
                )

                let proj = axisCoord(faceCenter)
                let isInEnd = (end == .start) ? (proj < endPosition + wideThreshold) : (proj > endPosition - wideThreshold)

                if isInEnd {
                    endFaceCenters.append(faceCenter)
                    endFaceNormals.append(normals[i])
                }
            }
        }

        guard !endFaceCenters.isEmpty else {
            print("  detectEndCut(\(end == .start ? "start" : "end")): No faces found at end")
            return nil
        }

        print("  detectEndCut(\(end == .start ? "start" : "end")): Found \(endFaceCenters.count) faces")

        // Fit plane to end face vertices
        let planeNormal = fitPlane(vertices: endFaceCenters)

        // Compute angle between plane normal and tube axis
        let dot = abs(planeNormal.x * axis.x + planeNormal.y * axis.y + planeNormal.z * axis.z)
        let theta = acos(min(dot, 1.0)) * 180 / .pi  // Angle in degrees

        print("    Plane normal vs axis angle: \(String(format: "%.1f", theta))°")

        // Classify: < 5° = square (relaxed from 2° for coarse meshes), >= 5° = miter
        let endName = (end == .start) ? "start" : "end"

        if theta < 5 {
            print("    → SQUARE end detected")
            return EndCutInfo(end: endName, type: .square, miterAngleDeg: 0, miterDirectionDeg: 0, xAtCenterline: end == .start ? 0 : length)  // STL already in mm
        } else {
            // TODO: Detect compound miter (two-plane tilt)
            // For now, assume simple miter
            let miterDirection = atan2(planeNormal.y, planeNormal.x) * 180 / .pi
            print("    → MITER end detected: \(String(format: "%.1f", theta))°")
            return EndCutInfo(end: endName, type: .miter, miterAngleDeg: theta, miterDirectionDeg: miterDirection, xAtCenterline: end == .start ? 0 : length)  // STL already in mm
        }
    }
    
    // MARK: - Feature Detection (KB Section 4)

    /// Detect surface features: holes, notches, cutouts, cope cuts
    /// Uses boundary loop extraction and classification (KB Section 4)
    private static func detectSurfaceFeatures(vertices: [SCNVector3], faces: [[Int]], normals: [SCNVector3],
                                             stockInfo: StockInfo) -> [SurfaceFeature] {
        var features: [SurfaceFeature] = []

        // Build edge map to find boundary loops
        var edgeToFaces: [Edge: [Int]] = [:]

        for (faceIdx, face) in faces.enumerated() {
            guard face.count == 3 else { continue }

            for i in 0..<3 {
                let v1 = face[i]
                let v2 = face[(i + 1) % 3]
                let edge = Edge(v1: v1, v2: v2)
                edgeToFaces[edge, default: []].append(faceIdx)
            }
        }

        // Find boundary edges (edges with only 1 face = hole boundary)
        var boundaryEdges: [Edge] = []
        for (edge, faceList) in edgeToFaces {
            if faceList.count == 1 {
                boundaryEdges.append(edge)
            }
        }

        // Check mesh watertightness
        let totalEdges = edgeToFaces.count
        let boundaryEdgeRatio = Double(boundaryEdges.count) / Double(max(totalEdges, 1))
        print("  Mesh watertightness check: \(boundaryEdges.count)/\(totalEdges) boundary edges (\(String(format: "%.1f", boundaryEdgeRatio * 100))%)")
        
        // If >50% of edges are boundary edges, mesh is severely non-watertight
        // This indicates a poor quality mesh - be very aggressive with filtering
        let isNonWatertight = boundaryEdgeRatio > 0.5
        if isNonWatertight {
            print("  ⚠️ WARNING: Mesh is severely non-watertight - using aggressive filtering")
        }

        // Extract boundary loops
        let boundaryLoops = extractBoundaryLoops(edges: boundaryEdges, vertices: vertices)
        print("  Found \(boundaryLoops.count) raw boundary loop(s)")

        // Filter out tiny loops (internal mesh artifacts) and tube end caps
        // Keep only significant loops that represent actual features
        let significantLoops = filterSignificantLoops(loops: boundaryLoops, vertices: vertices, stockInfo: stockInfo, isNonWatertight: isNonWatertight)
        print("  Filtered to \(significantLoops.count) significant feature loop(s)")
        
        // Classify each boundary loop
        var featureId = 1
        for loop in significantLoops {
            if let feature = classifyBoundaryLoop(loop: loop, vertices: vertices, stockInfo: stockInfo, id: featureId) {
                // Validate feature per KB Section 12
                let (isValid, errors) = feature.validate(stockInfo: stockInfo)
                
                if !errors.isEmpty {
                    print("  WARNING - Feature \(feature.id): \(errors.joined(separator: "; "))")
                }
                
                features.append(feature)
                featureId += 1
                print("  Detected \(feature.type.rawValue): \(feature.shape.rawValue) at X=\(String(format: "%.1f", feature.xCenter)), A=\(String(format: "%.1f", feature.aCenterDeg))° (confidence: \(String(format: "%.2f", feature.confidence)))")
            }
        }
        
        return features
    }
    
    struct Edge: Hashable {
        let v1: Int
        let v2: Int
        
        init(v1: Int, v2: Int) {
            // Normalize so v1 < v2 for consistent hashing
            if v1 < v2 {
                self.v1 = v1
                self.v2 = v2
            } else {
                self.v1 = v2
                self.v2 = v1
            }
        }
    }
    
    /// Extract connected boundary loops from boundary edges
    private static func extractBoundaryLoops(edges: [Edge], vertices: [SCNVector3]) -> [[Int]] {
        guard !edges.isEmpty else { return [] }
        
        // Build adjacency map
        var adjacency: [Int: [Int]] = [:]
        for edge in edges {
            adjacency[edge.v1, default: []].append(edge.v2)
            adjacency[edge.v2, default: []].append(edge.v1)
        }
        
        var visited = Set<Int>()
        var loops: [[Int]] = []
        
        // Traverse each connected component
        for startVertex in adjacency.keys {
            guard !visited.contains(startVertex) else { continue }
            
            var loop: [Int] = []
            var current = startVertex
            
            while true {
                visited.insert(current)
                loop.append(current)
                
                // Find next unvisited neighbor
                guard let neighbors = adjacency[current] else { break }
                
                var nextVertex: Int? = nil
                for neighbor in neighbors {
                    if !visited.contains(neighbor) {
                        nextVertex = neighbor
                        break
                    }
                }
                
                if let next = nextVertex {
                    current = next
                } else {
                    // No unvisited neighbors - loop closed or dead end
                    break
                }
                
                // Safety: prevent infinite loops
                if loop.count > 10000 {
                    break
                }
            }
            
            if loop.count >= 3 {
                loops.append(loop)
            }
        }
        
        return loops
    }
    
    /// Filter boundary loops to keep only significant features (notches, holes)
    /// Removes tube end caps, tiny mesh artifacts, and INNER WALL features
    /// CNC plasma cutting only works on the OUTER surface of hollow tubes
    private static func filterSignificantLoops(loops: [[Int]], vertices: [SCNVector3], stockInfo: StockInfo, isNonWatertight: Bool = false) -> [[Int]] {
        // Group loops by position and merge nearby ones
        // For non-watertight meshes, features often fragment into many small loops

        let tubeLength = stockInfo.length
        let tubeRadius = (stockInfo.od ?? 50) / 2
        let outerRadius = stockInfo.outerRadius ?? tubeRadius
        let innerRadius = stockInfo.innerRadius

        print("  Filtering \(loops.count) boundary loops...")
        print("    Tube length: \(String(format: "%.1f", tubeLength))mm, outer radius: \(String(format: "%.1f", outerRadius))mm")

        // First pass: collect loop metadata
        struct LoopInfo {
            let loop: [Int]
            let center: SCNVector3
            let size: SCNVector3
            let diagonal: CGFloat
            let centerProj: CGFloat
            let vertexCount: Int
            let avgRadialDist: CGFloat  // Average distance from tube centerline
            let minRadialDist: CGFloat  // Minimum radial distance (for wall detection)
            let maxRadialDist: CGFloat  // Maximum radial distance (for wall detection)
        }

        var loopInfos: [LoopInfo] = []

        for loop in loops {
            guard loop.count >= 3 else { continue }

            let loopVertices = loop.map { vertices[$0] }

            // Compute loop size and position
            var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
            var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
            var minZ = CGFloat.greatestFiniteMagnitude, maxZ = -CGFloat.greatestFiniteMagnitude

            for v in loopVertices {
                minX = min(minX, v.x); maxX = max(maxX, v.x)
                minY = min(minY, v.y); maxY = max(maxY, v.y)
                minZ = min(minZ, v.z); maxZ = max(maxZ, v.z)
            }

            let size = SCNVector3(maxX - minX, maxY - minY, maxZ - minZ)
            let center = SCNVector3((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
            let diagonal = sqrt(size.x * size.x + size.y * size.y + size.z * size.z)
            let centerProj = center.x * stockInfo.axisVector.x + center.y * stockInfo.axisVector.y + center.z * stockInfo.axisVector.z

            // Calculate radial distances from tube centerline
            var radialDistances: [CGFloat] = []
            for v in loopVertices {
                let dx = v.x - stockInfo.centroid.x
                let dy = v.y - stockInfo.centroid.y
                let dz = v.z - stockInfo.centroid.z

                // Project onto plane perpendicular to axis
                let axialComponent = dx * stockInfo.axisVector.x + dy * stockInfo.axisVector.y + dz * stockInfo.axisVector.z
                let perpX = dx - axialComponent * stockInfo.axisVector.x
                let perpY = dy - axialComponent * stockInfo.axisVector.y
                let perpZ = dz - axialComponent * stockInfo.axisVector.z
                let radialDist = sqrt(perpX * perpX + perpY * perpY + perpZ * perpZ)
                radialDistances.append(radialDist)
            }
            let avgRadialDist = radialDistances.reduce(0, +) / CGFloat(max(radialDistances.count, 1))
            let minRadialDist = radialDistances.min() ?? 0
            let maxRadialDist = radialDistances.max() ?? 0

            // Skip tiny loops immediately (mesh artifacts)
            if diagonal < 5 {
                print("    Filtering tiny loop at X=\(String(format: "%.1f", centerProj)) (size=\(String(format: "%.1f", diagonal))mm)")
                continue
            }

            // **CRITICAL: Filter out mesh artifact loops based on radial distance**
            // Real features on a tube should be on or near the outer surface
            // Loops with radial distance << outer radius are internal mesh artifacts
            let expectedOuterRadius = outerRadius
            let minFeatureRadius = expectedOuterRadius * 0.5  // Features should be at least 50% of outer radius
            
            if avgRadialDist < minFeatureRadius {
                print("    Filtering mesh artifact at X=\(String(format: "%.1f", centerProj)) (R=\(String(format: "%.1f", avgRadialDist))mm << expected \(String(format: "%.1f", expectedOuterRadius))mm)")
                continue
            }

            // **For non-watertight meshes, use even more aggressive filtering**
            if isNonWatertight {
                // Require features to be at 75% of outer radius for non-watertight meshes
                let strictMinFeatureRadius = expectedOuterRadius * 0.75
                if avgRadialDist < strictMinFeatureRadius {
                    print("    Filtering non-watertight artifact at X=\(String(format: "%.1f", centerProj)) (R=\(String(format: "%.1f", avgRadialDist))mm < \(String(format: "%.1f", strictMinFeatureRadius))mm)")
                    continue
                }
                
                // Also require larger minimum size for non-watertight meshes
                if diagonal < 10 {
                    print("    Filtering small non-watertight loop at X=\(String(format: "%.1f", centerProj)) (size=\(String(format: "%.1f", diagonal))mm < 10mm)")
                    continue
                }
            }

            // **CRITICAL FIX: Filter out inner wall features for CNC plasma cutting**
            // Plasma cutting only works on the OUTER surface of hollow tubes
            // Inner wall boundaries (holes, cutouts, end cuts) must be ignored
            if let inner = innerRadius {
                // Determine if this loop is on the inner wall
                // Compare distance to inner vs outer radius
                let distToInner = abs(avgRadialDist - inner)
                let distToOuter = abs(avgRadialDist - outerRadius)
                
                // If closer to inner radius, this is an inner wall feature - skip it
                let isOnInnerWall = distToInner < distToOuter
                
                // Use a tolerance band to handle vertices near the wall boundary
                // Vertices within the middle of the wall thickness are considered inner wall
                let definitelyInnerWall = avgRadialDist < (inner + outerRadius) / 2
                
                if isOnInnerWall || definitelyInnerWall {
                    print("    Filtering out INNER WALL feature at X=\(String(format: "%.1f", centerProj)) (radial dist=\(String(format: "%.1f", avgRadialDist))mm, inner=\(String(format: "%.1f", inner))mm, outer=\(String(format: "%.1f", outerRadius))mm)")
                    continue
                }
            }

            // Check if this is a tube end cap (circular opening at the end)
            let crossSectionSpan = max(size.y, size.z)
            let spansFullDiameter = crossSectionSpan > tubeRadius * 1.4  // ~70% of diameter
            let distToStart = abs(centerProj)
            let distToEnd = abs(centerProj - tubeLength)
            let isAtExtremeEnd = distToStart < 1.0 || distToEnd < 1.0  // Within 1mm of end

            // Calculate circularity to distinguish circular end caps from notches
            var perimeter: CGFloat = 0
            for i in 0..<loopVertices.count {
                let v1 = loopVertices[i]
                let v2 = loopVertices[(i + 1) % loopVertices.count]
                let edgeDist = sqrt(pow(v2.x - v1.x, 2) + pow(v2.y - v1.y, 2) + pow(v2.z - v1.z, 2))
                perimeter += edgeDist
            }

            let approxArea = size.x * size.y
            let circularity = (4 * .pi * approxArea) / max(perimeter * perimeter, 0.001)
            let isCircular = circularity > 0.6  // Reasonably circular

            // End caps are circular, span full diameter, and are AT the extreme ends
            if isCircular && spansFullDiameter && isAtExtremeEnd {
                print("    Filtering out tube end cap at X=\(String(format: "%.1f", centerProj)) (circular, \(String(format: "%.1f", diagonal))mm, circularity=\(String(format: "%.2f", circularity)))")
                continue
            }

            // **Filter out ALL end-related boundaries (both inner and outer walls)**
            // End cuts (miters, square cuts, cope cuts) are detected separately by detectEndCut()
            // Any boundary loop at the tube ends is part of the end cut geometry, not a separate feature
            let isNearTubeEnd = distToStart < tubeLength * 0.2 || distToEnd < tubeLength * 0.2  // Within 20% of end

            if isNearTubeEnd {
                // Check if this loop is actually an end cut by seeing if it spans a significant portion of the circumference
                // End cuts create boundary loops that wrap around the tube end
                // Real features (holes, notches) are localized and don't span the full circumference

                // Also check if this is an outer wall end cut boundary
                // End cuts typically span a large arc of the tube circumference (>90°)
                // Calculate angular span of this loop
                var minAngle = CGFloat.greatestFiniteMagnitude
                var maxAngle = -CGFloat.greatestFiniteMagnitude

                for v in loopVertices {
                    let dx = v.x - stockInfo.centroid.x
                    let dy = v.y - stockInfo.centroid.y
                    let dz = v.z - stockInfo.centroid.z

                    // Compute angle around tube axis
                    let angle: CGFloat
                    if abs(stockInfo.axisVector.z) > 0.9 {
                        angle = atan2(dy, dx)
                    } else if abs(stockInfo.axisVector.x) > 0.9 {
                        angle = atan2(dz, dy)
                    } else {
                        angle = atan2(dz, dx)
                    }

                    minAngle = min(minAngle, angle)
                    maxAngle = max(maxAngle, angle)
                }

                let angularSpan = (maxAngle - minAngle) * 180 / .pi

                // If this loop spans >90° of the circumference, it's likely the end cut boundary
                // Lowered from 120° to 90° to catch more cope cut boundaries
                if angularSpan > 90 {
                    print("    Filtering out end cut boundary at X=\(String(format: "%.1f", centerProj)) (spans \(String(format: "%.1f", angularSpan))° of circumference)")
                    continue
                }
                
                // **Additional filter: Loops very close to end (<5% of length) are likely end cut artifacts**
                // This catches cope cuts and other end treatments that don't span full circumference
                let isVeryNearEnd = distToStart < tubeLength * 0.05 || distToEnd < tubeLength * 0.05
                if isVeryNearEnd {
                    print("    Filtering out very-near-end boundary at X=\(String(format: "%.1f", centerProj)) (distToStart=\(String(format: "%.1f", distToStart)), distToEnd=\(String(format: "%.1f", distToEnd)))")
                    continue
                }
            }

            // **NEW: Filter out loops that don't represent real features**
            // Real features (holes, notches) should have vertices at a consistent radial distance
            // (on the tube surface). Loops with large radial variation are likely mesh artifacts.
            let radialVariation = maxRadialDist - minRadialDist
            let expectedWallThickness: CGFloat = innerRadius != nil ? (outerRadius - innerRadius!) : tubeRadius * 0.1
            
            // If radial variation is more than half the wall thickness, this is likely not a real feature
            // (it's probably a mesh artifact or internal structure)
            if radialVariation > expectedWallThickness * 0.5 {
                print("    Filtering out loop with large radial variation at X=\(String(format: "%.1f", centerProj)) (variation=\(String(format: "%.1f", radialVariation))mm, wall=\(String(format: "%.1f", expectedWallThickness))mm)")
                continue
            }

            loopInfos.append(LoopInfo(
                loop: loop,
                center: center,
                size: size,
                diagonal: diagonal,
                centerProj: centerProj,
                vertexCount: loop.count,
                avgRadialDist: avgRadialDist,
                minRadialDist: minRadialDist,
                maxRadialDist: maxRadialDist
            ))
        }

        print("    After basic filtering: \(loopInfos.count) loops remain")

        // Second pass: group loops by spatial proximity
        // Loops within 20mm of each other likely represent the same feature
        var featureGroups: [[LoopInfo]] = []
        var assigned = Set<Int>()

        for (i, info1) in loopInfos.enumerated() {
            guard !assigned.contains(i) else { continue }

            var group: [LoopInfo] = [info1]
            assigned.insert(i)

            // Find nearby loops
            for (j, info2) in loopInfos.enumerated() {
                guard !assigned.contains(j) else { continue }

                // Check spatial distance
                let dx = info2.center.x - info1.center.x
                let dy = info2.center.y - info1.center.y
                let dz = info2.center.z - info1.center.z
                let dist = sqrt(dx * dx + dy * dy + dz * dz)

                // Also check axial distance (along tube)
                let axialDist = abs(info2.centerProj - info1.centerProj)

                if dist < 20 || axialDist < 10 {
                    group.append(info2)
                    assigned.insert(j)
                }
            }

            featureGroups.append(group)
        }

        print("    Grouped into \(featureGroups.count) feature region(s)")

        // Third pass: select the largest/most representative loop from each group
        var significantLoops: [[Int]] = []

        for group in featureGroups {
            // For each feature group, keep only the largest loop
            // This represents the main boundary of the feature
            if let largest = group.max(by: { $0.diagonal < $1.diagonal }) {
                significantLoops.append(largest.loop)
                print("    Feature at X=\(String(format: "%.1f", largest.centerProj)): selected largest of \(group.count) loops (size: \(String(format: "%.1f", largest.diagonal))mm, \(largest.vertexCount) verts)")
            }
        }

        return significantLoops
    }
    
    /// Classify a boundary loop as a specific feature type (KB Section 4)
    private static func classifyBoundaryLoop(loop: [Int], vertices: [SCNVector3], stockInfo: StockInfo, id: Int) -> SurfaceFeature? {
        guard loop.count >= 3 else { return nil }
        
        let loopVertices = loop.map { vertices[$0] }
        
        // Compute bounding box in tube coordinates
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        var minZ = CGFloat.greatestFiniteMagnitude, maxZ = -CGFloat.greatestFiniteMagnitude
        
        for v in loopVertices {
            minX = min(minX, v.x); maxX = max(maxX, v.x)
            minY = min(minY, v.y); maxY = max(maxY, v.y)
            minZ = min(minZ, v.z); maxZ = max(minZ, v.z)
        }
        
        let size = SCNVector3(maxX - minX, maxY - minY, maxZ - minZ)
        let center = SCNVector3((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
        
        // Convert to tube coordinates (X, A)
        let radius = (stockInfo.od ?? 50) / 2
        let xCenter = projectToAxis(point: center, axis: stockInfo.axisVector)
        let aCenter = computeAngle(point: center, axis: stockInfo.axisVector, centroid: stockInfo.centroid)
        
        // Compute perimeter and area for circularity
        var perimeter: CGFloat = 0
        for i in 0..<loopVertices.count {
            let v1 = loopVertices[i]
            let v2 = loopVertices[(i + 1) % loopVertices.count]
            let dist = sqrt(pow(v2.x - v1.x, 2) + pow(v2.y - v1.y, 2) + pow(v2.z - v1.z, 2))
            perimeter += dist
        }
        
        // Approximate area (simple 2D projection)
        let approxArea = size.x * size.y
        
        // Circularity: 4π * area / perimeter²  (close to 1.0 = circular)
        let circularity = (4 * .pi * approxArea) / (perimeter * perimeter)
        
        // Classify shape
        if circularity > 0.7 {
            // Round hole
            let diameter = sqrt(approxArea / .pi) * 2  // STL already in mm (Fusion 360 default)
            return SurfaceFeature(
                id: id,
                type: .hole,
                shape: .round,
                xCenter: xCenter,  // STL already in mm
                aCenterDeg: aCenter,
                dimensions: ["diameter": diameter],
                normalAngleDeg: 0,
                end: nil
            )
        } else if circularity > 0.4 && circularity <= 0.7 {
            // Rectangular hole
            let width = size.x  // STL already in mm
            let height = size.y  // STL already in mm
            return SurfaceFeature(
                id: id,
                type: .hole,
                shape: .rectangular,
                xCenter: xCenter,  // STL already in mm
                aCenterDeg: aCenter,
                dimensions: ["width": width, "height": height],
                normalAngleDeg: 0,
                end: nil
            )
        } else {
            // Custom shape or notch
            // Check if it's at tube end (notch)
            let tubeLength = stockInfo.length
            let distToStart = abs(xCenter)
            let distToEnd = abs(xCenter - tubeLength)  // tubeLength already in mm
            
            if distToStart < tubeLength / 10 || distToEnd < tubeLength / 10 {
                // Likely a notch
                let depth = size.x  // STL already in mm
                let width = size.y  // STL already in mm
                let endName = distToStart < distToEnd ? "start" : "end"
                
                return SurfaceFeature(
                    id: id,
                    type: .notch,
                    shape: .rectangular,
                    xCenter: xCenter,  // STL already in mm
                    aCenterDeg: aCenter,
                    dimensions: ["depth": depth, "width": width, "angle": 30],
                    normalAngleDeg: 0,
                    end: endName
                )
            }
            
            // Default to custom hole
            return SurfaceFeature(
                id: id,
                type: .hole,
                shape: .custom,
                xCenter: xCenter,  // STL already in mm
                aCenterDeg: aCenter,
                dimensions: ["width": size.x, "height": size.y],  // STL already in mm
                normalAngleDeg: 0,
                end: nil
            )
        }
    }
    
    /// Project a point onto the tube axis to get X coordinate
    private static func projectToAxis(point: SCNVector3, axis: SCNVector3) -> CGFloat {
        // Dot product: project point onto axis
        return point.x * axis.x + point.y * axis.y + point.z * axis.z
    }
    
    /// Compute angular position (A axis in degrees) around tube
    private static func computeAngle(point: SCNVector3, axis: SCNVector3, centroid: SCNVector3) -> CGFloat {
        // Compute radial vector (perpendicular to axis)
        let toPoint = SCNVector3(point.x - centroid.x, point.y - centroid.y, point.z - centroid.z)
        
        // Project onto cross-section plane (perpendicular to axis)
        let axialComponent = toPoint.x * axis.x + toPoint.y * axis.y + toPoint.z * axis.z
        let radial = SCNVector3(
            toPoint.x - axialComponent * axis.x,
            toPoint.y - axialComponent * axis.y,
            toPoint.z - axialComponent * axis.z
        )
        
        // Compute angle in cross-section plane
        // Use Y-Z plane if axis is X, X-Z if axis is Y, X-Y if axis is Z
        let angle: CGFloat
        if abs(axis.x) > 0.9 {
            // Axis is X → use Y-Z plane
            angle = atan2(radial.z, radial.y) * 180 / .pi
        } else if abs(axis.y) > 0.9 {
            // Axis is Y → use X-Z plane
            angle = atan2(radial.z, radial.x) * 180 / .pi
        } else {
            // Axis is Z → use X-Y plane
            angle = atan2(radial.y, radial.x) * 180 / .pi
        }
        
        // Normalize to 0-360
        return angle < 0 ? angle + 360 : angle
    }
    
    enum End {
        case start, end
    }
    
    /// Fit a plane to vertices using least squares
    private static func fitPlane(vertices: [SCNVector3]) -> SCNVector3 {
        guard vertices.count >= 3 else { return SCNVector3(0, 0, 1) }
        
        // Compute centroid
        let centroid = SCNVector3(
            vertices.reduce(0) { $0 + $1.x } / CGFloat(vertices.count),
            vertices.reduce(0) { $0 + $1.y } / CGFloat(vertices.count),
            vertices.reduce(0) { $0 + $1.z } / CGFloat(vertices.count)
        )
        
        // Compute covariance matrix for PCA
        var covXX: CGFloat = 0, covYY: CGFloat = 0, covZZ: CGFloat = 0
        var covXY: CGFloat = 0, covXZ: CGFloat = 0, covYZ: CGFloat = 0
        
        for v in vertices {
            let dx = v.x - centroid.x
            let dy = v.y - centroid.y
            let dz = v.z - centroid.z
            
            covXX += dx * dx
            covYY += dy * dy
            covZZ += dz * dz
            covXY += dx * dy
            covXZ += dx * dz
            covYZ += dy * dz
        }
        
        // Find smallest eigenvector (plane normal)
        // Simplified: use cross product of two edge vectors
        if vertices.count >= 3 {
            let v0 = vertices[0]
            let v1 = vertices[1]
            let v2 = vertices[2]
            
            let e1 = SCNVector3(v1.x - v0.x, v1.y - v0.y, v1.z - v0.z)
            let e2 = SCNVector3(v2.x - v0.x, v2.y - v0.y, v2.z - v0.z)
            
            let normal = SCNVector3(
                e1.y * e2.z - e1.z * e2.y,
                e1.z * e2.x - e1.x * e2.z,
                e1.x * e2.y - e1.y * e2.x
            )
            
            let len = sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
            if len > 0.0001 {
                return SCNVector3(normal.x / len, normal.y / len, normal.z / len)
            }
        }
        
        return SCNVector3(0, 0, 1)
    }

    /// Analyze the mesh to detect shape type (cylinder, box, etc.)
    private static func analyzeShape(vertices: [SCNVector3], faces: [[Int]]) -> ShapeData? {
        guard vertices.count >= 4 else { return nil }

        // Calculate bounding box
        var minX: CGFloat = .greatestFiniteMagnitude
        var maxX: CGFloat = -.greatestFiniteMagnitude
        var minY: CGFloat = .greatestFiniteMagnitude
        var maxY: CGFloat = -.greatestFiniteMagnitude
        var minZ: CGFloat = .greatestFiniteMagnitude
        var maxZ: CGFloat = -.greatestFiniteMagnitude

        for v in vertices {
            if v.x < minX { minX = v.x }
            if v.x > maxX { maxX = v.x }
            if v.y < minY { minY = v.y }
            if v.y > maxY { maxY = v.y }
            if v.z < minZ { minZ = v.z }
            if v.z > maxZ { maxZ = v.z }
        }

        let size = SCNVector3(maxX - minX, maxY - minY, maxZ - minZ)
        let center = SCNVector3((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)

        // Check for box FIRST - rectangular tubes should be detected as boxes
        if let boxData = detectBox(vertices: vertices, size: size) {
            return ShapeData(
                type: .box,
                dimensions: boxData,
                isCuttable: true
            )
        }

        // Check for cylinder (round tubes only)
        if let cylinderData = detectCylinder(vertices: vertices, size: size, center: center) {
            return ShapeData(
                type: .cylinder,
                dimensions: cylinderData,
                isCuttable: true
            )
        }

        return ShapeData(type: .unknown, dimensions: nil, isCuttable: false)
    }

    private static func detectCylinder(vertices: [SCNVector3], size: SCNVector3, center: SCNVector3) -> CylinderDimensions? {
        // A cylinder has circular cross-section in one axis
        // Check if two dimensions are similar (diameter) and one is different (height)
        // ALSO verify the cross-section is actually circular by checking vertex distribution

        let dims = [size.x, size.y, size.z].sorted()

        // Check if two dimensions are similar (within 10%)
        guard Swift.abs(dims[1] - dims[0]) / Swift.max(dims[1], 0.001) < 0.15 else {
            return nil
        }

        // Determine primary axis (the long dimension)
        var axis = SCNVector3(0, 0, 1)
        var crossSectionSize: (CGFloat, CGFloat) = (0, 0)
        
        if size.x == dims[2] {
            axis = SCNVector3(1, 0, 0)
            crossSectionSize = (size.y, size.z)
        } else if size.y == dims[2] {
            axis = SCNVector3(0, 1, 0)
            crossSectionSize = (size.x, size.z)
        } else {
            crossSectionSize = (size.x, size.y)
        }

        // Verify circular cross-section by checking if vertices form a circle
        // Sample vertices and check distance from center
        let diameter = (dims[0] + dims[1]) / 2
        let radius = diameter / 2
        let tolerance = diameter * 0.15 // 15% tolerance

        var distancesFromCenter: [CGFloat] = []
        
        for v in vertices {
            // Project vertex onto cross-section plane
            let distFromAxis: CGFloat
            if axis.x == 1 {
                // Axis is X, check YZ plane
                let dy = v.y - center.y
                let dz = v.z - center.z
                distFromAxis = sqrt(dy * dy + dz * dz)
            } else if axis.y == 1 {
                // Axis is Y, check XZ plane
                let dx = v.x - center.x
                let dz = v.z - center.z
                distFromAxis = sqrt(dx * dx + dz * dz)
            } else {
                // Axis is Z, check XY plane
                let dx = v.x - center.x
                let dy = v.y - center.y
                distFromAxis = sqrt(dx * dx + dy * dy)
            }
            distancesFromCenter.append(distFromAxis)
        }

        // For a true cylinder, most vertices should be at ~radius distance from axis
        let avgDistance = distancesFromCenter.reduce(0, +) / CGFloat(distancesFromCenter.count)
        let distanceVariation = distancesFromCenter.map { abs($0 - avgDistance) }.max() ?? 0

        // If distance variation is small (< 20% of radius), it's a cylinder
        guard distanceVariation < radius * 0.2 else {
            return nil
        }

        let height = dims[2]

        return CylinderDimensions(
            diameter: diameter,  // STL already in mm (Fusion 360 default)
            height: height,  // STL already in mm (Fusion 360 default)
            axis: axis
        )
    }
    
    private static func detectBox(vertices: [SCNVector3], size: SCNVector3) -> BoxDimensions? {
        // Check if all dimensions are significantly different (rectangular box)
        let dims = [size.x, size.y, size.z].sorted()

        // If dimensions are all different (not cylinder-like)
        if Swift.abs(dims[1] - dims[0]) / Swift.max(dims[1], 0.001) > 0.15 {
            return BoxDimensions(
                width: size.x,  // STL already in mm (Fusion 360 default)
                height: size.y,  // STL already in mm (Fusion 360 default)
                depth: size.z  // STL already in mm (Fusion 360 default)
            )
        }

        return nil
    }
}
