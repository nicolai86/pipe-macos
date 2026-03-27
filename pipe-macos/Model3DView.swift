import SwiftUI
import SceneKit
import simd

struct Model3DView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        SceneKitView(viewModel: viewModel)
            .background(Color.gray.opacity(0.2))
    }
}

struct SceneKitView: NSViewRepresentable {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var displayManager = CutPresetManager.shared

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = SCNScene()
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.backgroundColor = NSColor(white: 0.1, alpha: 1.0)
        
        setupBaseScene(scnView)
        addAxes(to: scnView.scene!.rootNode)

        let clickGesture = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        scnView.addGestureRecognizer(clickGesture)
        context.coordinator.scnView = scnView
        context.coordinator.viewModel = viewModel

        return scnView
    }
    
    func updateNSView(_ scnView: SCNView, context: Context) {
        // Track if we have a model in the view model
        let hasModelInViewModel = viewModel.loadedModel != nil
        
        // If view model has a model but it's a different model, reset the scene
        if hasModelInViewModel && !context.coordinator.isCurrentModel(viewModel.loadedModel) {
            // Remove all old model nodes
            scnView.scene?.rootNode.enumerateChildNodes { node, _ in
                if node.name?.hasPrefix("model_") == true {
                    node.removeFromParentNode()
                }
            }
            
            // Clear any highlighting
            let selector = ShapeSelector()
            selector.highlight(nil, in: scnView)
            
            // Add new model nodes (they're already centered at 0,0,0 by ModelLoader)
            if let root = viewModel.loadedModel?.rootNode {
                for child in root.childNodes {
                    scnView.scene?.rootNode.addChildNode(child)
                }
            }
            
            // Reset camera to default position looking at origin (0,0,0)
            // Only reset if this is the first model OR user requested a reset
            if context.coordinator.currentModelURL == nil {
                if let cameraNode = scnView.pointOfView {
                    cameraNode.position = SCNVector3(x: 200, y: 200, z: 500)
                    cameraNode.look(at: SCNVector3(0, 0, 0))
                }
            }
            // For subsequent models, keep the camera where the user positioned it
            
            // Update the coordinator's tracking
            context.coordinator.currentModelURL = viewModel.loadedModel?.url
        }
        
        // Handle view mode changes
        let viewMode = viewModel.viewMode
        scnView.scene?.rootNode.enumerateChildNodes { node, _ in
            guard node.name?.hasPrefix("model_") == true else { return }
            switch viewMode {
            case .wireframe:
                node.geometry?.firstMaterial?.fillMode = .lines
            case .solid:
                node.geometry?.firstMaterial?.fillMode = .fill
            }
        }
        switch displayManager.displaySettings.viewBackground {
        case .dark:  scnView.backgroundColor = NSColor(white: 0.1, alpha: 1.0)
        case .light: scnView.backgroundColor = NSColor(white: 0.85, alpha: 1.0)
        }

        // Re-apply the full highlight state so sidebar hover changes are reflected
        // without requiring the user to click inside the 3D view.
        ShapeSelector().highlight(
            viewModel.selectedShape,
            matching: viewModel.matchingShapes,
            hovered: viewModel.hoveredShape,
            in: scnView
        )

        // Update toolpath overlay whenever generation counter or selected feature changes
        let overlayGen = viewModel.toolpathOverlayGeneration
        let selFID = viewModel.selectedFeatureID
        if context.coordinator.lastOverlayGeneration != overlayGen
            || context.coordinator.lastSelectedFeatureID != selFID {
            context.coordinator.lastOverlayGeneration = overlayGen
            context.coordinator.lastSelectedFeatureID = selFID
            rebuildToolpathOverlay(in: scnView, viewModel: viewModel)
        }

        scnView.needsDisplay = true
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    private func setupBaseScene(_ scnView: SCNView) {
        let scene = scnView.scene!
        
        // 1. Camera Setup
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        let camera = SCNCamera()
        // FIX: Increase zFar from default 100 to 100,000 so offset CAD files are never clipped
        camera.zFar = 100000.0
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(x: 200, y: 200, z: 500)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)
        
        // 2. Add some ambient light so dark areas aren't completely black
        let ambientLightNode = SCNNode()
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.color = NSColor(white: 0.3, alpha: 1.0)
        ambientLightNode.light = ambientLight
        scene.rootNode.addChildNode(ambientLightNode)
    }
    
    // MARK: - Toolpath Overlay

    /// Rebuilds the lead-in (orange) and cut-path (cyan) tube overlays on the tube surface.
    /// When a feature is selected, it is rendered full-brightness and others are dimmed.
    private func rebuildToolpathOverlay(in scnView: SCNView, viewModel: AppViewModel) {
        guard let scene = scnView.scene else { return }

        // Remove existing overlay nodes
        scene.rootNode.enumerateChildNodes { node, _ in
            if node.name?.hasPrefix("overlay_") == true { node.removeFromParentNode() }
        }

        guard let stock = viewModel.overlayStock, !viewModel.toolpathOverlay.isEmpty else { return }

        let vAxis = SIMD3<Float>(
            stock.axis.y * stock.uAxis.z - stock.axis.z * stock.uAxis.y,
            stock.axis.z * stock.uAxis.x - stock.axis.x * stock.uAxis.z,
            stock.axis.x * stock.uAxis.y - stock.axis.y * stock.uAxis.x
        )
        let normV = sqrt(vAxis.x*vAxis.x + vAxis.y*vAxis.y + vAxis.z*vAxis.z)
        let vAxisN = normV > 1e-6 ? vAxis / normV : SIMD3<Float>(0, 0, 1)

        let selectedID = viewModel.selectedFeatureID
        let hasSelection = selectedID != nil

        for planned in viewModel.toolpathOverlay {
            let fid = planned.source.id
            let isSelected = fid == selectedID
            // Selected: full brightness + thicker tubes; others: dim
            let alpha: CGFloat = hasSelection ? (isSelected ? 1.0 : 0.18) : 0.85
            let radius: CGFloat = isSelected ? 1.0 : 0.6

            // Lead-in — orange (selected: gold)
            if !planned.plannedPath.leadInPoints.isEmpty {
                let pts = planned.plannedPath.leadInPoints.map { pt in
                    surfacePoint(x: Float(pt.x), aDeg: Float(pt.a), stock: stock, vAxis: vAxisN)
                }
                let color = isSelected
                    ? NSColor(red: 1.0, green: 0.75, blue: 0.0, alpha: alpha)
                    : NSColor.orange.withAlphaComponent(alpha)
                if let node = makeLineNode(points: pts, color: color, tubeRadius: radius) {
                    node.name = "overlay_leadin_\(fid)"
                    scene.rootNode.addChildNode(node)
                }
            }

            // Cut path — cyan (selected: bright white-cyan)
            if !planned.plannedPath.cutPoints.isEmpty {
                let pts = planned.plannedPath.cutPoints.map { pt in
                    surfacePoint(x: Float(pt.x), aDeg: Float(pt.a), stock: stock, vAxis: vAxisN)
                }
                let color = isSelected
                    ? NSColor(red: 0.4, green: 1.0, blue: 1.0, alpha: alpha)
                    : NSColor.cyan.withAlphaComponent(alpha)
                if let node = makeLineNode(points: pts, color: color, tubeRadius: radius) {
                    node.name = "overlay_cut_\(fid)"
                    scene.rootNode.addChildNode(node)
                }
            }

            // Lead-out — lime green (selected: bright yellow-green)
            if !planned.plannedPath.leadOutPoints.isEmpty {
                // Prepend last cut point so the lead-out tube starts from the cut exit
                let exitPt = planned.plannedPath.cutPoints.last ?? planned.plannedPath.leadOutPoints[0]
                let leadOutPts = [exitPt] + planned.plannedPath.leadOutPoints
                let pts = leadOutPts.map { pt in
                    surfacePoint(x: Float(pt.x), aDeg: Float(pt.a), stock: stock, vAxis: vAxisN)
                }
                let color = isSelected
                    ? NSColor(red: 0.6, green: 1.0, blue: 0.2, alpha: alpha)
                    : NSColor(red: 0.4, green: 0.9, blue: 0.1, alpha: alpha)
                if let node = makeLineNode(points: pts, color: color, tubeRadius: radius) {
                    node.name = "overlay_leadout_\(fid)"
                    scene.rootNode.addChildNode(node)
                }
            }
        }
    }

    /// Maps a surface-space `(x, aDeg)` point to a 3D world position on the tube surface.
    private func surfacePoint(
        x: Float, aDeg: Float, stock: StockInfo, vAxis: SIMD3<Float>
    ) -> SCNVector3 {
        let aRad = aDeg * Float.pi / 180.0
        // x is in [0, length] local stock space; convert to axial offset from tube centre
        let axial = x - Float(stock.length) / 2.0

        let r: Float
        if stock.profile == .round {
            r = Float((stock.od ?? 50.0) / 2.0)
        } else {
            // Rectangular: intersect the direction vector with the rectangular hull.
            // uAxisDimension is the face-to-face distance in the cosA (uAxis) direction;
            // the remaining dimension is in the sinA (vAxis) direction.
            let cosA = cos(aRad), sinA = sin(aRad)
            let hu: Float  // half-extent in uAxis direction (cosA)
            let hv: Float  // half-extent in vAxis direction (sinA)
            if let uDim = stock.uAxisDimension {
                hu = Float(uDim / 2.0)
                let totalFlat = Float((stock.odX ?? 50.0) + (stock.odY ?? 50.0))
                hv = (totalFlat - Float(uDim)) / 2.0
            } else {
                hu = Float((stock.odX ?? 50.0) / 2.0)
                hv = Float((stock.odY ?? 50.0) / 2.0)
            }
            let tu = abs(cosA) > 1e-4 ? hu / abs(cosA) : Float.greatestFiniteMagnitude
            let tv = abs(sinA) > 1e-4 ? hv / abs(sinA) : Float.greatestFiniteMagnitude
            r = min(tu, tv)
        }

        let p = stock.origin
            + stock.axis * axial
            + stock.uAxis * (r * cos(aRad))
            + vAxis * (r * sin(aRad))
        // Raise slightly off the surface so the overlay is always visible
        let normal = stock.uAxis * cos(aRad) + vAxis * sin(aRad)
        let lifted = p + normal * 0.5
        return SCNVector3(lifted.x, lifted.y, lifted.z)
    }

    /// Creates an SCNNode containing thin cylinder tubes between consecutive `points`.
    /// SCNGeometry `.line` primitives are 1 px in Metal and effectively invisible;
    /// cylinders are reliably rendered at any zoom level.
    private func makeLineNode(points: [SCNVector3], color: NSColor, tubeRadius: CGFloat = 0.6) -> SCNNode? {
        guard points.count >= 2 else { return nil }

        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.isDoubleSided = true
        mat.lightingModel = .constant

        let parent = SCNNode()
        for i in 0..<points.count - 1 {
            let a = points[i]
            let b = points[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
            let length = CGFloat(sqrt(dx*dx + dy*dy + dz*dz))
            guard length > 1e-4 else { continue }

            let cyl = SCNCylinder(radius: tubeRadius, height: length)
            cyl.materials = [mat]
            let seg = SCNNode(geometry: cyl)

            // Position at midpoint
            seg.position = SCNVector3(
                (a.x + b.x) / 2,
                (a.y + b.y) / 2,
                (a.z + b.z) / 2
            )

            // Rotate default Y-axis cylinder to align with the segment direction
            let dir = SIMD3<Float>(Float(dx), Float(dy), Float(dz)) / Float(length)
            let yAxis = SIMD3<Float>(0, 1, 0)
            let cross = simd_cross(yAxis, dir)
            let crossLen = simd_length(cross)
            if crossLen > 1e-6 {
                let angle = Float(asin(min(1.0, Double(crossLen))))
                let dot = simd_dot(yAxis, dir)
                let finalAngle = dot < 0 ? Float.pi - angle : angle
                seg.rotation = SCNVector4(cross.x / crossLen, cross.y / crossLen, cross.z / crossLen, finalAngle)
            } else if simd_dot(yAxis, dir) < 0 {
                // Anti-parallel: rotate 180° around X
                seg.rotation = SCNVector4(1, 0, 0, Float.pi)
            }

            parent.addChildNode(seg)
        }
        return parent
    }

    private func addAxes(to node: SCNNode) {
        let axisLength: CGFloat = 100.0
        let axisThickness: CGFloat = 1.0
        
        let xAxis = SCNNode(geometry: SCNCylinder(radius: axisThickness, height: axisLength))
        xAxis.geometry?.firstMaterial?.diffuse.contents = NSColor.red
        xAxis.position = SCNVector3(axisLength/2, 0, 0)
        xAxis.eulerAngles = SCNVector3(0, 0, Float.pi/2)
        
        let yAxis = SCNNode(geometry: SCNCylinder(radius: axisThickness, height: axisLength))
        yAxis.geometry?.firstMaterial?.diffuse.contents = NSColor.green
        yAxis.position = SCNVector3(0, axisLength/2, 0)
        
        let zAxis = SCNNode(geometry: SCNCylinder(radius: axisThickness, height: axisLength))
        zAxis.geometry?.firstMaterial?.diffuse.contents = NSColor.blue
        zAxis.position = SCNVector3(0, 0, axisLength/2)
        zAxis.eulerAngles = SCNVector3(Float.pi/2, 0, 0)
        
        node.addChildNode(xAxis)
        node.addChildNode(yAxis)
        node.addChildNode(zAxis)
    }
}

