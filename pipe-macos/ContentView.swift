import SwiftUI
import UniformTypeIdentifiers
import SceneKit
import simd

// MARK: - UTType Extensions
extension UTType {
    static var step: UTType {
        UTType(filenameExtension: "step", conformingTo: .data) ?? .data
    }

    static var stp: UTType {
        UTType(filenameExtension: "stp", conformingTo: .data) ?? .data
    }
}

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @State private var showingFilePicker = false
    @State private var showingSaveDialog = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            ToolbarView(viewModel: viewModel)

            Divider()

            // Main content
            HSplitView {
                // 3D View
                Model3DView(viewModel: viewModel)
                    .frame(minWidth: 400)

                // Side panel
                SidePanelView(viewModel: viewModel)
                    .frame(width: 300)
            }

            PackView(viewModel: viewModel)
        }
        .frame(minWidth: 800, minHeight: 500)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            setupNotifications()
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.step, .stp],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    viewModel.loadModel(from: url)
                }
            case .failure(let error):
                print("File picker error: \(error.localizedDescription)")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openModel)) { _ in
            showingFilePicker = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveGCode)) { _ in
            if viewModel.generatedGCode != nil {
                showingSaveDialog = true
            }
        }
        .fileExporter(
            isPresented: $showingSaveDialog,
            document: GCodeDocument(gcode: viewModel.generatedGCode ?? ""),
            contentType: .plainText,
            defaultFilename: "output.nc"
        ) { result in
            switch result {
            case .success(let url):
                print("GCode saved to: \(url.path)")
            case .failure(let error):
                print("Save error: \(error.localizedDescription)")
            }
        }
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            forName: .openModel,
            object: nil,
            queue: .main
        ) { _ in
            showingFilePicker = true
        }
    }
}

struct ToolbarView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { viewModel.openFile() }) {
                Label("Open", systemImage: "folder.badge.plus")
            }
            .help("Open 3D Model")

            Divider()
                .frame(height: 16)

            Picker("View Mode", selection: $viewModel.viewMode) {
                Text("Wireframe").tag(ViewMode.wireframe)
                Text("Solid").tag(ViewMode.solid)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(height: 32)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

struct SidePanelView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Model Info")
                    .font(.headline)

                Divider()

                if let selection = viewModel.selectedShape {
                    if let summary = viewModel.selectedShapeSummary {
                        Text(summary)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let shapeData = selection.shapeData, shapeData.isCuttable {
                        Button("Generate GCode") {
                            viewModel.generateGCode(for: selection)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Deselect") {
                            viewModel.selectShape(nil)
                        }
                        .buttonStyle(.bordered)
                    }

                    // Matching shapes section
                    if !viewModel.matchingShapes.isEmpty {
                        Divider()

                        Text("\(viewModel.matchingShapes.count) matching stock\(viewModel.matchingShapes.count == 1 ? "" : "s")")
                            .font(.headline)
                            .foregroundColor(Color(red: 0, green: 0.7, blue: 1.0))

                        ForEach(Array(viewModel.matchingShapes.enumerated()), id: \.offset) { idx, shape in
                            if let stock = shape.stockInfo {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Match \(idx + 1)")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(Color(red: 0, green: 0.7, blue: 1.0))
                                    Text(viewModel.stockSummaryText(for: stock))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.primary)
                                }
                                .padding(.vertical, 4)
                                if idx < viewModel.matchingShapes.count - 1 {
                                    Divider().opacity(0.4)
                                }
                            }
                        }
                    }
                } else {
                    Text("Click a shape to inspect it.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if let gcode = viewModel.generatedGCode {
                    Divider()

                    Text("GCode Preview")
                        .font(.headline)

                    TextEditor(text: .constant(gcode))
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 200)
                        .background(Color.black)
                        .cornerRadius(4)
                }
            }
            .padding()
        }
    }
}


// MARK: - View Mode
enum ViewMode: String, CaseIterable, Identifiable {
    case solid = "Solid"
    case wireframe = "Wireframe"
    var id: String { self.rawValue }
}

class AppViewModel: ObservableObject {
    @Published var loadedModel: Model3D?
    @Published var selectedShape: SelectedShape?
    @Published var matchingShapes: [SelectedShape] = []
    @Published var generatedGCode: String?
    @Published var viewMode: ViewMode = .solid
    @Published var packScene: SCNScene?

    var selectedShapeSummary: String? {
        selectedShape?.stockInfo.map { stockSummaryText(for: $0) }
    }

