import SwiftUI
import UniformTypeIdentifiers
import SceneKit

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
    @Published var generatedGCode: String?
    @Published var viewMode: ViewMode = .solid

    var selectedShapeSummary: String? {
        guard let stock = selectedShape?.stockInfo else { return nil }
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
                self.generatedGCode = nil
                self.loadedModel = model
            }
        } else {
            print("Failed to load model")
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
    
    /// Generates G-code for a selected shape
    func generateGCode(for shape: SelectedShape) {
        let generator = GCodeGenerator()
        
        guard let stockInfo = shape.stockInfo else {
            print("Cannot generate G-code: No stock information available")
            return
        }
        
        generatedGCode = generator.generateGCode(for: stockInfo)
        
        NotificationCenter.default.post(name: .saveGCode, object: nil)
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