class Coordinator: NSObject {
    var scnView: SCNView?
    var viewModel: AppViewModel?
    var currentModelURL: URL?
    /// Tracks the last rendered overlay generation so we only rebuild when it changes.
    var lastOverlayGeneration: Int = -1
    /// Tracks the last selected feature ID so we rebuild highlighting when selection changes.
    var lastSelectedFeatureID: Int? = nil
    
    func isCurrentModel(_ model: Model3D?) -> Bool {
        return currentModelURL == model?.url
    }
    
    @objc func handleTap(_ gestureRecognize: NSGestureRecognizer) {
        guard let scnView = scnView, let viewModel = viewModel else { return }

        let p = gestureRecognize.location(in: scnView)
        let hitResults = scnView.hitTest(p, options: [:])
        let selector = ShapeSelector()

        if let result = hitResults.first(where: { $0.node.name?.hasPrefix("model_") == true }),
           let selected = viewModel.loadedModel?.selectableShapes.first(where: { $0.node === result.node }) {
            viewModel.selectShape(selected)   // also clears hoveredShape
            selector.highlight(selected, matching: viewModel.matchingShapes, hovered: nil, in: scnView)
        } else {
            viewModel.selectShape(nil)
            selector.highlight(nil, in: scnView)
        }
    }
}

extension SCNGeometry {
    convenience init(vertices: [SCNVector3], faces: [[Int]]) {
        let vertexSource = SCNGeometrySource(vertices: vertices)
        
        var indices: [Int32] = []
        for face in faces {
            if face.count >= 3 {
                for i in 1..<(face.count - 1) {
                    indices.append(Int32(face[0]))
                    indices.append(Int32(face[i]))
                    indices.append(Int32(face[i + 1]))
                }
            }
        }
        
        let indexData = Data(bytes: indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: indices.count / 3,
            bytesPerIndex: MemoryLayout<Int32>.size
        )
        
        self.init(sources: [vertexSource], elements: [element])
    }
}
