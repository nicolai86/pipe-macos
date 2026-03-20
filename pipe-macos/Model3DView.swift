import SwiftUI
import SceneKit

struct Model3DView: View {
    @ObservedObject var viewModel: AppViewModel
    
    var body: some View {
        SceneKitView(viewModel: viewModel)
            .background(Color.gray.opacity(0.2))
    }
}

struct SceneKitView: NSViewRepresentable {
    @ObservedObject var viewModel: AppViewModel
    
    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.scene = SCNScene()
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true
        scnView.backgroundColor = NSColor.black
        
        // Setup Camera & Lights (existing logic)
        setupBaseScene(scnView)
        
        // ADD COORDINATE SYSTEM AT 0,0,0
        addAxes(to: scnView.scene!.rootNode)

        // Setup gesture recognizer for selection
        let clickGesture = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        scnView.addGestureRecognizer(clickGesture)
        context.coordinator.scnView = scnView
        context.coordinator.viewModel = viewModel

        return scnView
    }
    
    /// Configures the camera and manual lighting for the scene
    private func setupBaseScene(_ scnView: SCNView) {
        let scene = scnView.scene!
        
        // Camera setup
        let cameraNode = SCNNode()
        cameraNode.name = "camera"
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 45
        cameraNode.position = SCNVector3(x: 0, y: 0, z: 5)
        scene.rootNode.addChildNode(cameraNode)
        scnView.pointOfView = cameraNode
        
        // Ambient Light: Overall visibility
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 400
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)
        
        // Directional Light: Defines shapes and shadows
        let directionalLight = SCNLight()
        directionalLight.type = .directional
        directionalLight.intensity = 1000
        let directionalNode = SCNNode()
        directionalNode.light = directionalLight
        directionalNode.position = SCNVector3(x: 5, y: 5, z: 10)
        directionalNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(directionalNode)
    }
    
    // Helper to build the XYZ Axis Helper
    private func addAxes(to rootNode: SCNNode) {
        let axisLength: CGFloat = 1.0
        let axisThickness: CGFloat = 0.005
        
        func createAxis(direction: SCNVector3, color: NSColor) -> SCNNode {
            let cylinder = SCNCylinder(radius: axisThickness, height: axisLength)
            cylinder.firstMaterial?.diffuse.contents = color
            let node = SCNNode(geometry: cylinder)
            
            // Align cylinder with the axis direction
            if direction.x != 0 {
                node.eulerAngles.z = .pi / 2
                node.position = SCNVector3(axisLength/2, 0, 0)
            } else if direction.y != 0 {
                node.position = SCNVector3(0, axisLength/2, 0)
            } else if direction.z != 0 {
                node.eulerAngles.x = .pi / 2
                node.position = SCNVector3(0, 0, axisLength/2)
            }
            return node
        }

        rootNode.addChildNode(createAxis(direction: SCNVector3(1, 0, 0), color: .red))   // X-Axis
        rootNode.addChildNode(createAxis(direction: SCNVector3(0, 1, 0), color: .green)) // Y-Axis
        rootNode.addChildNode(createAxis(direction: SCNVector3(0, 0, 1), color: .blue))  // Z-Axis
    }
    
    func updateNSView(_ scnView: SCNView, context: Context) {
        // Update scene when model changes
        if let model = viewModel.loadedModel {
            let modelChanged = context.coordinator.modelHash != (model.vertexCount + model.faceCount)
            let viewModeChanged = context.coordinator.currentViewMode != viewModel.viewMode
            
            if modelChanged {
                context.coordinator.updateScene(with: model, in: scnView, viewMode: viewModel.viewMode, modelChanged: true)
            } else if viewModeChanged {
                // Model didn't change, but view mode did - update fill mode
                updateViewMode(in: scnView, viewMode: viewModel.viewMode)
                context.coordinator.currentViewMode = viewModel.viewMode
            }
        } else {
            // Update view mode for existing model
            updateViewMode(in: scnView, viewMode: viewModel.viewMode)
        }

        context.coordinator.selectionMode = viewModel.selectionMode
    }
    
    private func updateViewMode(in scnView: SCNView, viewMode: ViewMode) {
        scnView.scene?.rootNode.enumerateChildNodes { (node, _) in
            guard let geometry = node.geometry else { return }
            
            switch viewMode {
            case .wireframe:
                geometry.firstMaterial?.fillMode = .lines
            case .solid:
                geometry.firstMaterial?.fillMode = .fill
            }
        }
        // Force redraw
        scnView.needsDisplay = true
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject {
        weak var scnView: SCNView?
        weak var viewModel: AppViewModel?
        var selectionMode: Bool = false
        var shapeDataMap: [String: ShapeData] = [:]
        var selectedNodeName: String?
        var currentViewMode: ViewMode?
        var modelHash: Int?

        func updateScene(with model: Model3D, in scnView: SCNView, viewMode: ViewMode = .solid, modelChanged: Bool = true) {
            let viewModeChanged = currentViewMode != viewMode
            currentViewMode = viewMode

            // Rebuild geometry only if model actually changed
            if modelChanged {
                modelHash = model.vertexCount + model.faceCount
                rebuildScene(with: model, in: scnView, viewMode: viewMode)
            } else if viewModeChanged {
                // Model didn't change, but view mode did - just update fill mode
                updateViewMode(in: scnView, viewMode: viewMode)
            }

            // Always reapply highlight after any update
            reapplyHighlight(in: scnView)
        }
        
        func rebuildScene(with model: Model3D, in scnView: SCNView, viewMode: ViewMode) {

            print("=== Updating 3D Scene ===")
            print("Model: \(model.name)")
            print("  Vertices: \(model.vertexCount)")
            print("  Faces: \(model.faceCount)")
            print("  Meshes: \(model.meshes.count)")
            print("  View mode: \(viewMode)")

            // Clear existing nodes (keep lights and camera)
            print("  Clearing existing nodes...")
            var clearedCount = 0
            scnView.scene?.rootNode.enumerateChildNodes { (node, _) in
                if node.name != nil && (node.name!.hasPrefix("model_") || node.name == "model_root") {
                    print("    Removing node: \(node.name ?? "unnamed")")
                    node.removeFromParentNode()
                    clearedCount += 1
                }
            }
            print("  Cleared \(clearedCount) nodes")

            // Clear shape data map
            shapeDataMap.removeAll()

            // Create model node and position at origin
            let modelNode = SCNNode()
            modelNode.name = "model_root"
            modelNode.position = SCNVector3(0, 0, 0)

            // Add geometry for each mesh
            for (index, mesh) in model.meshes.enumerated() {
                print("  Mesh \(index): \(mesh.vertices.count) vertices, \(mesh.faces.count) faces")

                if mesh.vertices.isEmpty || mesh.faces.isEmpty {
                    print("    Warning: Empty mesh, skipping")
                    continue
                }

                // Create geometry with explicit vertex and face data
                let geometry = SCNGeometry(vertices: mesh.vertices, faces: mesh.faces)

                print("    Geometry created: \(geometry.sources.count) sources, \(geometry.elements.count) elements")
                print("    First vertex: \(mesh.vertices.first ?? SCNVector3(0,0,0))")
                print("    First face: \(mesh.faces.first ?? [])")

                // Use professional blue-gray material with emission for visibility
                let material = SCNMaterial()
                material.diffuse.contents = NSColor.systemBlue
                material.emission.contents = NSColor.systemBlue.withAlphaComponent(0.4)
                material.specular.contents = NSColor.white
                material.shininess = 0.3
                material.isDoubleSided = true
                material.lightingModel = .phong
                
                // Apply view mode
                switch viewMode {
                case .wireframe:
                    material.fillMode = .lines
                case .solid:
                    material.fillMode = .fill
                }
                
                geometry.materials = [material]

                let node = SCNNode(geometry: geometry)
                node.name = "model_\(index)"
                node.position = SCNVector3(0, 0, 0)  // Position at origin
                node.scale = SCNVector3(1, 1, 1)  // No scaling on individual nodes
                modelNode.addChildNode(node)

                print("    Added model node")

                // Store shape data in map
                if let shapeData = mesh.shapeData {
                    shapeDataMap["model_\(index)"] = shapeData
                    print("    Shape type: \(shapeData.type.rawValue), cuttable: \(shapeData.isCuttable)")
                }
            }

            // Calculate bounding box BEFORE adding to scene
            let tempBoundingBox = modelNode.boundingBox
            let min = tempBoundingBox.min
            let max = tempBoundingBox.max
            
            print("  Bounding box:")
            print("    Min: (\(min.x), \(min.y), \(min.z))")
            print("    Max: (\(max.x), \(max.y), \(max.z))")
            
            // Calculate center and size
            let center = SCNVector3(
                (min.x + max.x) / 2,
                (min.y + max.y) / 2,
                (min.z + max.z) / 2
            )
            
            let size = SCNVector3(
                max.x - min.x,
                max.y - min.y,
                max.z - min.z
            )
            
            print("    Center: (\(center.x), \(center.y), \(center.z))")
            print("    Size: (\(size.x), \(size.y), \(size.z))")
            
            // Center each child node's geometry so the model is at origin
            for child in modelNode.childNodes {
                child.position = SCNVector3(
                    -center.x,
                    -center.y,
                    -center.z
                )
            }
            
            print("    Centered model at origin")
            
            // Scale the entire model to fit view
            let maxDim = Swift.max(size.x, Swift.max(size.y, size.z))
            var overallScale: CGFloat = 1.0
            if maxDim > 0 {
                overallScale = 2.0 / maxDim
                modelNode.scale = SCNVector3(overallScale, overallScale, overallScale)
                print("    Scale factor: \(overallScale)")
            }
            
            // Calculate scaled size
            let scaledSize = SCNVector3(size.x * overallScale, size.y * overallScale, size.z * overallScale)
            print("  Scaled size: (\(scaledSize.x), \(scaledSize.y), \(scaledSize.z))")
            
            scnView.scene?.rootNode.addChildNode(modelNode)

            // Verify model was added to scene
            print("  Model added to scene graph")
            print("  Scene has \(scnView.scene?.rootNode.childNodes.count ?? 0) child nodes")
            print("  Model node has \(modelNode.childNodes.count) child nodes")
            
            // Debug: print model position
            print("  Model node position: (\(modelNode.position.x), \(modelNode.position.y), \(modelNode.position.z))")
            print("  Model node scale: (\(modelNode.scale.x), \(modelNode.scale.y), \(modelNode.scale.z))")
            
            // Adjust camera to frame the model using SCALED size
            adjustCameraToFrameModel(scaledSize: scaledSize, in: scnView)

            // Force a redraw
            scnView.needsDisplay = true
            print("  Scene update complete: \(shapeDataMap.count) meshes with shape data")
        }

        private func adjustCameraToFrameModel(scaledSize: SCNVector3, in scnView: SCNView) {
            // Model is centered at origin
            let center = SCNVector3(0, 0, 0)
            
            let maxDim = Swift.max(scaledSize.x, Swift.max(scaledSize.y, scaledSize.z))
            
            // Calculate camera distance to fit entire model in view
            let cameraDistance = maxDim * 2.0
            
            // Position camera to see the model from an angle
            let cameraPos = SCNVector3(
                cameraDistance * 0.5,
                cameraDistance * 0.5,
                cameraDistance
            )
            
            print("  Camera framing:")
            print("    Scaled model size: (\(scaledSize.x), \(scaledSize.y), \(scaledSize.z))")
            print("    Max dim: \(maxDim)")
            print("    Camera distance: \(cameraDistance)")
            print("    Camera position: (\(cameraPos.x), \(cameraPos.y), \(cameraPos.z))")
            
            // Find or create camera
            var cameraNode: SCNNode? = scnView.scene?.rootNode.childNode(withName: "camera", recursively: true)
            if cameraNode == nil {
                cameraNode = SCNNode()
                cameraNode?.name = "camera"
                cameraNode?.camera = SCNCamera()
                cameraNode?.camera?.fieldOfView = 45
                scnView.scene?.rootNode.addChildNode(cameraNode!)
            }
            
            cameraNode?.position = cameraPos
            cameraNode?.look(at: center)
            
            // Set as point of view
            scnView.pointOfView = cameraNode
            scnView.allowsCameraControl = true
            scnView.defaultCameraController.pointOfView = cameraNode
            
            print("    Camera configured - looking at origin")
        }
        
        @objc func handleTap(_ gesture: NSClickGestureRecognizer) {
            guard selectionMode,
                  let scnView = scnView,
                  let viewModel = viewModel else { return }

            let location = gesture.location(in: scnView)

            // Perform hit test
            let hitResults = scnView.hitTest(location, options: [
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue,
                SCNHitTestOption.boundingBoxOnly: false
            ])

            // Find the mesh node that has shape data (traverse up the node hierarchy)
            for hit in hitResults {
                var currentNode: SCNNode? = hit.node
                while currentNode != nil {
                    if let nodeName = currentNode?.name,
                       let shapeData = shapeDataMap[nodeName] {
                        print("Selected: \(nodeName), type: \(shapeData.type.rawValue)")
                        
                        let selectedShape = SelectedShape(
                            shapeType: shapeData.type.rawValue,
                            dimensions: shapeData.dimensions,
                            isCuttable: shapeData.isCuttable,
                            node: currentNode
                        )
                        viewModel.selectShape(selectedShape)

                        // Highlight selected node
                        highlightNode(currentNode!)
                        return
                    }
                    currentNode = currentNode?.parent
                }
            }
            
            print("No shape data found for hit")
        }

        func highlightNode(_ node: SCNNode) {
            // Reset all materials to default blue
            scnView?.scene?.rootNode.enumerateChildNodes { (n, _) in
                if n.name != nil && n.name!.hasPrefix("model_") {
                    n.geometry?.firstMaterial?.emission.contents = NSColor.systemBlue.withAlphaComponent(0.4)
                    n.geometry?.firstMaterial?.diffuse.contents = NSColor.systemBlue
                }
            }

            // Highlight selected node in red
            node.geometry?.firstMaterial?.emission.contents = NSColor.red
            node.geometry?.firstMaterial?.diffuse.contents = NSColor.red

            // Store reference to selected node by name
            selectedNodeName = node.name
        }
        
        func reapplyHighlight(in scnView: SCNView) {
            guard let name = selectedNodeName,
                  let node = scnView.scene?.rootNode.childNode(withName: name, recursively: true) else {
                return
            }
            node.geometry?.firstMaterial?.emission.contents = NSColor.red
            node.geometry?.firstMaterial?.diffuse.contents = NSColor.red
        }
        
        func updateViewMode(in scnView: SCNView, viewMode: ViewMode) {
            scnView.scene?.rootNode.enumerateChildNodes { (node, _) in
                guard let geometry = node.geometry,
                      node.name != nil && node.name!.hasPrefix("model_") else { return }
                
                switch viewMode {
                case .wireframe:
                    geometry.firstMaterial?.fillMode = .lines
                case .solid:
                    geometry.firstMaterial?.fillMode = .fill
                }
            }
            // Force redraw
            scnView.needsDisplay = true
        }
    }
}

// MARK: - SCNGeometry helpers
extension SCNGeometry {
    convenience init(vertices: [SCNVector3], faces: [[Int]]) {
        // Create vertices source with explicit format
        let vertexSource = SCNGeometrySource(vertices: vertices)
        
        // Create indices for faces
        var indices: [Int32] = []
        for face in faces {
            // Convert to triangle fan for polygons with more than 3 vertices
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
