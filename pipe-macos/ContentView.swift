import SwiftUI
import UniformTypeIdentifiers
import SceneKit
import simd
import AppKit

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
    @ObservedObject private var presetManager = CutPresetManager.shared
    @State private var showingFilePicker = false
    @State private var showingSaveDialog = false
    @State private var showingSettings = false
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 300
    @AppStorage("stockTubeLength") private var stockTubeLength: Double = 6000

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            ToolbarView(viewModel: viewModel, showSettings: $showingSettings)

            Divider()

            // Main content
            HStack(spacing: 0) {
                // 3D View
                Model3DView(viewModel: viewModel)
                    .frame(minWidth: 400)

                ResizableDivider(
                    width: Binding(get: { CGFloat(sidebarWidth) },
                                   set: { sidebarWidth = Double($0) }),
                    minWidth: 200,
                    maxWidth: 600
                )

                // Side panel
                SidePanelView(viewModel: viewModel)
                    .frame(width: CGFloat(sidebarWidth))
            }

            PackView(viewModel: viewModel, sidebarWidth: CGFloat(sidebarWidth))
        }
        .frame(minWidth: 800, minHeight: 500)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            setupNotifications()
            viewModel.stockTubeLength = stockTubeLength
        }
        .onChange(of: viewModel.stockTubeLength) { newVal in
            stockTubeLength = newVal
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
        .onReceive(NotificationCenter.default.publisher(for: .saveGCodePacks)) { _ in
            viewModel.saveGCodePacksAsZip()
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
        .sheet(isPresented: $showingSettings) {
            SettingsView()
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
    @Binding var showSettings: Bool
    @ObservedObject private var presetManager = CutPresetManager.shared

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

            // Active preset indicator
            HStack(spacing: 4) {
                Image(systemName: "flame")
                    .foregroundColor(.orange)
                    .font(.caption)
                if let p = presetManager.activePreset {
                    Text(p.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("·")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Text("\(Int(p.amperage))A")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    Text("No preset selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
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
                                let isHovered = viewModel.hoveredShape == shape
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Match \(idx + 1)")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(isHovered
                                            ? Color(red: 0.1, green: 1.0, blue: 0.2)
                                            : Color(red: 0, green: 0.7, blue: 1.0))
                                    Text(viewModel.stockSummaryText(for: stock))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.primary)
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 4)
                                .background(
                                    isHovered
                                        ? Color(red: 0.1, green: 1.0, blue: 0.2).opacity(0.08)
                                        : Color.clear
                                )
                                .cornerRadius(4)
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    if hovering {
                                        viewModel.hoveredShape = shape
                                    }
                                    // Don't clear on hover-end — highlight persists in 3D view.
                                }
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

// MARK: - Simulation Segment
struct SimSegment {
    let startX: Float   // G-code X at segment start (pack space)
    let startA: Float   // G-code A (degrees) at segment start
    let endX: Float     // G-code X at segment end
    let endA: Float     // G-code A (degrees) at segment end
    let torchOn: Bool   // whether torch fires during this segment
    let isCut: Bool     // true = G1 feed, false = G0 rapid
    let realDuration: Float // real-world seconds for this segment (speed multiplier applied separately)
}

struct ShapeOverride {
    var enabled: Bool = true
    var quantity: Int = 1
}

/// Bundles the SceneKit scene with the camera-fitting metadata computed in buildPackScene.
/// Stored as a single @Published value so scene and dimensions update atomically.
struct PackSceneBundle: Equatable {
    let scene: SCNScene
    let contentLength: Float
    let halfHeight: Float
    /// Maps each shape's UUID to its pack-view SCNNodes (one per quantity copy).
    let shapeNodes: [UUID: [SCNNode]]
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.scene === rhs.scene }
}

class AppViewModel: ObservableObject {
    @Published var loadedModel: Model3D?
    @Published var selectedShape: SelectedShape?
    @Published var matchingShapes: [SelectedShape] = []
    @Published var generatedGCode: String?
    @Published var generatedGCodePacks: [String] = []
    @Published var viewMode: ViewMode = .solid
    @Published var packSceneBundle: PackSceneBundle?
    @Published var shapeOverrides: [UUID: ShapeOverride] = [:]
    @Published var simRunning = false
    @Published var simSpeedMultiplier: Float = 10.0  // 1× = real time, 10× = 10 times faster
    /// Length of a full stock tube in mm. Packs exceeding this are split.
    @Published var stockTubeLength: Double = 6000.0
    /// Number of packs in the current layout, updated by buildPackScene (source of truth).
    @Published var currentPackCount: Int = 1
    /// The matching shape currently highlighted via sidebar hover (persists when moving into 3D view).
    @Published var hoveredShape: SelectedShape?
    private var simTimer: Timer?
    private var simTotalLength: Float = 0
    private var simStockRadius: Float = 30.0
    private var simTorchHeight: Float = 16.0
    /// Angular offset (radians) added to the stock rotation so A=0 in the G-code
    /// corresponds to the uAxis direction facing world +Y (the torch).
    /// Derived from q1 (axis-alignment rotation only) for both round and HSS stock.
    private var simA0Offset: Float = 0
    private var simSegments: [SimSegment] = []
    private var simSegmentIdx: Int = 0
    private var simSegmentElapsed: Float = 0  // seconds into current segment (in real-time units)

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

    func shapeOverride(for shape: SelectedShape) -> ShapeOverride {
        shapeOverrides[shape.id] ?? ShapeOverride()
    }

    func setEnabled(_ enabled: Bool, for shape: SelectedShape) {
        var o = shapeOverride(for: shape)
        o.enabled = enabled
        shapeOverrides[shape.id] = o
        buildPackScene()
    }

    func setQuantity(_ qty: Int, for shape: SelectedShape) {
        var o = shapeOverride(for: shape)
        o.quantity = max(1, qty)
        shapeOverrides[shape.id] = o
        buildPackScene()
    }

    // Called from the main thread (gesture recognizer callback) — no async dispatch needed.
    func selectShape(_ shape: SelectedShape?) {
        selectedShape = shape
        hoveredShape = nil          // new click clears any sidebar hover
        guard let selected = shape, let stock = selected.stockInfo,
              let all = loadedModel?.selectableShapes else {
            matchingShapes = []
            packSceneBundle = nil
            stopSim()
            return
        }
        matchingShapes = all.filter { other in
            other != selected && other.stockInfo.map { profileMatches(stock, $0) } == true
        }
        // Defer so SwiftUI commits selectedShape + matchingShapes in one pass
        // before the pack scene (which depends on both) is built.
        DispatchQueue.main.async { [weak self] in self?.buildPackScene() }
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
                self.packSceneBundle = nil
                self.shapeOverrides = [:]
                self.loadedModel = model
            }
        } else {
            print("Failed to load model")
        }
    }
    
    func openFile() {
        NotificationCenter.default.post(name: .openModel, object: nil)
    }
    
    // Generates G-code for the whole pack, splitting across tubes when needed.
    func generatePackGCode(triggerSave: Bool = true) {
        guard selectedShape != nil else { return }
        let gap: CGFloat = 10.0
        let generator = GCodeGenerator()
        generator.settings = CutPresetManager.shared.currentGCodeSettings()

        let expanded = computeExpandedPieces()
        let groups = splitIntoPacks(expanded, gap: gap)

        // One G-code string per pack.
        generatedGCodePacks = groups.map { group in
            generator.generatePackGCode(entries: makePackEntries(from: group, gap: gap))
        }
        generatedGCode = generatedGCodePacks.first

        // Simulation uses all pieces laid out in one continuous sequence (visual approximation).
        let simEntries = makePackEntries(from: expanded, gap: gap)
        let simCode = generator.generatePackGCode(entries: simEntries)
        simSegments = buildSimSegments(from: simCode)
        resetSim()

        if triggerSave {
            if generatedGCodePacks.count > 1 {
                NotificationCenter.default.post(name: .saveGCodePacks, object: nil)
            } else {
                NotificationCenter.default.post(name: .saveGCode, object: nil)
            }
        }
    }

    /// Saves all generated packs as a ZIP archive chosen via NSSavePanel.
    func saveGCodePacksAsZip() {
        guard generatedGCodePacks.count > 1 else { return }
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gcpacks-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)) != nil else { return }
        for (i, gcode) in generatedGCodePacks.enumerated() {
            try? gcode.write(to: tmpDir.appendingPathComponent("pack_\(i + 1).nc"),
                             atomically: true, encoding: .utf8)
        }
        let panel = NSSavePanel()
        if let zipType = UTType(filenameExtension: "zip") { panel.allowedContentTypes = [zipType] }
        panel.nameFieldStringValue = "gcode_packs.zip"
        panel.title = "Save G-code packs as ZIP"
        panel.begin { [weak self] response in
            guard response == .OK, let destURL = panel.url, let self else {
                try? FileManager.default.removeItem(at: tmpDir); return
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            proc.arguments = ["-j", destURL.path]
                + (0..<self.generatedGCodePacks.count).map { i in
                    tmpDir.appendingPathComponent("pack_\(i + 1).nc").path
                }
            try? proc.run(); proc.waitUntilExit()
            try? FileManager.default.removeItem(at: tmpDir)
        }
    }

    // Update: Generates G-code for a selected shape with roll alignment
    func generateGCode(for shape: SelectedShape) {
        let generator = GCodeGenerator()
        generator.settings = CutPresetManager.shared.currentGCodeSettings()
        
        guard let stockInfo = shape.stockInfo else {
            print("Cannot generate G-code: No stock information available")
            return
        }
        
        generatedGCode = generator.generateGCode(for: stockInfo)
        NotificationCenter.default.post(name: .saveGCode, object: nil)
    }
    
    // MARK: - Pack View

    /// A single expanded piece (after applying quantity) ready for bin-packing.
    private struct ExpandedPiece {
        let shape: SelectedShape
        var length: CGFloat { shape.stockInfo?.length ?? 0 }
    }

    /// Expands all enabled shapes with their quantities into a flat list,
    /// sorted by ascending length (shortest first).
    private func computeExpandedPieces() -> [ExpandedPiece] {
        guard let selected = selectedShape else { return [] }
        let allShapes = [selected] + matchingShapes
        let sorted = allShapes.sorted { ($0.stockInfo?.length ?? 0) < ($1.stockInfo?.length ?? 0) }
        var pieces: [ExpandedPiece] = []
        for shape in sorted {
            let ov = shapeOverride(for: shape)
            guard ov.enabled, shape.stockInfo != nil else { continue }
            for _ in 0..<max(1, ov.quantity) {
                pieces.append(ExpandedPiece(shape: shape))
            }
        }
        return pieces
    }

    /// Groups pieces into packs where each pack fits within stockTubeLength.
    /// Uses First Fit Decreasing to minimise waste.
    /// Each returned sub-array is sorted ascending by length (shortest-first = leftmost).
    private func splitIntoPacks(_ pieces: [ExpandedPiece], gap: CGFloat) -> [[ExpandedPiece]] {
        let limit = CGFloat(stockTubeLength)
        // If no meaningful limit, one big pack.
        guard limit > 0 else { return [pieces] }

        // FFD: place longest pieces first.
        let sorted = pieces.sorted { $0.length > $1.length }

        var packs: [[ExpandedPiece]] = []
        var used: [CGFloat] = []

        for piece in sorted {
            var placed = false
            for i in 0..<packs.count {
                let addLen = used[i] == 0 ? piece.length : used[i] + gap + piece.length
                if addLen <= limit {
                    packs[i].append(piece)
                    used[i] = addLen
                    placed = true
                    break
                }
            }
            if !placed {
                // Start a new pack (even if piece itself > limit — never drop a piece).
                packs.append([piece])
                used.append(piece.length)
            }
        }

        // Re-sort each pack ascending by length for the cutting/scene order.
        return packs.map { $0.sorted { $0.length < $1.length } }
    }

    /// Converts an ordered list of pieces in one pack into PackEntry objects
    /// with sequential packStartX positions.
    private func makePackEntries(from pieces: [ExpandedPiece], gap: CGFloat, startX: CGFloat = 0) -> [PackEntry] {
        var x = startX
        return pieces.map { piece in
            let entry = PackEntry(shape: piece.shape, packStartX: x)
            x += piece.length + gap
            return entry
        }
    }

    private func alignAxisToX(_ axis: SIMD3<Float>) -> simd_quatf {
        let target = SIMD3<Float>(1, 0, 0)
        let a = normalize(axis)
        let d = dot(a, target)
        if d > 0.9999 { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        if d < -0.9999 { return simd_quatf(angle: .pi, axis: SIMD3<Float>(0, 1, 0)) }
        return simd_quatf(angle: acos(d), axis: normalize(cross(a, target)))
    }

    func buildPackScene() {
        stopSim()
        simSegments = []
        simSegmentIdx = 0
        simSegmentElapsed = 0
        guard let selected = selectedShape, selected.stockInfo != nil else {
            packSceneBundle = nil
            return
        }

        let scene = SCNScene()
        let gap: Float = 10.0
        var packX: Float = 0.0
        var maxCross: Float = 20.0

        // Pre-compute maxCross so dividers are sized correctly.
        let allShapes = [selected] + matchingShapes
        for shape in allShapes {
            if let s = shape.stockInfo {
                let cx = Float(s.odX ?? s.od ?? 0)
                let cy = Float(s.odY ?? s.od ?? 0)
                maxCross = max(maxCross, max(cx, cy))
            }
        }

        let ambientNode = SCNNode()
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = NSColor(white: 0.4, alpha: 1.0)
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let dirNode = SCNNode()
        let dirLight = SCNLight()
        dirLight.type = .directional
        dirNode.light = dirLight
        dirNode.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 4, 0)
        scene.rootNode.addChildNode(dirNode)

        // All piece geometry goes into stockGroup so it can translate/rotate as one unit
        let stockGroup = SCNNode()
        stockGroup.name = "stockGroup"
        scene.rootNode.addChildNode(stockGroup)

        // Split pieces into packs and render each pack, separated by a visual divider.
        let expanded = computeExpandedPieces()
        let packGroups = splitIntoPacks(expanded, gap: CGFloat(gap))
        currentPackCount = packGroups.count
        let packDividerGap: Float = 60.0   // extra space between packs in scene
        var nodeIdx = 0
        var shapeNodes: [UUID: [SCNNode]] = [:]

        /// Renders one piece at the current packX and advances packX.
        func addPieceNode(_ piece: ExpandedPiece) {
            guard let stock = piece.shape.stockInfo,
                  let geometry = piece.shape.node?.geometry else { return }
            let length = Float(stock.length)
            let q1 = alignAxisToX(stock.axis)
            let q: simd_quatf
            if stock.profile != .round {
                let rotatedU = q1.act(normalize(stock.uAxis))
                let q2 = simd_quatf(angle: -atan2(rotatedU.z, rotatedU.y), axis: SIMD3<Float>(1, 0, 0))
                q = q2 * q1
            } else {
                q = q1
            }
            let origVerts = extractVertices(from: geometry)
            let faces = extractFaces(from: geometry)
            var newVerts: [SCNVector3] = []
            for v in origVerts {
                let p = SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
                let centered = p - stock.origin
                let rotated = q.act(centered)
                let placed = rotated + SIMD3<Float>(packX + length / 2.0, 0, 0)
                newVerts.append(SCNVector3(CGFloat(placed.x), CGFloat(placed.y), CGFloat(placed.z)))
            }
            let packGeometry = SCNGeometry(vertices: newVerts, faces: faces)
            let mat = SCNMaterial()
            mat.isDoubleSided = true
            mat.diffuse.contents = (piece.shape == selected)
                ? NSColor.orange
                : NSColor(red: 0.0, green: 0.7, blue: 1.0, alpha: 1.0)
            packGeometry.materials = [mat]
            let node = SCNNode(geometry: packGeometry)
            node.name = "pack_\(nodeIdx)"; nodeIdx += 1
            shapeNodes[piece.shape.id, default: []].append(node)
            stockGroup.addChildNode(node)
            packX += length + gap
        }

        for (groupIdx, group) in packGroups.enumerated() {
            // Yellow divider panel between packs
            if groupIdx > 0 {
                let divH = CGFloat(maxCross * 2.8)
                let divBox = SCNBox(width: 4, height: divH, length: divH, chamferRadius: 0)
                let divMat = SCNMaterial()
                divMat.diffuse.contents = NSColor(red: 1.0, green: 0.78, blue: 0.0, alpha: 0.85)
                divMat.isDoubleSided = true
                divBox.materials = [divMat]
                let divNode = SCNNode(geometry: divBox)
                divNode.name = "packDiv_\(groupIdx)"
                divNode.position = SCNVector3(CGFloat(packX + packDividerGap / 2 - gap / 2), 0, 0)
                stockGroup.addChildNode(divNode)
                packX += packDividerGap
            }
            for piece in group {
                addPieceNode(piece)
            }
        }

        let totalLength = packX > gap ? packX - gap : packX
        simTotalLength  = totalLength
        simStockRadius  = maxCross / 2.0
        simTorchHeight  = maxCross * 0.3  // scale torch size with stock

        // Compute angular offset so G-code A=0 maps to uAxis facing world +Y (toward torch).
        // For round stock only q1 is baked into the geometry, so we need simA0Offset to
        // bring uAxis to +Y at gcodeA=0.
        // For HSS-Rect/Square, addPieceNode bakes q2*q1 which already places uAxis at +Y,
        // so simA0Offset must be 0 — otherwise applySimState would double-rotate.
        if let refStock = expanded.first?.shape.stockInfo,
           refStock.profile == .round,
           simd_length(refStock.uAxis) > 0.001 {
            let q1_ref = alignAxisToX(refStock.axis)
            let rotatedU = q1_ref.act(normalize(refStock.uAxis))
            simA0Offset = -atan2(rotatedU.z, rotatedU.y)
        } else {
            simA0Offset = 0
        }

        // Torch cone: tip (bottomRadius=0) points toward tube, fat end away.
        // Position/orientation are set dynamically by applySimState — just create the node here.
        let torchCone = SCNCone(topRadius: CGFloat(maxCross * 0.08), bottomRadius: 0, height: CGFloat(simTorchHeight))
        let torchMat = SCNMaterial()
        torchMat.diffuse.contents  = NSColor(red: 1.0, green: 0.75, blue: 0.1, alpha: 1.0)
        torchMat.emission.contents = NSColor.black
        torchMat.isDoubleSided = true
        torchCone.materials = [torchMat]
        let torchNode = SCNNode(geometry: torchCone)
        torchNode.name = "torch"
        scene.rootNode.addChildNode(torchNode)

        // Camera: orthographic so the stock fills the fixed-height pack view regardless of
        // pack length. orthographicScale = half the world-unit height we want visible.
        // We show: stock cross-section + torch standoff + torch body + 15% margin.
        let visibleHalfHeight = (maxCross / 2.0 + simTorchHeight * 1.6) * 1.15
        let cameraNode = SCNNode()
        cameraNode.name = "packCamera"
        let camera = SCNCamera()
        camera.zFar = 100000.0
        camera.zNear = 1.0
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(visibleHalfHeight)
        cameraNode.camera = camera
        let cx = totalLength / 2.0
        // Position straight ahead on Z; Y centred on the torch (slightly above tube axis).
        let torchCentreY = maxCross / 2.0 + simTorchHeight / 2.0
        cameraNode.position = SCNVector3(cx, torchCentreY * 0.4, 2000)
        cameraNode.look(at: SCNVector3(cx, torchCentreY * 0.4, 0))
        scene.rootNode.addChildNode(cameraNode)

        // Bundle scene with its camera-fitting metadata so they update atomically.
        packSceneBundle = PackSceneBundle(scene: scene, contentLength: totalLength,
                                          halfHeight: visibleHalfHeight, shapeNodes: shapeNodes)
        // Position the torch at the initial "parked" state (free end, retracted)
        applySimState(gcodeX: simTotalLength, gcodeA: 0, torchOn: false)
    }

    // MARK: - Simulation

    func resetSim() {
        stopSim()
        simSegmentIdx = 0
        simSegmentElapsed = 0
        // Show torch at the free (right) end of stock — where cutting starts
        applySimState(gcodeX: simTotalLength, gcodeA: 0, torchOn: false)
    }

    func toggleSim() {
        if simRunning { stopSim() } else { startSim() }
    }

    private func startSim() {
        // Auto-generate G-code (and segments) if not yet done
        if simSegments.isEmpty { generatePackGCode(triggerSave: false) }
        guard !simSegments.isEmpty else { return }
        simRunning = true
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.stepSim()
        }
        RunLoop.main.add(timer, forMode: .common)
        simTimer = timer
    }

    private func stopSim() {
        simRunning = false
        simTimer?.invalidate()
        simTimer = nil
    }

    private func stepSim() {
        let dt: Float = 1.0 / 60.0
        // Advance elapsed time in real-world seconds × speed multiplier
        simSegmentElapsed += dt * simSpeedMultiplier
        while simSegmentIdx < simSegments.count {
            let seg = simSegments[simSegmentIdx]
            if simSegmentElapsed <= seg.realDuration {
                let t = simSegmentElapsed / seg.realDuration
                let x = seg.startX + t * (seg.endX - seg.startX)
                let a = seg.startA + t * (seg.endA - seg.startA)
                applySimState(gcodeX: x, gcodeA: a, torchOn: seg.torchOn)
                return
            }
            simSegmentElapsed -= seg.realDuration
            simSegmentIdx += 1
        }
        // All segments done
        if let last = simSegments.last {
            applySimState(gcodeX: last.endX, gcodeA: last.endA, torchOn: false)
        }
        stopSim()
    }

    private func applySimState(gcodeX: Float, gcodeA: Float, torchOn: Bool) {
        guard let scene = packSceneBundle?.scene,
              let stockGroup = scene.rootNode.childNode(withName: "stockGroup", recursively: false) else { return }

        // Stock moves axially so the cut point (gcodeX in pack space) lines up with the
        // fixed torch position (simTotalLength in scene space).
        stockGroup.position = SCNVector3(simTotalLength - gcodeX, 0, 0)
        // Stock rotates so the cut surface faces the torch.
        stockGroup.eulerAngles = SCNVector3(-gcodeA * Float.pi / 180.0 + simA0Offset, 0, 0)

        // Torch is fixed in scene space — stationary at X=simTotalLength, directly above the
        // tube axis. Only Y changes to show retracted (safe height) vs descending to cut.
        if let torchNode = scene.rootNode.childNode(withName: "torch", recursively: false) {
            let settings = GCodeSettings()
            let standoff: Float = torchOn ? Float(settings.cutHeight) : Float(settings.safeHeight)
            // Tip is at (simStockRadius + standoff) above tube axis; cone centre is half-height further
            let centreY = simStockRadius + standoff + simTorchHeight / 2.0
            torchNode.position = SCNVector3(CGFloat(simTotalLength), CGFloat(centreY), 0)
            // Cone always points straight down — eulerAngles stay at zero
            torchNode.eulerAngles = SCNVector3(0, 0, 0)
            torchNode.geometry?.firstMaterial?.emission.contents = torchOn
                ? NSColor(red: 1.0, green: 0.4, blue: 0.0, alpha: 1.0)
                : NSColor.black
        }
    }

    // MARK: - G-code to Simulation Segments

    private func buildSimSegments(from gcode: String) -> [SimSegment] {
        let rapidFeed: Float = 3000.0      // mm/min for G0 rapids
        let effRadius: Float = max(simStockRadius, 20.0)  // for arc-distance timing estimate

        var segments: [SimSegment] = []
        var curX: Float = 0, curA: Float = 0, curZ: Float = 0
        var curFeed: Float = 1000
        var torchOn = false

        for rawLine in gcode.components(separatedBy: "\n") {
            let commentStripped = rawLine.components(separatedBy: ";")[0]
            let line = commentStripped.trimmingCharacters(in: .whitespaces).uppercased()
            guard !line.isEmpty else { continue }

            if line.hasPrefix("M3") { torchOn = true;  continue }
            if line.hasPrefix("M5") { torchOn = false; continue }

            // G92 resets the tracked coordinates without creating a segment
            if line.hasPrefix("G92") {
                for tok in line.components(separatedBy: " ") {
                    if tok.hasPrefix("X"), let v = Float(tok.dropFirst()) { curX = v }
                    if tok.hasPrefix("A"), let v = Float(tok.dropFirst()) { curA = v }
                    if tok.hasPrefix("Z"), let v = Float(tok.dropFirst()) { curZ = v }
                }
                continue
            }

            let isG0 = line.hasPrefix("G0 ") || line.hasPrefix("G00 ")
            let isG1 = line.hasPrefix("G1 ") || line.hasPrefix("G01 ")
            guard isG0 || isG1 else { continue }

            var newX = curX, newA = curA, newZ = curZ
            for tok in line.components(separatedBy: " ") {
                if tok.hasPrefix("X"), let v = Float(tok.dropFirst()) { newX = v }
                if tok.hasPrefix("A"), let v = Float(tok.dropFirst()) { newA = v }
                if tok.hasPrefix("Z"), let v = Float(tok.dropFirst()) { newZ = v }
                if tok.hasPrefix("F"), let v = Float(tok.dropFirst()) { curFeed = v }
            }

            let effectiveFeed = isG0 ? rapidFeed : curFeed
            let dx = newX - curX
            let da_mm = (newA - curA) * Float.pi / 180.0 * effRadius
            let dz = newZ - curZ
            let dist = sqrt(dx * dx + da_mm * da_mm + dz * dz)
            let realSec = max(dist / max(effectiveFeed / 60.0, 0.001), 0.0001)

            segments.append(SimSegment(
                startX: curX, startA: curA,
                endX: newX, endA: newA,
                torchOn: torchOn, isCut: isG1,
                realDuration: realSec
            ))
            curX = newX; curA = newA; curZ = newZ
        }
        return segments
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

// MARK: - Resizable Divider

struct ResizableDivider: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    @State private var dragStartWidth: CGFloat? = nil

    var body: some View {
        Rectangle()
            .fill(Color(NSColor.separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay(
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.resizeLeftRight.push() }
                        else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if dragStartWidth == nil { dragStartWidth = width }
                                let proposed = (dragStartWidth ?? width) - value.translation.width
                                width = max(minWidth, min(maxWidth, proposed))
                            }
                            .onEnded { _ in dragStartWidth = nil }
                    )
            )
    }
}

