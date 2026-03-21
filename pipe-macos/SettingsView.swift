import SwiftUI

// MARK: - Settings Window Entry Point

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var manager = CutPresetManager.shared
    @State private var selectedPresetID: UUID? = nil
    @State private var editingPreset: CutPreset? = nil
    @State private var isAddingNew = false
    @State private var tab: Tab = .presets
    @State private var searchText = ""

    enum Tab { case presets, advanced }

    private func matches(_ preset: CutPreset) -> Bool {
        guard !searchText.isEmpty else { return true }
        let q = searchText.lowercased()
        return preset.name.lowercased().contains(q)
            || preset.source.lowercased().contains(q)
            || String(Int(preset.amperage)).contains(q)
    }

    private var filteredPresets: [CutPreset] {
        manager.presets.filter { matches($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Cut Presets").tag(Tab.presets)
                Text("Advanced").tag(Tab.advanced)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            switch tab {
            case .presets:  presetsTab
            case .advanced: advancedTab
            }

            Divider()

            HStack {
                Spacer()
                Button("OK") {
                    manager.savePresets()
                    manager.saveAdvanced()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 720, minHeight: 480)
    }

    // MARK: - Presets Tab

    private var presetsTab: some View {
        HSplitView {
            // ── Sidebar: grouped preset list ──────────────────────────────────
            VStack(spacing: 0) {
                TextField("Search (material, thickness, amperage…)", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)

                Divider()

                List(selection: $selectedPresetID) {
                    if searchText.isEmpty {
                        let sources = Array(Set(manager.presets.map { $0.source })).sorted()
                        ForEach(sources, id: \.self) { source in
                            Section(source) {
                                ForEach(manager.presets.filter { $0.source == source }) { preset in
                                    PresetRow(preset: preset,
                                              isActive: manager.activePresetID == preset.id,
                                              onActivate: { activateAndClose(preset.id) })
                                        .tag(preset.id)
                                }
                            }
                        }
                    } else {
                        ForEach(filteredPresets) { preset in
                            PresetRow(preset: preset,
                                      isActive: manager.activePresetID == preset.id,
                                      onActivate: { activateAndClose(preset.id) })
                                .tag(preset.id)
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider()

                HStack(spacing: 6) {
                    Button { addNewPreset() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("Add custom preset")

                    Button { deleteSelected() } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .disabled(selectedPresetID == nil)
                        .help("Delete selected preset")

                    Spacer()

                    Button("Reset to Defaults") {
                        manager.resetToDefaults()
                        selectedPresetID = nil
                        editingPreset = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Restore all built-in Hypertherm presets")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(minWidth: 240, maxWidth: 300)

            // ── Detail / Edit panel ───────────────────────────────────────────
            Group {
                if let editing = editingPreset {
                    PresetEditForm(preset: editing, onSave: { saved in
                        if isAddingNew {
                            manager.addPreset(saved)
                            selectedPresetID = saved.id
                            isAddingNew = false
                        } else {
                            manager.updatePreset(saved)
                        }
                        editingPreset = nil
                    }, onCancel: {
                        isAddingNew = false
                        editingPreset = nil
                    })
                } else if let id = selectedPresetID,
                          let preset = manager.presets.first(where: { $0.id == id }) {
                    PresetDetailView(
                        preset: preset,
                        isActive: manager.activePresetID == id,
                        onActivate: { activateAndClose(id) },
                        onEdit: { editingPreset = preset }
                    )
                } else {
                    VStack {
                        Spacer()
                        Text("Select a preset to view details")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onChange(of: selectedPresetID) { _ in
            if !isAddingNew { editingPreset = nil }
        }
    }

    // MARK: - Advanced Tab

    private var advancedTab: some View {
        ScrollView {
            Form {
                Section {
                    advancedField("Rapid Rate", unit: "mm/min", value: $manager.advancedSettings.rapidRate)
                    advancedField("Safe Height", unit: "mm", value: $manager.advancedSettings.safeHeight)
                } header: {
                    AdvancedSectionHeader(title: "Motion", info: "Controls how fast the machine moves between features and how high the torch retracts during repositioning. Rapid Rate should match the maximum safe traverse speed configured in your controller — going higher risks missed steps on stepper-driven axes. Safe Height must clear the tallest point of the tube (including any corner overhang on rectangular stock) during A-axis rotation rapids; increase it if you hear the torch clipping the tube on repositioning moves.")
                }

                Section {
                    advancedField("Linear Length", unit: "mm", value: $manager.advancedSettings.leadInDistance)
                    advancedField("Arc Sweep", unit: "°", value: $manager.advancedSettings.leadInAngle)
                    advancedField("Arc Radius", unit: "mm", value: $manager.advancedSettings.leadInAngleDistance)
                    advancedField("Overburn", unit: "°", value: $manager.advancedSettings.overburnDegrees)
                } header: {
                    AdvancedSectionHeader(title: "Lead-in", info: "Shapes the entry path the torch takes before it joins the cut contour. The torch pierces at the far end of the straight segment (Linear Length), travels along it, then sweeps through an arc (Arc Sweep, Arc Radius) that blends tangentially into the cut line — keeping the rough pierce hole and any dross in the scrap zone. Overburn extends the path past the closure point to prevent a notch at torch-off. Increase Linear Length if pierce dross is landing on the finished edge; increase Overburn if you see a visible step or gap at the cut closure.")
                }

                Section {
                    Toggle("Enable Thermal Hedging", isOn: $manager.advancedSettings.enableThermalHedging)
                        .onChange(of: manager.advancedSettings.enableThermalHedging) { _ in manager.saveAdvanced() }
                    advancedField("X Weight", unit: "×", value: $manager.advancedSettings.thermalHedgingWeightX)
                        .disabled(!manager.advancedSettings.enableThermalHedging)
                        .foregroundColor(manager.advancedSettings.enableThermalHedging ? .primary : .secondary)
                    advancedField("A Weight", unit: "×", value: $manager.advancedSettings.thermalHedgingWeightA)
                        .disabled(!manager.advancedSettings.enableThermalHedging)
                        .foregroundColor(manager.advancedSettings.enableThermalHedging ? .primary : .secondary)
                } header: {
                    AdvancedSectionHeader(title: "Thermal Hedging", info: "Reorders the cutting sequence to spread heat evenly across the tube before severing. Internal features (holes, notches) are cut first in a nearest-neighbour order; sever cuts follow right-to-left so already-cut sections fall away cleanly. The X and A weights control how the sequencer balances axial travel against tube rotation when choosing the next feature — raise X Weight to prefer features that are close axially, raise A Weight to prefer features that require less tube rotation to reach. Leave both at 1.0 for equal weighting.")
                }

                Section {
                    Toggle("Enable Kerf Compensation", isOn: $manager.advancedSettings.enableKerfComp)
                        .onChange(of: manager.advancedSettings.enableKerfComp) { _ in manager.saveAdvanced() }
                    Toggle("Use SimCNC Feedrate Mode", isOn: $manager.advancedSettings.useSimCNC)
                        .onChange(of: manager.advancedSettings.useSimCNC) { _ in manager.saveAdvanced() }
                    Toggle("Enable Dynamic THC (corner lock)", isOn: $manager.advancedSettings.enableDynamicTHC)
                        .onChange(of: manager.advancedSettings.enableDynamicTHC) { _ in manager.saveAdvanced() }
                    Toggle("Enable Dynamic Safe Z (asymmetric envelope)", isOn: $manager.advancedSettings.enableDynamicSafeZ)
                        .onChange(of: manager.advancedSettings.enableDynamicSafeZ) { _ in manager.saveAdvanced() }
                } header: {
                    AdvancedSectionHeader(title: "Compensation", info: "Kerf Compensation offsets the cut path inward or outward by half the kerf width so the finished part matches the intended geometry — leave this on unless your controller applies its own G41/G42 offset. SimCNC Feedrate Mode generates feed rates that account for all four axes simultaneously, preserving the intended cut speed; turn it off for standard Fanuc/Mach4/LinuxCNC controllers that interpret F as the XYZ linear rate only. Dynamic THC injects corner-lock codes (M220/M221) at HSS corner transitions to stop the torch-height controller from chasing rapid arc-voltage changes through the corner — disable only if your THC does not support M220/M221. Dynamic Safe Z raises the retract height automatically for rectangular stock whose corner radius exceeds the flat-face half-height; disable if you prefer a fixed retract height.")
                }

                Section {
                    advancedField("X Axis", unit: "mm/s²", value: $manager.advancedSettings.maxAccelX)
                    advancedField("Y Axis", unit: "mm/s²", value: $manager.advancedSettings.maxAccelY)
                    advancedField("Z Axis", unit: "mm/s²", value: $manager.advancedSettings.maxAccelZ)
                    advancedField("A Axis", unit: "°/s²",  value: $manager.advancedSettings.maxAccelA)
                } header: {
                    AdvancedSectionHeader(title: "Axis Acceleration Limits", info: "Must match the acceleration values configured in your machine controller (Mach4 motor tuning, LinuxCNC INI MAX_ACCELERATION). These are used by the velocity profiler to compute safe junction speeds and feed-rate ramps — they do not change the controller's actual limits. Setting these higher than the controller allows will produce feed-rate commands the machine cannot execute, causing missed steps or stalls. Setting them lower than the controller's actual capability leaves cut-speed potential unused. The A axis typically has the lowest practical limit due to chuck inertia; verify at low feed rate before raising it.")
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private func advancedField(_ label: String, unit: String, value: Binding<Double>) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField("", value: value, format: .number)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onChange(of: value.wrappedValue) { _ in manager.saveAdvanced() }
                Text(unit)
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .leading)
            }
        }
    }

    // MARK: - Actions

    private func activateAndClose(_ id: UUID) {
        manager.activePresetID = id
        dismiss()
    }

    private func addNewPreset() {
        let p = CutPreset(name: "New Preset", source: "Custom", amperage: 45,
                          feedRate: 1000, kerfWidth: 2.0, cutHeight: 3.2, pierceHeight: 3.8)
        isAddingNew = true
        editingPreset = p
    }

    private func deleteSelected() {
        guard let id = selectedPresetID else { return }
        manager.deletePresets(ids: [id])
        selectedPresetID = nil
        editingPreset = nil
    }
}

// MARK: - Advanced Section Header with Info Popover

private struct AdvancedSectionHeader: View {
    let title: String
    let info: String
    @State private var showingInfo = false

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Button {
                showingInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
                Text(info)
                    .font(.body)
                    .padding()
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Preset Row

private struct PresetRow: View {
    let preset: CutPreset
    let isActive: Bool
    let onActivate: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isActive ? .accentColor : .secondary)
                .onTapGesture { onActivate() }
            Text(preset.name)
                .lineLimit(1)
            Spacer()
            Text("\(Int(preset.amperage))A")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Preset Detail View

private struct PresetDetailView: View {
    let preset: CutPreset
    let isActive: Bool
    let onActivate: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.name).font(.title3).fontWeight(.semibold)
                    Text("\(preset.source)  ·  \(Int(preset.amperage)) A")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                if isActive {
                    Label("Active Preset", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundColor(.accentColor)
                } else {
                    Button("Set as Active", action: onActivate)
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }

            Divider()

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Text("Feed Rate").foregroundColor(.secondary)
                    Text(String(format: "%.0f mm/min", preset.feedRate))
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("Kerf Width").foregroundColor(.secondary)
                    Text(String(format: "%.3f mm", preset.kerfWidth))
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("Cut Height").foregroundColor(.secondary)
                    Text(String(format: "%.3f mm", preset.cutHeight))
                        .font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("Pierce Height").foregroundColor(.secondary)
                    Text(String(format: "%.3f mm", preset.pierceHeight))
                        .font(.system(.body, design: .monospaced))
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Edit", action: onEdit).buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Preset Edit Form

private struct PresetEditForm: View {
    @State private var draft: CutPreset
    let onSave: (CutPreset) -> Void
    let onCancel: () -> Void

    init(preset: CutPreset, onSave: @escaping (CutPreset) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: preset)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Identity") {
                    LabeledContent("Name") {
                        TextField("", text: $draft.name).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Source") {
                        TextField("", text: $draft.source).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Amperage") {
                        HStack(spacing: 4) {
                            TextField("", value: $draft.amperage, format: .number)
                                .multilineTextAlignment(.trailing).frame(width: 60)
                            Text("A").foregroundColor(.secondary)
                        }
                    }
                }

                Section("Cut Parameters") {
                    formField("Feed Rate",     unit: "mm/min", value: $draft.feedRate,     width: 80)
                    formField("Kerf Width",    unit: "mm",     value: $draft.kerfWidth,    width: 70)
                    formField("Cut Height",    unit: "mm",     value: $draft.cutHeight,    width: 70)
                    formField("Pierce Height", unit: "mm",     value: $draft.pierceHeight, width: 70)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Save", action: { onSave(draft) })
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func formField(_ label: String, unit: String, value: Binding<Double>, width: CGFloat) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField("", value: value, format: .number)
                    .multilineTextAlignment(.trailing).frame(width: width)
                Text(unit).foregroundColor(.secondary)
            }
        }
    }
}
