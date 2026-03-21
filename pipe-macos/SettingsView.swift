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
                Section("Motion") {
                    advancedField("Rapid Rate", unit: "mm/min", value: $manager.advancedSettings.rapidRate)
                    advancedField("Safe Height", unit: "mm", value: $manager.advancedSettings.safeHeight)
                }

                Section("Lead-in") {
                    advancedField("Linear Length", unit: "mm", value: $manager.advancedSettings.leadInDistance)
                    advancedField("Arc Sweep", unit: "°", value: $manager.advancedSettings.leadInAngle)
                    advancedField("Arc Radius", unit: "mm", value: $manager.advancedSettings.leadInAngleDistance)
                    advancedField("Overburn", unit: "°", value: $manager.advancedSettings.overburnDegrees)
                }

                Section("Compensation") {
                    Toggle("Enable Kerf Compensation", isOn: $manager.advancedSettings.enableKerfComp)
                        .onChange(of: manager.advancedSettings.enableKerfComp) { _ in manager.saveAdvanced() }
                    Toggle("Use SimCNC Feedrate Mode", isOn: $manager.advancedSettings.useSimCNC)
                        .onChange(of: manager.advancedSettings.useSimCNC) { _ in manager.saveAdvanced() }
                    Toggle("Enable Dynamic THC (corner lock)", isOn: $manager.advancedSettings.enableDynamicTHC)
                        .onChange(of: manager.advancedSettings.enableDynamicTHC) { _ in manager.saveAdvanced() }
                }

                Section("Axis Acceleration Limits") {
                    advancedField("X Axis", unit: "mm/s²", value: $manager.advancedSettings.maxAccelX)
                    advancedField("Y Axis", unit: "mm/s²", value: $manager.advancedSettings.maxAccelY)
                    advancedField("Z Axis", unit: "mm/s²", value: $manager.advancedSettings.maxAccelZ)
                    advancedField("A Axis", unit: "°/s²",  value: $manager.advancedSettings.maxAccelA)
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
