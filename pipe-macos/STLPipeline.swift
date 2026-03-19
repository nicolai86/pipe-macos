import Foundation
import SceneKit
import Accelerate

// MARK: - Half-Edge Data Structure for Topological Analysis

/// Represents a unique edge in the mesh (sorted vertex indices)
struct MeshEdge: Hashable {
    let v1: Int  // Always v1 < v2
    let v2: Int
    
    init(_ a: Int, _ b: Int) {
        if a < b {
            self.v1 = a
            self.v2 = b
        } else {
            self.v1 = b
            self.v2 = a
        }
    }
}

/// Half-edge data structure for topological mesh analysis
class HalfEdgeMesh {
    struct Face {
        let vertices: [Int]
        let normal: SCNVector3
        var neighbors: [Int?] = []  // Neighbor face indices for each edge
    }
    
    var faces: [Face] = []
    var edgeToFaces: [MeshEdge: [Int]] = [:]  // Edge -> face indices
    
    /// Build half-edge structure from vertex/face data
    init(vertices: [SCNVector3], faces: [[Int]], normals: [SCNVector3]) {
        // Create faces
        for (i, faceVerts) in faces.enumerated() {
            let normal = i < normals.count ? normals[i] : SCNVector3(0, 0, 1)
            self.faces.append(Face(vertices: faceVerts, normal: normal))
        }
        
        // Build edge-to-face map
        for (faceIdx, face) in self.faces.enumerated() {
            for i in 0..<face.vertices.count {
                let v1 = face.vertices[i]
                let v2 = face.vertices[(i + 1) % face.vertices.count]
                let edge = MeshEdge(v1, v2)
                edgeToFaces[edge, default: []].append(faceIdx)
            }
        }
        
        // Build neighbor map for each face
        for (faceIdx, face) in self.faces.enumerated() {
            self.faces[faceIdx].neighbors = Array(repeating: nil, count: face.vertices.count)
            
            for i in 0..<face.vertices.count {
                let v1 = face.vertices[i]
                let v2 = face.vertices[(i + 1) % face.vertices.count]
                let edge = MeshEdge(v1, v2)
                
                // Find the reverse edge (v2, v1) which indicates a shared edge
                let reverseEdge = MeshEdge(v2, v1)
                if let neighborFaces = edgeToFaces[reverseEdge],
                   let neighborIdx = neighborFaces.first(where: { $0 != faceIdx }) {
                    self.faces[faceIdx].neighbors[i] = neighborIdx
                }
            }
        }
    }
    
    /// Segment mesh into connected bodies using topological face-walking (BFS)
    func segmentIntoBodies() -> [[Int]] {
        var visited = Set<Int>()
        var bodies: [[Int]] = []
        
        for startFace in 0..<faces.count {
            guard !visited.contains(startFace) else { continue }
            
            // BFS to find all connected faces
            var body: [Int] = []
            var queue: [Int] = [startFace]
            
            while !queue.isEmpty {
                let faceIdx = queue.removeFirst()
                guard !visited.contains(faceIdx) else { continue }
                
                visited.insert(faceIdx)
                body.append(faceIdx)
                
                // Add all unvisited neighbors
                if faceIdx < faces.count {
                    for neighborIdx in faces[faceIdx].neighbors {
                        if let nIdx = neighborIdx, !visited.contains(nIdx) {
                            queue.append(nIdx)
                        }
                    }
                }
            }
            
            if !body.isEmpty {
                bodies.append(body)
            }
        }
        
        return bodies
    }
    
    /// Get boundary edges (edges with only one adjacent face)
    func findBoundaryEdges() -> [MeshEdge] {
        return edgeToFaces.compactMap { edge, faceList in
            faceList.count == 1 ? edge : nil
        }
    }
}

// MARK: - Extended Gaussian Image (EGI) Analysis

/// Analyzes face normals to classify stock type using EGI + PCA
class ExtendedGaussianImage {
    struct NormalPoint {
        let x: Double, y: Double, z: Double
    }
    
