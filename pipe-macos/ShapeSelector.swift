import Foundation
import SceneKit

/// Handles shape selection and analysis for 3D models
/// Note: Most functionality is now handled by Model3DView's Coordinator
class ShapeSelector {
    
    /// Highlight selected shape
    func highlight(_ shape: SelectedShape?, in view: SCNView) {
        // Reset all highlights
        view.scene?.rootNode.enumerateChildNodes { node, _ in
            node.geometry?.firstMaterial?.emission.contents = NSColor.clear
        }
        
        // Highlight selected
        if let shape = shape, let node = shape.node {
            node.geometry?.firstMaterial?.emission.contents = NSColor.red
        }
    }
}