    func stockSummaryText(for stock: StockInfo) -> String {
        var lines: [String] = []
        if stock.profile == .round {
            lines.append("Stock: \(stock.profile.rawValue)")
            lines.append("OD: \(String(format: "%.1f", stock.od ?? 0)) mm")
        } else {
            lines.append("Stock: \(stock.profile.rawValue)")
            lines.append("OD: \(String(format: "%.1f", stock.odX ?? 0)) × \(String(format: "%.1f", stock.odY ?? 0)) mm")
        }
        lines.append("Length: \(String(format: "%.1f", stock.length)) mm")
        if stock.features.isEmpty {
            lines.append("Features: none detected")
        } else {
            lines.append("Features: \(stock.features.count) detected")
            for f in stock.features {
                lines.append("  • \(f.type.rawValue.capitalized)  X=\(String(format: "%.1f", f.xCenter)) mm  A=\(String(format: "%.0f", f.aCenterDeg))°")
            }
        }
        return lines.joined(separator: "\n")
    }

    // Called from the main thread (gesture recognizer callback) — no async dispatch needed.
    func selectShape(_ shape: SelectedShape?) {
        selectedShape = shape
        guard let selected = shape, let stock = selected.stockInfo,
              let all = loadedModel?.selectableShapes else {
            matchingShapes = []
            packScene = nil
            return
        }
        matchingShapes = all.filter { other in
            other != selected && other.stockInfo.map { profileMatches(stock, $0) } == true
        }
        buildPackScene()
    }

    func profileMatches(_ a: StockInfo, _ b: StockInfo) -> Bool {
        guard a.profile == b.profile else { return false }
        let tol: CGFloat = 1.0
        switch a.profile {
        case .round:
            return abs((a.od ?? 0) - (b.od ?? 0)) < tol
        case .square, .rectangular:
            let (aX, aY) = (a.odX ?? 0, a.odY ?? 0)
            let (bX, bY) = (b.odX ?? 0, b.odY ?? 0)
            return (abs(aX - bX) < tol && abs(aY - bY) < tol) ||
                   (abs(aX - bY) < tol && abs(aY - bX) < tol)
        case .unknown:
            return false
        }
    }

    func loadModel(from url: URL) {
        // Start accessing security-scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            print("Failed to access file")
            return
        }
        
        defer {
            url.stopAccessingSecurityScopedResource()
        }
        
