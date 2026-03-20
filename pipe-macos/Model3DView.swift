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
        // Update nodes safely
        if scnView.scene?.rootNode.childNodes.contains(where: { $0.name?.hasPrefix("model_") == true }) == false {
            if let root = viewModel.loadedModel?.rootNode {
                for child in root.childNodes {
                    scnView.scene?.rootNode.addChildNode(child)
                }
                
                // Auto-frame camera to encompass the new model
                scnView.scene?.rootNode.enumerateChildNodes { node, _ in
                    if node.name?.hasPrefix("model_") == true {
                        scnView.pointOfView?.look(at: node.position)
                    }
                }
            }
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
    
    @objc func handleTap(_ gestureRecognize: NSGestureRecognizer) {
        guard let scnView = scnView, let viewModel = viewModel else { return }
        
        let p = gestureRecognize.location(in: scnView)
        let hitResults = scnView.hitTest(p, options: [:])
        
        if let result = hitResults.first(where: { $0.node.name?.hasPrefix("model_") == true }) {
            if let selected = viewModel.loadedModel?.selectableShapes.first(where: { $0.node === result.node }) {
                viewModel.selectedShape = selected
                let selector = ShapeSelector()
                selector.highlight(selected, in: scnView)
            }
        } else {
            viewModel.selectedShape = nil
            let selector = ShapeSelector()
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