    /// Map face normals to unit sphere and analyze distribution
    static func analyze(normals: [SCNVector3], axis: SCNVector3) -> StockClassification {
        guard normals.count >= 10 else { return .unknown }
        
        // Convert normals to unit sphere points
        var spherePoints: [NormalPoint] = []
        for normal in normals {
            let magnitude = sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
            if magnitude > 0.0001 {
                spherePoints.append(NormalPoint(
                    x: Double(normal.x / magnitude),
                    y: Double(normal.y / magnitude),
                    z: Double(normal.z / magnitude)
                ))
            }
        }
        
        // Compute covariance matrix of normal distribution
        let n = Double(spherePoints.count)
        let meanX = spherePoints.reduce(0) { $0 + $1.x } / n
        let meanY = spherePoints.reduce(0) { $0 + $1.y } / n
        let meanZ = spherePoints.reduce(0) { $0 + $1.z } / n
        
        var covXX: Double = 0, covYY: Double = 0, covZZ: Double = 0
        var covXY: Double = 0, covXZ: Double = 0, covYZ: Double = 0
        
        for p in spherePoints {
            let dx = p.x - meanX
            let dy = p.y - meanY
            let dz = p.z - meanZ
            covXX += dx * dx
            covYY += dy * dy
            covZZ += dz * dz
            covXY += dx * dy
            covXZ += dx * dz
            covYZ += dy * dz
        }
        
        // Find eigenvalues using power iteration
        let eigenvalues = computeEigenvalues(
            covXX/n, covYY/n, covZZ/n,
            covXY/n, covXZ/n, covYZ/n
        )
        
        // Classify based on eigenvalue distribution
        let sortedEigenvalues = eigenvalues.sorted(by: >)
        let totalVariance = sortedEigenvalues.reduce(0, +)
        
        guard totalVariance > 0.0001 else { return .unknown }
        
        let varianceRatios = sortedEigenvalues.map { $0 / totalVariance }
        
        // EGI Classification Logic:
        // - Round tube: One dominant eigenvalue (normals form a great circle)
        // - Square/Rectangular: Multiple significant eigenvalues (normals cluster at discrete points)
        
        if varianceRatios[0] > 0.6 && varianceRatios[1] < 0.3 {
            // One dominant direction → Round tube (normals form equator on sphere)
            return .round(confidence: CGFloat(varianceRatios[0]))
        } else if varianceRatios[0] > 0.4 && varianceRatios[1] > 0.2 {
            // Multiple significant directions → Rectangular/Square
            // Check if aspect ratio suggests square
            return .rectangularOrSquare(confidence: CGFloat(varianceRatios[0] + varianceRatios[1]))
        } else {
            return .unknown
        }
    }
    
    /// Compute eigenvalues of 3x3 symmetric covariance matrix using Jacobi method
    private static func computeEigenvalues(
        _ xx: Double, _ yy: Double, _ zz: Double,
        _ xy: Double, _ xz: Double, _ yz: Double
    ) -> [Double] {
        // Simplified: use characteristic polynomial for 3x3 symmetric matrix
        // |A - λI| = 0
        // -λ³ + (xx+yy+zz)λ² - (xx*yy + xx*zz + yy*zz - xy² - xz² - yz²)λ + det(A) = 0
        
        let trace = xx + yy + zz
        let sumMinors = xx*yy + xx*zz + yy*zz - xy*xy - xz*xz - yz*yz
        let det = xx*(yy*zz - yz*yz) - xy*(xy*zz - xz*yz) + xz*(xy*yz - xz*yy)
        
        // Solve cubic equation using Cardano's formula
        let p = sumMinors - trace*trace/3
        let q = 2*trace*trace*trace/27 - trace*sumMinors/3 + det
        
        let discriminant = q*q/4 + p*p*p/27
        
        if discriminant > 0 {
            // One real root
            let sqrtDisc = sqrt(discriminant)
            let u = cbrt(-q/2 + sqrtDisc)
            let v = cbrt(-q/2 - sqrtDisc)
            let eigenvalue1 = u + v - trace/3
            return [eigenvalue1, 0, 0]
        } else {
            // Three real roots (typical for covariance matrices)
            let r = sqrt(-p*p*p/27)
            let theta = acos(-q/(2*r))
            let cubeRootR = cbrt(r)
            
            let eigenvalue1 = 2*cubeRootR*cos(theta/3) - trace/3
            let eigenvalue2 = 2*cubeRootR*cos((theta + 2*.pi)/3) - trace/3
            let eigenvalue3 = 2*cubeRootR*cos((theta + 4*.pi)/3) - trace/3
            
            return [eigenvalue1, eigenvalue2, eigenvalue3].map { max(0, $0) }  // Eigenvalues must be non-negative
        }
    }
}