struct PackView: View {
    @ObservedObject var viewModel: AppViewModel
    var sidebarWidth: CGFloat

    var body: some View {
        if let bundle = viewModel.packSceneBundle {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 0) {
                    // Left: 3D pack render + sim controls
                    VStack(spacing: 0) {
                        HStack {
                            Text("Pack View")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            let allShapes = viewModel.selectedShape.map { [$0] + viewModel.matchingShapes } ?? []
                            let n = allShapes.reduce(0) { acc, s in
                                let ov = viewModel.shapeOverride(for: s)
                                return acc + (ov.enabled ? max(1, ov.quantity) : 0)
                            }
                            Text("← longest on right (\(n) piece\(n == 1 ? "" : "s"))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)

                        PackSceneView(bundle: bundle, hoveredShape: viewModel.hoveredShape)
                            .frame(height: 180)

                        // Simulation controls
                        HStack(spacing: 8) {
                            Button("⏮ Reset") {
                                viewModel.resetSim()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button(viewModel.simRunning ? "⏹ Stop" : "▶ Start") {
                                viewModel.toggleSim()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Divider().frame(height: 16)

                            Text("Speed: \(Int(viewModel.simSpeedMultiplier))×")
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 70, alignment: .leading)

                            Slider(value: $viewModel.simSpeedMultiplier, in: 1...100, step: 1)
                                .frame(width: 120)
                                .controlSize(.small)

                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }

                    Divider()

                    // Right: stock info + generate button
                    PackInfoView(viewModel: viewModel)
                        .frame(width: sidebarWidth)
                }
            }
        }
    }
}

struct PackSceneView: NSViewRepresentable {
    let bundle: PackSceneBundle
    let hoveredShape: SelectedShape?

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var lastBundle: PackSceneBundle?
        var lastHoveredID: UUID?
    }

    func makeNSView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.backgroundColor = NSColor(white: 0.05, alpha: 1.0)
        scnView.scene = bundle.scene
        return scnView
    }

