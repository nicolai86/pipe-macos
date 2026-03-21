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

class AppViewModel: ObservableObject {
    @Published var loadedModel: Model3D?
    @Published var selectedShape: SelectedShape?
    @Published var matchingShapes: [SelectedShape] = []
    @Published var generatedGCode: String?
    @Published var viewMode: ViewMode = .solid
    @Published var packScene: SCNScene?
    @Published var simRunning = false
    @Published var simSpeedMultiplier: Float = 10.0  // 1× = real time, 10× = 10 times faster
    private var simTimer: Timer?
    private var simTotalLength: Float = 0
    private var simStockRadius: Float = 30.0
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

    // Called from the main thread (gesture recognizer callback) — no async dispatch needed.
    func selectShape(_ shape: SelectedShape?) {
        selectedShape = shape
        guard let selected = shape, let stock = selected.stockInfo,
              let all = loadedModel?.selectableShapes else {
            matchingShapes = []
            packScene = nil
            stopSim()
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
    func generatePackGCode(triggerSave: Bool = true) {
        guard let selected = selectedShape else { return }
        let allShapes = [selected] + matchingShapes
        // Ascending: same order as buildPackScene — shortest left, longest right (first cut)
        let sorted = allShapes.sorted { ($0.stockInfo?.length ?? 0) < ($1.stockInfo?.length ?? 0) }

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
        // Build simulation segments from the G-code so Start replays the actual toolpath
        simSegments = buildSimSegments(from: generatedGCode ?? "")
        resetSim()
        if triggerSave {
            NotificationCenter.default.post(name: .saveGCode, object: nil)
        }
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
        stopSim()
        simSegments = []
        simSegmentIdx = 0
        simSegmentElapsed = 0
        guard let selected = selectedShape, selected.stockInfo != nil else {
            packScene = nil
            return
        }
        let allShapes = [selected] + matchingShapes
        // Ascending sort: shortest on left, longest on RIGHT (torch side)
        let sorted = allShapes.sorted { ($0.stockInfo?.length ?? 0) < ($1.stockInfo?.length ?? 0) }

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
        let dirLight = SCNLight()
        dirLight.type = .directional
        dirNode.light = dirLight
        dirNode.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 4, 0)
        scene.rootNode.addChildNode(dirNode)

        // All piece geometry goes into stockGroup so it can translate/rotate as one unit
        let stockGroup = SCNNode()
        stockGroup.name = "stockGroup"
        scene.rootNode.addChildNode(stockGroup)

        for (idx, shape) in sorted.enumerated() {
            guard let stock = shape.stockInfo,
                  let geometry = shape.node?.geometry else { continue }

            let length = Float(stock.length)
            let q1 = alignAxisToX(stock.axis)
            let q: simd_quatf
            if stock.profile != .round {
                let rotatedU = q1.act(normalize(stock.uAxis))
                let rollAngle = atan2(rotatedU.z, rotatedU.y)
                let q2 = simd_quatf(angle: -rollAngle, axis: SIMD3<Float>(1, 0, 0))
                q = q2 * q1
            } else {
                q = q1
            }

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
            stockGroup.addChildNode(node)

            let cross = max(Float(stock.odX ?? stock.od ?? 0), Float(stock.odY ?? stock.od ?? 0))
            maxCross = max(maxCross, cross)
            packX += length + gap
        }

        let totalLength = packX > gap ? packX - gap : packX
        simTotalLength  = totalLength
        simStockRadius  = maxCross / 2.0

        // Torch: a downward-pointing cone fixed in scene space (not in stockGroup).
        // Positioned at the RIGHT end of the stock (where cutting starts).
        let torchHeight: Float = 16.0
        let torchCone = SCNCone(topRadius: CGFloat(maxCross * 0.08), bottomRadius: 0, height: CGFloat(torchHeight))
        let torchMat = SCNMaterial()
        torchMat.diffuse.contents  = NSColor(red: 1.0, green: 0.75, blue: 0.1, alpha: 1.0)
        torchMat.emission.contents = NSColor(red: 0.4, green: 0.2,  blue: 0.0, alpha: 1.0)
        torchMat.isDoubleSided = true
        torchCone.materials = [torchMat]
        let torchNode = SCNNode(geometry: torchCone)
        torchNode.name = "torch"
        // SCNCone with topRadius=fat, bottomRadius=0: tip is at -height/2 in local Y.
        // We want tip to sit just above stock surface (Y = maxCross/2 + 2).
        let tipY = maxCross / 2.0 + 2.0
        torchNode.position = SCNVector3(CGFloat(totalLength), CGFloat(tipY + torchHeight / 2.0), 0)
        scene.rootNode.addChildNode(torchNode)

        // Camera: look at full initial stock range, torch on the right
        let camDist = max(maxCross * 3.5, totalLength * 0.5)
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
        guard let scene = packScene,
              let stockGroup = scene.rootNode.childNode(withName: "stockGroup", recursively: false) else { return }
        // Torch is fixed at simTotalLength in scene space; stock moves so torch appears at gcodeX
        stockGroup.position = SCNVector3(simTotalLength - gcodeX, 0, 0)
        stockGroup.eulerAngles = SCNVector3(gcodeA * Float.pi / 180.0, 0, 0)
        // Light up torch when cutting
        if let torchNode = scene.rootNode.childNode(withName: "torch", recursively: false) {
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

struct PackView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        if let scene = viewModel.packScene {
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
                            let n = viewModel.matchingShapes.count + 1
                            Text("← longest on right (\(n) piece\(n == 1 ? "" : "s"))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)

                        PackSceneView(scene: scene)
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
            .sorted { ($0.stockInfo?.length ?? 0) < ($1.stockInfo?.length ?? 0) }
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