enum StockClassification {
    case round(confidence: CGFloat)
    case rectangularOrSquare(confidence: CGFloat)
    case unknown
}

// MARK: - Least-Squares Cylinder Fit (Kåsa Method)

class CylinderFitter {
    /// Fit cylinder to vertices, returning accurate radius
    static func fit(vertices: [SCNVector3], axis: SCNVector3) -> CGFloat? {
        guard vertices.count >= 10 else { return nil }
        
        // Create orthonormal basis for cross-section plane
        let axisNorm = normalize(axis)
        let (u, v) = createOrthonormalBasis(axisNorm)
        
        // Project vertices onto cross-section plane
        var projectedPoints: [(x: Double, y: Double)] = []
        for vertex in vertices {
            let x = Double(vertex.x * u.x + vertex.y * u.y + vertex.z * u.z)
            let y = Double(vertex.x * v.x + vertex.y * v.y + vertex.z * v.z)
            projectedPoints.append((x: x, y: y))
        }
        
        // Kåsa least-squares circle fit
        guard let circle = fitCircle2DKåsa(points: projectedPoints) else { return nil }
        
        // Apply chord correction for tessellated geometry
        // True radius is slightly larger than fitted radius due to chord approximation
        let estimatedFacetsAroundCircumference = Double(projectedPoints.count) / 3  // Rough estimate
        let chordCorrection = 1.0 / cos(.pi / max(estimatedFacetsAroundCircumference, 12))
        let correctedRadius = circle.r * min(chordCorrection, 1.05)  // Cap correction at 5%
        
        return CGFloat(correctedRadius)
    }
    
    /// Kåsa least-squares circle fit to 2D points
    private static func fitCircle2DKåsa(points: [(x: Double, y: Double)]) -> (x: Double, y: Double, r: Double)? {
        guard points.count >= 3 else { return nil }
        
        let n = Double(points.count)
        
        // Compute centroid
        let sumX = points.reduce(0) { $0 + $1.x }
        let sumY = points.reduce(0) { $0 + $1.y }
        let avgX = sumX / n
        let avgY = sumY / n
        
        // Compute moments for Kåsa fit
        var sumXX: Double = 0, sumYY: Double = 0, sumXY: Double = 0
        var sumXXX: Double = 0, sumXYY: Double = 0, sumYXX: Double = 0, sumYYY: Double = 0
        
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
        
        // Solve normal equations
        let det = sumXX * sumYY - sumXY * sumXY
        if abs(det) < 0.0001 { return nil }  // Points are collinear
        
        let A = (sumYY * (sumYXX + sumYYY) - sumXY * (sumXXX + sumXYY)) / (2 * det)
        let B = (sumXX * (sumXXX + sumXYY) - sumXY * (sumYXX + sumYYY)) / (2 * det)
        
        let centerX = avgX + A
        let centerY = avgY + B
        
        // Compute radius as average distance from center
        var sumR: Double = 0
        for p in points {
            let dx = p.x - centerX
            let dy = p.y - centerY
            sumR += sqrt(dx * dx + dy * dy)
        }
        let radius = sumR / n
        
        return (centerX, centerY, radius)
    }
    
    /// Create orthonormal basis (u, v) perpendicular to axis
    private static func createOrthonormalBasis(_ axis: SCNVector3) -> (SCNVector3, SCNVector3) {
        // Find a vector not parallel to axis
        let tempAxis = abs(axis.x) < 0.9 ? SCNVector3(1, 0, 0) : SCNVector3(0, 1, 0)
        
        // u = axis × tempAxis (normalized)
        var u = cross(axis, tempAxis)
        u = normalize(u)
        
        // v = axis × u (normalized, already perpendicular to both)
        var v = cross(axis, u)
        v = normalize(v)
        
        return (u, v)
    }
    