        if let model = ModelLoader.loadSTEP(url: url) {
            DispatchQueue.main.async {
                // Reset UI state before loading new model
                self.selectedShape = nil
                self.matchingShapes = []
                self.generatedGCode = nil
                self.packScene = nil
                self.loadedModel = model
            }
        } else {
            print("Failed to load model")
        }
    }
    
    func openFile() {
        NotificationCenter.default.post(name: .openModel, object: nil)
    }
    
    // Update: Generates G-code for the whole pack
    func generatePackGCode() {
        guard let selected = selectedShape else { return }
        let allShapes = [selected] + matchingShapes
        let sorted = allShapes.sorted { ($0.stockInfo?.length ?? 0) > ($1.stockInfo?.length ?? 0) }

        let gap: CGFloat = 10.0
        var packX: CGFloat = 0
        var entries: [PackEntry] = []
        for shape in sorted {
            guard let stock = shape.stockInfo else { continue }
            let len = stock.length
            
            // Calculate the roll offset for each piece in the pack
            let q1 = alignAxisToX(stock.axis)
            var rollDeg: CGFloat = 0
            if stock.profile != .round {
                let rotatedU = q1.act(normalize(stock.uAxis))
                let rollAngle = atan2(rotatedU.z, rotatedU.y)
                rollDeg = CGFloat(-rollAngle * 180.0 / .pi)
            }
            
            entries.append(PackEntry(shape: shape, packStartX: packX, rollOffset: rollDeg))
            packX += len + gap
        }

        let generator = GCodeGenerator()
        generatedGCode = generator.generatePackGCode(entries: entries)
        NotificationCenter.default.post(name: .saveGCode, object: nil)
    }

    // Update: Generates G-code for a selected shape with roll alignment
    func generateGCode(for shape: SelectedShape) {
        let generator = GCodeGenerator()
        
        guard let stockInfo = shape.stockInfo else {
            print("Cannot generate G-code: No stock information available")
            return
        }
        
        // Calculate the roll offset so A=0 aligns with the top of the flat face
        let q1 = alignAxisToX(stockInfo.axis)
        var rollDeg: CGFloat = 0
        if stockInfo.profile != .round {
            let rotatedU = q1.act(normalize(stockInfo.uAxis))
            let rollAngle = atan2(rotatedU.z, rotatedU.y)
            rollDeg = CGFloat(-rollAngle * 180.0 / .pi)
        }
        
        generatedGCode = generator.generateGCode(for: stockInfo, rollOffset: rollDeg)
        NotificationCenter.default.post(name: .saveGCode, object: nil)
    }
    
    // MARK: - Pack View

    private func alignAxisToX(_ axis: SIMD3<Float>) -> simd_quatf {
        let target = SIMD3<Float>(1, 0, 0)
        let a = normalize(axis)
        let d = dot(a, target)
        if d > 0.9999 { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        if d < -0.9999 { return simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)) }
        return simd_quatf(angle: acos(d), axis: normalize(cross(a, target)))
    }

    func buildPackScene() {
        guard let selected = selectedShape, selected.stockInfo != nil else {
            packScene = nil
            return
        }
        let allShapes = [selected] + matchingShapes
        // Sort longest first: minimises inter-piece gaps when pieces come from one stock bar
        let sorted = allShapes.sorted { ($0.stockInfo?.length ?? 0) > ($1.stockInfo?.length ?? 0) }

        let scene = SCNScene()
        let gap: Float = 10.0
        var packX: Float = 0.0
        var maxCross: Float = 20.0

        let ambientNode = SCNNode()
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = NSColor(white: 0.4, alpha: 1.0)
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let dirNode = SCNNode()
        let dir = SCNLight()
        dir.type = .directional
        dirNode.light = dir
        dirNode.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 4, 0)
        scene.rootNode.addChildNode(dirNode)

        for (idx, shape) in sorted.enumerated() {
            guard let stock = shape.stockInfo,
                  let geometry = shape.node?.geometry else { continue }

            let length = Float(stock.length)

            // Step 1: align tube axis to X
            let q1 = alignAxisToX(stock.axis)
            // Step 2: for HSS, roll around X so uAxis maps to +Y — makes all faces co-planar
            // across all pieces (critical for later G-code generation).
            // Round tubes are rotationally symmetric so no roll correction needed.
            let q: simd_quatf
            if stock.profile != .round {
                let rotatedU = q1.act(normalize(stock.uAxis))
                // rotatedU is in YZ plane after q1; find angle from +Y and cancel it
                let rollAngle = atan2(rotatedU.z, rotatedU.y)
                let q2 = simd_quatf(angle: -rollAngle, axis: SIMD3<Float>(1, 0, 0))
                q = q2 * q1
            } else {
                q = q1
            }

            // Transform each vertex: center on tube origin, rotate axis to X, place in row
            // Piece spans [packX … packX+length] along X — no overlap guaranteed.
            let origVerts = extractVertices(from: geometry)
            var newVerts: [SCNVector3] = []
            for v in origVerts {
                let p = SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
                let centered = p - stock.origin
                let rotated = q.act(centered)
                let placed = rotated + SIMD3<Float>(packX + length / 2.0, 0, 0)
                newVerts.append(SCNVector3(CGFloat(placed.x), CGFloat(placed.y), CGFloat(placed.z)))
            }

            let faces = extractFaces(from: geometry)
            let packGeometry = SCNGeometry(vertices: newVerts, faces: faces)
            let mat = SCNMaterial()
            mat.isDoubleSided = true
            mat.diffuse.contents = shape == selected
                ? NSColor.orange
                : NSColor(red: 0.0, green: 0.7, blue: 1.0, alpha: 1.0)
            packGeometry.materials = [mat]

            let node = SCNNode(geometry: packGeometry)
            node.name = "pack_\(idx)"
            scene.rootNode.addChildNode(node)

            let cross = max(Float(stock.odX ?? stock.od ?? 0), Float(stock.odY ?? stock.od ?? 0))
            maxCross = max(maxCross, cross)
            packX += length + gap
        }

        let totalLength = packX > gap ? packX - gap : packX
        let camDist = max(maxCross * 3.0, totalLength * 0.4)
        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.zFar = 100000.0
        cameraNode.camera = camera
        let cx = totalLength / 2.0
        cameraNode.position = SCNVector3(cx, maxCross * 1.5, camDist)
        cameraNode.look(at: SCNVector3(cx, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        packScene = scene
    }

    // Helper functions to extract mesh data from SceneKit geometry
    private func extractVertices(from geometry: SCNGeometry) -> [SCNVector3] {
        guard let vertexSource = geometry.sources.first(where: { $0.semantic == .vertex }) else { return [] }
        
        var vertices: [SCNVector3] = []
        let data = vertexSource.data
        let stride = vertexSource.dataStride
        let componentsPerVertex = vertexSource.componentsPerVector
        
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            
            for i in 0..<vertexSource.vectorCount {
                let offset = i * stride
                let floatPtr = baseAddress.advanced(by: offset).assumingMemoryBound(to: Float.self)
                
                let x = CGFloat(floatPtr[0])
                let y = CGFloat(componentsPerVertex > 1 ? floatPtr[1] : 0)
                let z = CGFloat(componentsPerVertex > 2 ? floatPtr[2] : 0)
                vertices.append(SCNVector3(x, y, z))
            }
        }
        
        return vertices
    }
    
    private func extractFaces(from geometry: SCNGeometry) -> [[Int]] {
        guard let element = geometry.elements.first else { return [] }
        
        var faces: [[Int]] = []
        let indexData = element.data
        let primitiveCount = element.primitiveCount
        
        indexData.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            
            if element.bytesPerIndex == 2 {
                let indices = baseAddress.assumingMemoryBound(to: UInt16.self)
                for i in 0..<primitiveCount {
                    let idx = i * 3
                    faces.append([Int(indices[idx]), Int(indices[idx+1]), Int(indices[idx+2])])
                }
            } else if element.bytesPerIndex == 4 {
                let indices = baseAddress.assumingMemoryBound(to: UInt32.self)
                for i in 0..<primitiveCount {
                    let idx = i * 3
                    faces.append([Int(indices[idx]), Int(indices[idx+1]), Int(indices[idx+2])])
                }
            }
        }
        
        return faces
    }
    
    private func extractNormals(from geometry: SCNGeometry, faceCount: Int) -> [SCNVector3] {
        guard let normalSource = geometry.sources.first(where: { $0.semantic == .normal }) else {
            // Generate dummy normals if not available
            return Array(repeating: SCNVector3(0, 0, 1), count: faceCount)
        }
        
        var normals: [SCNVector3] = []
        let data = normalSource.data
        let stride = normalSource.dataStride
        
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            
            for i in 0..<normalSource.vectorCount {
                let offset = i * stride
                let floatPtr = baseAddress.advanced(by: offset).assumingMemoryBound(to: Float.self)
                
                let x = CGFloat(floatPtr[0])
                let y = CGFloat(floatPtr[1])
                let z = CGFloat(floatPtr[2])
                normals.append(SCNVector3(x, y, z))
            }
        }
        
        return normals
    }
}

