import SwiftUI
import UniformTypeIdentifiers
import SceneKit

// MARK: - UTType Extensions
extension UTType {
    static var stl: UTType {
        UTType(filenameExtension: "stl", conformingTo: .data) ?? .data
    }
    
    static var obj: UTType {
        UTType(filenameExtension: "obj", conformingTo: .data) ?? .data
    }
    
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
        }
        .frame(minWidth: 800, minHeight: 500)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            setupNotifications()
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.stl, .obj, .step, .stp, .folder],
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
                Text("Shaded").tag(ViewMode.shaded)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            Spacer()

            Toggle("Selection Mode", isOn: $viewModel.selectionMode)
                .toggleStyle(.switch)
                .help("Enable sub-shape selection")
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
                
                if let model = viewModel.loadedModel {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name: \(model.name)")
                        Text("Vertices: \(model.vertexCount)")
                        Text("Faces: \(model.faceCount)")
                        
                        if let stock = model.stockInfo {
                            Divider()
                            Text("Stock Classification")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            
                            Text("Profile: \(stock.profile.rawValue.uppercased())")
                            
                            if let od = stock.od {
                                Text("OD: \(String(format: "%.1f", od)) mm")
                            } else if let odX = stock.odX, let odY = stock.odY {
                                Text("Dimensions: \(String(format: "%.1f", odX)) × \(String(format: "%.1f", odY)) mm")
                            }
                            
                            Text("Length: \(String(format: "%.1f", stock.length)) mm")
                            
                            if let startCut = stock.startEndCut {
                                Text("Start: \(startCut.type.rawValue)")
                                if startCut.type == .miter {
                                    Text("  Angle: \(String(format: "%.1f", startCut.miterAngleDeg))°")
                                        .font(.caption2)
                                }
                            }
                            
                            if let endCut = stock.endEndCut {
                                Text("End: \(endCut.type.rawValue)")
                                if endCut.type == .miter {
                                    Text("  Angle: \(String(format: "%.1f", endCut.miterAngleDeg))°")
                                        .font(.caption2)
                                }
                            }
                            
                            if !stock.features.isEmpty {
                                Divider()
                                Text("Detected Features: \(stock.features.count)")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                
                                ForEach(stock.features, id: \.id) { feature in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("  • \(feature.type.rawValue.capitalized) (\(feature.shape.rawValue))")
                                            .font(.caption)
                                        if let diameter = feature.dimensions["diameter"] {
                                            Text("    Ø\(String(format: "%.1f", diameter)) mm")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        } else if let width = feature.dimensions["width"], let height = feature.dimensions["height"] {
                                            Text("    \(String(format: "%.1f", width)) × \(String(format: "%.1f", height)) mm")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        Text("    X=\(String(format: "%.1f", feature.xCenter)) A=\(String(format: "%.0f", feature.aCenterDeg))°")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .font(.caption)
                } else {
                    Text("No model loaded")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                Text("Selected Shape")
                    .font(.headline)
                
                if let selection = viewModel.selectedShape {
                    VStack(alignment: .leading, spacing: 8) {
                        ShapeInfoView(shape: selection)
                        
                        if selection.isCuttable {
                            Button("Generate GCode (Selected Shape)") {
                                viewModel.generateGCode(for: selection)
                            }
                            .buttonStyle(.borderedProminent)
                            
                            Button("Deselect") {
                                viewModel.selectShape(nil)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .font(.caption)
                } else {
                    Text("No shape selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Always show full stock button if stock info available
                if let model = viewModel.loadedModel, let stock = model.stockInfo {
                    Divider()
                    
                    Button("Generate GCode for Full Stock") {
                        let selectedShape = SelectedShape(
                            shapeType: stock.profile.rawValue,
                            dimensions: nil,
                            isCuttable: true,
                            node: nil
                        )
                        viewModel.generateGCode(for: selectedShape)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Uses stock classification with feature detection")
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

struct ShapeInfoView: View {
    let shape: SelectedShape

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Type: \(shape.shapeType)")
            
            dimensionText
            
            Text("Cuttable: \(shape.isCuttable ? "Yes" : "No")")
                .foregroundColor(shape.isCuttable ? .green : .red)
        }
    }
    
    @ViewBuilder
    private var dimensionText: some View {
        switch shape.shapeType {
        case "cylinder":
            if let dims = shape.dimensions as? CylinderDimensions {
                Text("Diameter: \(String(format: "%.2f", dims.diameter)) mm")
                Text("Height: \(String(format: "%.2f", dims.height)) mm")
            }
        case "box":
            if let dims = shape.dimensions as? BoxDimensions {
                Text("Width: \(String(format: "%.2f", dims.width)) mm")
                Text("Height: \(String(format: "%.2f", dims.height)) mm")
                Text("Depth: \(String(format: "%.2f", dims.depth)) mm")
            }
        default:
            EmptyView()
        }
    }
}

enum ViewMode: String, CaseIterable {
    case wireframe = "Wireframe"
    case solid = "Solid"
    case shaded = "Shaded"
}

class AppViewModel: ObservableObject {
    @Published var loadedModel: Model3D?
    @Published var selectedShape: SelectedShape?
    @Published var generatedGCode: String?
    @Published var viewMode: ViewMode = .solid
    @Published var selectionMode: Bool = false
    
    func loadModel(from url: URL) {
        // Start accessing security-scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            print("Failed to access file")
            return
        }
        
        defer {
            url.stopAccessingSecurityScopedResource()
        }
        
        do {
            let model = try ModelLoader.load(url: url)
            DispatchQueue.main.async {
                self.loadedModel = model
            }
        } catch {
            print("Failed to load model: \(error)")
        }
    }
    
    func openFile() {
        NotificationCenter.default.post(name: .openModel, object: nil)
    }
    
    func selectShape(_ shape: SelectedShape?) {
        DispatchQueue.main.async {
            self.selectedShape = shape
        }
    }
    
    func generateGCode(for shape: SelectedShape) {
        let generator = GCodeGenerator()
        
        let stockInfo: StockInfo?
        if let node = shape.node, let geometry = node.geometry {
            // Selected mesh: run stock classification on this specific mesh
            print("=== Extracting mesh data for classification ===")
            let vertices = extractVertices(from: geometry)
            let faces = extractFaces(from: geometry)
            let normals = extractNormals(from: geometry, faceCount: faces.count)
            
            print("  Extracted \(vertices.count) vertices, \(faces.count) faces, \(normals.count) normals")
            
            // Run classification on selected mesh only
            stockInfo = ModelLoader.classifyStock(vertices: vertices, faces: faces, normals: normals)
            
            if let stock = stockInfo {
                print("  Classification SUCCESS:")
                print("    Profile: \(stock.profile.rawValue)")
                print("    OD: \(stock.od ?? -1)")
                print("    Dimensions: \(stock.odX ?? -1) × \(stock.odY ?? -1)")
                print("    Length: \(stock.length)")
                print("    Start end cut: \(stock.startEndCut?.type.rawValue ?? "none")")
                print("    End end cut: \(stock.endEndCut?.type.rawValue ?? "none")")
                print("    Features: \(stock.features.count)")
            } else {
                print("  Classification FAILED - returned nil")
            }
        } else {
            // No specific node = use full model stock info
            print("=== Using full model stock info ===")
            stockInfo = loadedModel?.stockInfo
        }
        
        let gcode = generator.generate(for: shape, stockInfo: stockInfo)
        DispatchQueue.main.async {
            self.generatedGCode = gcode
        }
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