    private static func normalize(_ v: SCNVector3) -> SCNVector3 {
        let mag = sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
        return mag > 0.0001 ? SCNVector3(v.x/mag, v.y/mag, v.z/mag) : SCNVector3(0, 0, 1)
    }
    
    private static func cross(_ a: SCNVector3, _ b: SCNVector3) -> SCNVector3 {
        return SCNVector3(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x
        )
    }
}

// MARK: - Main STL Processing Pipeline

class STLPipeline {
    
    enum ProcessingError: Error {
        case emptyMesh
        case segmentationFailed
        case classificationFailed
    }
    
    /// Process STL through complete pipeline
    /// Returns segmented bodies with stock classification for each
    static func process(vertices: [SCNVector3], faces: [[Int]], normals: [SCNVector3]) throws -> [ProcessedBody] {
        guard !faces.isEmpty else {
            throw ProcessingError.emptyMesh
        }
        
        // Step 1: Multi-Body Segmentation using Half-Edge topological face-walking
        print("Step 1: Segmenting mesh into connected bodies...")
        let halfEdgeMesh = HalfEdgeMesh(vertices: vertices, faces: faces, normals: normals)
        let bodyFaceLists = halfEdgeMesh.segmentIntoBodies()
        
        print("  Found \(bodyFaceLists.count) separate body/bodies")
        
        // Step 2 & 3: Classify and measure each body
        var processedBodies: [ProcessedBody] = []
        
        for (bodyIdx, faceList) in bodyFaceLists.enumerated() {
            print("\nProcessing body \(bodyIdx + 1) (\(faceList.count) faces)...")
            
            // Extract body geometry
            let bodyVertices = Set(faceList.flatMap { faces[$0] })
            let bodyFaceNormals = faceList.compactMap { $0 < normals.count ? normals[$0] : nil }
            
            // Step 2: Stock Classification using EGI + PCA
            print("  Step 2: Classifying stock type using EGI+PCA...")
            let axis = computePrincipalAxis(vertices: Array(bodyVertices.map { vertices[$0] }))
            let classification = ExtendedGaussianImage.analyze(normals: bodyFaceNormals, axis: axis)
            
            // Step 3: Precision Dimensional Recovery
            print("  Step 3: Computing precise dimensions...")
            let dimensions = computeDimensions(
                vertices: Array(bodyVertices.map { vertices[$0] }),
                faces: faceList.map { faces[$0] },
                normals: bodyFaceNormals,
                classification: classification,
                axis: axis
            )
            
            processedBodies.append(ProcessedBody(
                faceIndices: faceList,
                classification: classification,
                dimensions: dimensions,
                axis: axis
            ))
        }
        
        return processedBodies
    }
    
    /// Compute principal axis using PCA
    private static func computePrincipalAxis(vertices: [SCNVector3]) -> SCNVector3 {
        guard vertices.count > 2 else { return SCNVector3(0, 0, 1) }
        
        // Compute centroid
        let centroid = SCNVector3(
            vertices.reduce(0) { $0 + $1.x } / CGFloat(vertices.count),
            vertices.reduce(0) { $0 + $1.y } / CGFloat(vertices.count),
            vertices.reduce(0) { $0 + $1.z } / CGFloat(vertices.count)
        )
        
        // Compute covariance matrix
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
        
        let n = CGFloat(vertices.count)
        covXX /= n; covYY /= n; covZZ /= n
        covXY /= n; covXZ /= n; covYZ /= n
        
        // Power iteration to find dominant eigenvector (principal axis)
        var v = SCNVector3(1, 0, 0)
        for _ in 0..<20 {
            let newX = covXX * v.x + covXY * v.y + covXZ * v.z
            let newY = covXY * v.x + covYY * v.y + covYZ * v.z
            let newZ = covXZ * v.x + covYZ * v.y + covZZ * v.z
            
            let len = sqrt(newX * newX + newY * newY + newZ * newZ)
            if len < 0.0001 { break }
            v = SCNVector3(newX/len, newY/len, newZ/len)
        }
        
        return v
    }
    