    func updateNSView(_ scnView: SCNView, context: Context) {
        let c = context.coordinator
        if c.lastBundle != bundle {
            c.lastBundle = bundle
            scnView.scene = bundle.scene
            DispatchQueue.main.async { self.refitCamera(in: scnView) }
        }
        let newHoveredID = hoveredShape?.id
        if c.lastHoveredID != newHoveredID {
            c.lastHoveredID = newHoveredID
            applyHover()
        }
    }

    private func applyHover() {
        // Clear emission on all pack nodes, then set lime-green on the hovered shape's nodes.
        for nodes in bundle.shapeNodes.values {
            for node in nodes {
                node.geometry?.firstMaterial?.emission.contents = NSColor.clear
            }
        }
        if let id = hoveredShape?.id, let nodes = bundle.shapeNodes[id] {
            let limeGreen = NSColor(red: 0.1, green: 1.0, blue: 0.2, alpha: 1.0)
            for node in nodes { node.geometry?.firstMaterial?.emission.contents = limeGreen }
        }
    }

    private func refitCamera(in scnView: SCNView) {
        guard let cameraNode = scnView.pointOfView,
              let camera = cameraNode.camera else { return }
        let viewW = Float(scnView.bounds.width)
        let viewH = Float(scnView.bounds.height)
        guard viewH > 0 else { return }
        let scaleForHeight = bundle.halfHeight
        let scaleForWidth = viewW > 0 ? (bundle.contentLength / 2.0) / (viewW / viewH) : scaleForHeight
        let scale = max(scaleForHeight, scaleForWidth) * 1.05
        camera.orthographicScale = Double(scale)
        let cx = bundle.contentLength / 2.0
        let currentY = Float(cameraNode.position.y)
        cameraNode.position = SCNVector3(cx, currentY, Float(cameraNode.position.z))
        cameraNode.look(at: SCNVector3(cx, currentY, 0))
    }
}