// MARK: - Pack View

struct PackView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        if let scene = viewModel.packScene {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 0) {
                    // 3D pack render
                    VStack(spacing: 0) {
                        HStack {
                            Text("Pack View")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            let n = viewModel.matchingShapes.count + 1
                            Text("\(n) piece\(n == 1 ? "" : "s") · longest first")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        PackSceneView(scene: scene)
                            .frame(height: 180)
                    }

                    Divider()

                    // Stock info panel
                    PackInfoView(viewModel: viewModel)
                        .frame(width: 200)
                }
            }
        }
    }
}

struct PackSceneView: NSViewRepresentable {
    let scene: SCNScene

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.backgroundColor = NSColor(white: 0.05, alpha: 1.0)
        scnView.scene = scene
        return scnView
    }

    func updateNSView(_ scnView: SCNView, context: Context) {
        if scnView.scene !== scene {
            scnView.scene = scene
        }
    }
}

struct PackInfoView: View {
    @ObservedObject var viewModel: AppViewModel

    private static let packGap: CGFloat = 10.0  // mm between pieces

    private var sortedShapes: [SelectedShape] {
        guard let s = viewModel.selectedShape else { return [] }
        return ([s] + viewModel.matchingShapes)
            .sorted { ($0.stockInfo?.length ?? 0) > ($1.stockInfo?.length ?? 0) }
    }

    private var totalStockLength: CGFloat {
        let pieceSum = sortedShapes.compactMap { $0.stockInfo?.length }.reduce(0, +)
        let gaps = CGFloat(max(0, sortedShapes.count - 1)) * Self.packGap
        return pieceSum + gaps
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                Text("Stock Required")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                Divider()

                ForEach(Array(sortedShapes.enumerated()), id: \.offset) { idx, shape in
                    if let len = shape.stockInfo?.length {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(shape == viewModel.selectedShape
                                    ? Color.orange
                                    : Color(red: 0, green: 0.7, blue: 1.0))
                                .frame(width: 6, height: 6)
                            Text(String(format: "%.1f mm", len))
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                        }
                        if idx < sortedShapes.count - 1 {
                            Text(String(format: "+%.0f mm gap", Self.packGap))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(.leading, 10)
                        }
                    }
                }

                Divider()

                HStack {
                    Text("Total:")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Spacer()
                    Text(String(format: "%.1f mm", totalStockLength))
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.semibold)
                }

                Divider()

                Button("Generate GCode") {
                    viewModel.generatePackGCode()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
            }
            .padding(8)
        }
    }
}

struct GCodeDocument: FileDocument {
    var content: String
    
    init(gcode: String) {
        self.content = gcode
    }
    
    static var readableContentTypes: [UTType] { [.plainText] }
    
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            content = String(decoding: data, as: UTF8.self)
        } else {
            content = ""
        }
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: Data(content.utf8))
    }
}
