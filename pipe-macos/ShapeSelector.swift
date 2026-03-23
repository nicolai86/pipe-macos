import Foundation
import SceneKit

/// Handles shape selection and analysis for 3D models
/// Note: Most functionality is now handled by Model3DView's Coordinator
class ShapeSelector {
    
    /// Highlight selected shape, profile-matching shapes, and an optional hovered shape.
    /// Colors:
    ///   selected → orange
    ///   matching → cyan  (0, 0.7, 1.0)
    ///   hovered  → lime-green (0.1, 1.0, 0.2)  – overrides cyan for that node
    func highlight(_ shape: SelectedShape?, matching: [SelectedShape] = [],
                   hovered: SelectedShape? = nil, in view: SCNView) {
        view.scene?.rootNode.enumerateChildNodes { node, _ in
            node.geometry?.firstMaterial?.emission.contents = NSColor.clear
        }
        if let node = shape?.node {
            node.geometry?.firstMaterial?.emission.contents = NSColor.orange
        }
        for m in matching {
            m.node?.geometry?.firstMaterial?.emission.contents =
                NSColor(red: 0.0, green: 0.7, blue: 1.0, alpha: 1.0)
        }
        // Hovered overrides whatever color the node already got (cyan for matching).
        if let hv = hovered {
            hv.node?.geometry?.firstMaterial?.emission.contents =
                NSColor(red: 0.1, green: 1.0, blue: 0.2, alpha: 1.0)
        }
    }
}