// MARK: - Stock Profile Orientation View

/// Shows a cross-section of HSS-Rect/Square stock, indicating which face should face UP
/// toward the torch. The `uAxis` face is always at the top after roll-offset alignment.
struct StockProfileView: View {
    let stockInfo: StockInfo

    /// Face-to-face distance in the uAxis (vertical / toward torch) direction.
    private var uDim: CGFloat {
        stockInfo.uAxisDimension ?? (stockInfo.odY ?? stockInfo.od ?? 50)
    }

    /// Face-to-face distance in the vAxis (horizontal) direction.
    private var vDim: CGFloat {
        let x = stockInfo.odX ?? stockInfo.od ?? 50
        let y = stockInfo.odY ?? stockInfo.od ?? 50
        return (x + y) - uDim
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Cutting Orientation")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            HStack(alignment: .center, spacing: 8) {
                profileCanvas
                    .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                        Text("torch side")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                    }
                    Text(String(format: "W  %.0f mm", vDim))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text(String(format: "H  %.0f mm", uDim))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Divider()
        }
    }

    private var profileCanvas: some View {
        Canvas { ctx, size in
            let padX: CGFloat = 4
            let padTop: CGFloat = 16  // space for up-arrow
            let padBot: CGFloat = 4

            let availW = size.width - padX * 2
            let availH = size.height - padTop - padBot

            let scale = min(availW / vDim, availH / uDim)
            let rW = vDim * scale
            let rH = uDim * scale
            let rX = (size.width - rW) / 2
            let rY = padTop + (availH - rH) / 2

            let cornerR = min(rW, rH) * 0.1
            let rect = CGRect(x: rX, y: rY, width: rW, height: rH)

            // Fill
            ctx.fill(Path(roundedRect: rect, cornerRadius: cornerR),
                     with: .color(Color(white: 0.22)))

            // Outline
            ctx.stroke(Path(roundedRect: rect, cornerRadius: cornerR),
                       with: .color(Color(white: 0.45)), lineWidth: 1)

            // Yellow highlight on top face (uAxis / torch face)
            let topEdge = Path { p in
                p.move(to: CGPoint(x: rX + cornerR, y: rY))
                p.addLine(to: CGPoint(x: rX + rW - cornerR, y: rY))
            }
            ctx.stroke(topEdge, with: .color(.yellow), lineWidth: 2.5)

            // Arrow pointing up from the top face centre
            let ax = size.width / 2
            let arrowBase = CGPoint(x: ax, y: rY - 3)
            let arrowTip  = CGPoint(x: ax, y: 5)
            var arrow = Path()
            arrow.move(to: arrowBase)
            arrow.addLine(to: arrowTip)
            arrow.move(to: arrowTip)
            arrow.addLine(to: CGPoint(x: ax - 4, y: arrowTip.y + 6))
            arrow.move(to: arrowTip)
            arrow.addLine(to: CGPoint(x: ax + 4, y: arrowTip.y + 6))
            ctx.stroke(arrow, with: .color(.yellow), lineWidth: 1.5)
        }
    }
}