    /// Compute precise dimensions based on classification
    private static func computeDimensions(
        vertices: [SCNVector3],
        faces: [[Int]],
        normals: [SCNVector3],
        classification: StockClassification,
        axis: SCNVector3
    ) -> BodyDimensions {
        
        // Compute bounding box
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        var minZ = CGFloat.greatestFiniteMagnitude, maxZ = -CGFloat.greatestFiniteMagnitude
        
        for v in vertices {
            minX = min(minX, v.x); maxX = max(maxX, v.x)
            minY = min(minY, v.y); maxY = max(maxY, v.y)
            minZ = min(minZ, v.z); maxZ = max(maxZ, v.z)
        }
        
        let size = SCNVector3(maxX - minX, maxY - minY, maxZ - minZ)
        let length: CGFloat
        let crossSectionWidth: CGFloat
        let crossSectionHeight: CGFloat
        
        if abs(axis.x) > 0.9 {
            length = size.x
            crossSectionWidth = size.y
            crossSectionHeight = size.z
        } else if abs(axis.y) > 0.9 {
            length = size.y
            crossSectionWidth = size.x
            crossSectionHeight = size.z
        } else {
            length = size.z
            crossSectionWidth = size.x
            crossSectionHeight = size.y
        }
        
        switch classification {
        case .round(let confidence):
            // Use least-squares cylinder fit for accurate OD
            if let radius = CylinderFitter.fit(vertices: vertices, axis: axis) {
                print("    → ROUND tube: OD = \(String(format: "%.2f", radius * 2))mm (confidence: \(String(format: "%.1f", confidence * 100))%)")
                return BodyDimensions(
                    profile: .round,
                    outerDiameter: radius * 2,
                    width: nil,
                    height: nil,
                    length: length,
                    axis: axis
                )
            } else {
                // Fallback to bounding box
                let od = max(crossSectionWidth, crossSectionHeight)
                print("    → ROUND tube: OD = \(String(format: "%.2f", od))mm (fallback, confidence: \(String(format: "%.1f", confidence * 100))%)")
                return BodyDimensions(
                    profile: .round,
                    outerDiameter: od,
                    width: nil,
                    height: nil,
                    length: length,
                    axis: axis
                )
            }
            
        case .rectangularOrSquare(let confidence):
            let aspectRatio = max(crossSectionWidth, crossSectionHeight) / min(crossSectionWidth, crossSectionHeight)
            let profile: BodyDimensions.Profile = aspectRatio < 1.1 ? .square : .rectangular
            
            print("    → \(profile.rawValue.uppercased()) tube: \(String(format: "%.2f", crossSectionWidth)) × \(String(format: "%.2f", crossSectionHeight))mm (confidence: \(String(format: "%.1f", confidence * 100))%)")
            
            return BodyDimensions(
                profile: profile,
                outerDiameter: nil,
                width: crossSectionWidth,
                height: crossSectionHeight,
                length: length,
                axis: axis
            )
            
        case .unknown:
            print("    → UNKNOWN profile, using bounding box fallback")
            return BodyDimensions(
                profile: .unknown,
                outerDiameter: nil,
                width: crossSectionWidth,
                height: crossSectionHeight,
                length: length,
                axis: axis
            )
        }
    }
}

// MARK: - Data Structures

struct ProcessedBody {
    let faceIndices: [Int]
    let classification: StockClassification
    let dimensions: BodyDimensions
    let axis: SCNVector3
}

struct BodyDimensions {
    enum Profile: String {
        case round = "round"
        case square = "square"
        case rectangular = "rectangular"
        case unknown = "unknown"
    }
    
    let profile: Profile
    let outerDiameter: CGFloat?  // For round tubes
    let width: CGFloat?          // For square/rectangular
    let height: CGFloat?         // For square/rectangular
    let length: CGFloat
    let axis: SCNVector3
}
