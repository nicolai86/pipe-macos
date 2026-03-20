import Foundation
import SceneKit

/// Handles shape selection and analysis for 3D models
/// Note: Most functionality is now handled by Model3DView's Coordinator
class ShapeSelector {
    
    /// Highlight selected shape and optionally a set of profile-matching shapes.
    func highlight(_ shape: SelectedShape?, matching: [SelectedShape] = [], in view: SCNView) {
        view.scene?.rootNode.enumerateChildNodes { node, _ in
            node.geometry?.firstMaterial?.emission.contents = NSColor.clear
        }
        if let node = shape?.node {
            node.geometry?.firstMaterial?.emission.contents = NSColor.orange
        }
        for m in matching {
            m.node?.geometry?.firstMaterial?.emission.contents = NSColor(red: 0.0, green: 0.7, blue: 1.0, alpha: 1.0)
        }
    }
}