struct PackInfoView: View {
    @ObservedObject var viewModel: AppViewModel

    private static let packGap: CGFloat = 10.0  // mm between pieces

    @State private var stockLengthText: String = ""

    private var sortedShapes: [SelectedShape] {
        guard let s = viewModel.selectedShape else { return [] }
        return ([s] + viewModel.matchingShapes)
            .sorted { ($0.stockInfo?.length ?? 0) < ($1.stockInfo?.length ?? 0) }
    }

    private var totalStockLength: CGFloat {
        var total: CGFloat = 0
        var count = 0
        for shape in sortedShapes {
            let ov = viewModel.shapeOverride(for: shape)
            guard ov.enabled, let len = shape.stockInfo?.length else { continue }
            let qty = max(1, ov.quantity)
            total += len * CGFloat(qty)
            count += qty
        }
        let gaps = CGFloat(max(0, count - 1)) * Self.packGap
        return total + gaps
    }

    private var packCount: Int { viewModel.currentPackCount }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                if let stockInfo = sortedShapes.first?.stockInfo,
                   stockInfo.profile == .rectangular || stockInfo.profile == .square {
                    StockProfileView(stockInfo: stockInfo)
                }

                Text("Stock Required")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                // Stock tube length input
                HStack(spacing: 4) {
                    Text("Tube length:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("mm", text: $stockLengthText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 70)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .onAppear {
                            stockLengthText = String(format: "%.0f", viewModel.stockTubeLength)
                        }
                        .onChange(of: viewModel.stockTubeLength) { v in
                            stockLengthText = String(format: "%.0f", v)
                        }
                        .onSubmit { commitStockLength() }
                    Text("mm")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                ForEach(sortedShapes) { shape in
                    if let len = shape.stockInfo?.length {
                        let ov = viewModel.shapeOverride(for: shape)
                        let enabledBinding = Binding<Bool>(
                            get: { viewModel.shapeOverride(for: shape).enabled },
                            set: { viewModel.setEnabled($0, for: shape) }
                        )
                        let qtyBinding = Binding<Int>(
                            get: { viewModel.shapeOverride(for: shape).quantity },
                            set: { viewModel.setQuantity($0, for: shape) }
                        )

                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Toggle("", isOn: enabledBinding)
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                    .controlSize(.mini)
                                Circle()
                                    .fill(shape == viewModel.selectedShape
                                        ? Color.orange
                                        : Color(red: 0, green: 0.7, blue: 1.0))
                                    .frame(width: 6, height: 6)
                                Text(String(format: "%.1f mm", len))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(ov.enabled ? .primary : .secondary)
                                    .strikethrough(!ov.enabled)
                                Spacer()
                                Text("\(ov.quantity)×")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(ov.enabled ? .primary : .secondary)
                                    .frame(width: 20, alignment: .trailing)
                                Stepper("", value: qtyBinding, in: 1...99)
                                    .labelsHidden()
                                    .controlSize(.mini)
                                    .disabled(!ov.enabled)
                            }
                            if ov.enabled && ov.quantity > 1 {
                                Text(String(format: "×%d = %.1f mm", ov.quantity, len * CGFloat(ov.quantity)))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 20)
                            }
                        }
                        .padding(.vertical, 1)
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

                // Pack count warning
                if packCount > 1 {
                    HStack(spacing: 4) {
                        Image(systemName: "shippingbox.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                        Text("\(packCount) tubes required")
                            .font(.caption)
                            .foregroundColor(.yellow)
                    }
                    .padding(.top, 2)
                }

                Divider()

                Button(packCount > 1 ? "Generate GCode (\(packCount) files → ZIP)" : "Generate GCode") {
                    viewModel.generatePackGCode()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
            }
            .padding(8)
        }
    }

    private func commitStockLength() {
        if let v = Double(stockLengthText.trimmingCharacters(in: .whitespaces)), v > 0 {
            viewModel.stockTubeLength = v
            viewModel.buildPackScene()
        } else {
            // Reset to current value on bad input
            stockLengthText = String(format: "%.0f", viewModel.stockTubeLength)
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
