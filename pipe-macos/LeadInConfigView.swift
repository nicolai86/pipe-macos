import SwiftUI

// MARK: - SurfaceFeatureType display helpers

extension SurfaceFeatureType {
    var displayName: String {
        switch self {
        case .startCut: return "Start Cut"
        case .endCut:   return "End Cut"
        case .hole:     return "Hole"
        case .notch:    return "Notch"
        case .cutout:   return "Cutout"
        }
    }

    var icon: String {
        switch self {
        case .startCut: return "scissors"
        case .endCut:   return "scissors"
        case .hole:     return "circle"
        case .notch:    return "triangle"
        case .cutout:   return "square"
        }
    }

    var color: Color {
        switch self {
        case .startCut, .endCut: return .red
        case .hole:              return Color(red: 0.3, green: 0.6, blue: 1.0)
        case .notch:             return .orange
        case .cutout:            return Color(red: 0.7, green: 0.3, blue: 1.0)
        }
    }

    /// Lead-out strategies available for this feature type.
    var validLeadOutStrategies: [LeadOutStrategy] {
        switch self {
        case .startCut, .endCut:
            return [.rotationalArc, .linear, .none]
        case .hole, .cutout, .notch:
            return [.linear, .none]
        }
    }

    /// Lead-in strategies that make physical sense for this feature type.
    var validLeadInStrategies: [LeadInStrategy] {
        switch self {
        case .startCut, .endCut:
            // Sever cuts must not move X, so only rotational arc or none.
            return [.rotationalArc, .none]
        case .hole, .cutout:
            return LeadInStrategy.allCases
        case .notch:
            return [.tangentArc, .linear, .centerPierce, .spiral, .none]
        }
    }
}

// MARK: - Feature List View

/// Shows a clickable row per feature in the selected stock, with an inline
/// lead-in config panel that expands when the feature is selected.
struct FeatureListView: View {
    @ObservedObject var viewModel: AppViewModel
    let features: [GeometricFeature]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Features")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(features.count)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 4)

            if features.isEmpty {
                Text("No features detected.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(features) { feature in
                    FeatureRowView(viewModel: viewModel, feature: feature)
                        .padding(.vertical, 1)
                }
            }
        }
    }
}

// MARK: - Feature Row View

struct FeatureRowView: View {
    @ObservedObject var viewModel: AppViewModel
    let feature: GeometricFeature

    private var isSelected: Bool { viewModel.selectedFeatureID == feature.id }
    private var hasOverride: Bool {
        viewModel.featureLeadInOverrides[feature.id] != nil
        || viewModel.featureLeadOutOverrides[feature.id] != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Row header ──────────────────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: feature.type.icon)
                    .font(.caption)
                    .foregroundColor(feature.type.color)
                    .frame(width: 14)

                Text(feature.type.displayName)
                    .font(.caption)
                    .fontWeight(.semibold)

                if hasOverride {
                    Text("custom")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18))
                        .cornerRadius(3)
                }

                Spacer()

                Text(positionLabel)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)

                if let dim = dimensionLabel {
                    Text(dim)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isSelected
                ? Color.accentColor.opacity(0.14)
                : Color(NSColor.controlBackgroundColor))
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    viewModel.selectFeature(isSelected ? nil : feature.id)
                }
            }

            // ── Inline config panel ─────────────────────────────────────────
            if isSelected {
                FeatureConfigPanel(
                    leadInConfig: Binding(
                        get: { viewModel.resolvedLeadInConfig(for: feature) },
                        set: { viewModel.setLeadInOverride($0, forFeatureID: feature.id) }
                    ),
                    leadOutConfig: Binding(
                        get: { viewModel.resolvedLeadOutConfig(for: feature) },
                        set: { viewModel.setLeadOutOverride($0, forFeatureID: feature.id) }
                    ),
                    feature: feature,
                    suggestedLeadInStrategy: viewModel.suggestedLeadInStrategy(for: feature),
                    suggestedLeadOutStrategy: viewModel.suggestedLeadOutStrategy(for: feature),
                    hasLeadInOverride: viewModel.featureLeadInOverrides[feature.id] != nil,
                    hasLeadOutOverride: viewModel.featureLeadOutOverrides[feature.id] != nil,
                    onResetLeadIn:  { viewModel.resetLeadInOverride(forFeatureID: feature.id) },
                    onResetLeadOut: { viewModel.resetLeadOutOverride(forFeatureID: feature.id) }
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isSelected
                    ? Color.accentColor.opacity(0.5)
                    : Color(NSColor.separatorColor).opacity(0.5),
                        lineWidth: 1)
        )
        .cornerRadius(5)
    }

    private var positionLabel: String {
        "X \(String(format: "%.1f", feature.xCenter)) · A \(String(format: "%.0f", feature.aCenterDeg))°"
    }

    private var dimensionLabel: String? {
        if let d = feature.dimensions["diameter"] {
            return "Ø\(String(format: "%.1f", d))"
        }
        if let w = feature.dimensions["width"], let h = feature.dimensions["height"] {
            return "\(String(format: "%.1f", w))×\(String(format: "%.1f", h))"
        }
        return nil
    }
}

// MARK: - Combined Feature Config Panel

/// Inline card showing lead-in AND lead-out configuration for one feature.
struct FeatureConfigPanel: View {
    @Binding var leadInConfig: LeadInConfig
    @Binding var leadOutConfig: LeadOutConfig
    let feature: GeometricFeature
    let suggestedLeadInStrategy: LeadInStrategy
    let suggestedLeadOutStrategy: LeadOutStrategy
    let hasLeadInOverride: Bool
    let hasLeadOutOverride: Bool
    let onResetLeadIn: () -> Void
    let onResetLeadOut: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Lead-In ──────────────────────────────────────────────────────
            ConfigSection(
                title: "Lead-In",
                accentColor: .orange,
                content: {
                    LeadInStrategyBlock(
                        config: $leadInConfig,
                        feature: feature,
                        suggested: suggestedLeadInStrategy
                    )
                    LeadInParamsView(config: $leadInConfig)
                    ResetRow(hasOverride: hasLeadInOverride, onReset: onResetLeadIn)
                }
            )

            Divider().opacity(0.5)

            // ── Lead-Out ─────────────────────────────────────────────────────
            ConfigSection(
                title: "Lead-Out",
                accentColor: Color(red: 0.4, green: 1.0, blue: 0.4),
                content: {
                    LeadOutStrategyBlock(
                        config: $leadOutConfig,
                        feature: feature,
                        suggested: suggestedLeadOutStrategy
                    )
                    LeadOutParamsView(config: $leadOutConfig)
                    ResetRow(hasOverride: hasLeadOutOverride, onReset: onResetLeadOut)
                }
            )
        }
        .background(Color(NSColor.windowBackgroundColor).opacity(0.7))
    }
}

// MARK: - Config Section Wrapper

private struct ConfigSection<Content: View>: View {
    let title: String
    let accentColor: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Rectangle()
                    .fill(accentColor)
                    .frame(width: 3, height: 12)
                    .cornerRadius(1.5)
                Text(title)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(accentColor)
            }
            content()
        }
        .padding(10)
    }
}

// MARK: - Lead-In Strategy Block

private struct LeadInStrategyBlock: View {
    @Binding var config: LeadInConfig
    let feature: GeometricFeature
    let suggested: LeadInStrategy

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("", selection: $config.strategy) {
                    ForEach(feature.type.validLeadInStrategies) { strategy in
                        HStack(spacing: 4) {
                            Text(strategy.displayName)
                            if strategy == suggested {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundColor(.green)
                                    .font(.caption2)
                            }
                        }
                        .tag(strategy)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                if config.strategy == suggested {
                    Text("Suggested")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
                Spacer()
            }
            Text(config.strategy.shortDescription)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Lead-Out Strategy Block

private struct LeadOutStrategyBlock: View {
    @Binding var config: LeadOutConfig
    let feature: GeometricFeature
    let suggested: LeadOutStrategy

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("", selection: $config.strategy) {
                    ForEach(feature.type.validLeadOutStrategies) { strategy in
                        HStack(spacing: 4) {
                            Text(strategy.displayName)
                            if strategy == suggested {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundColor(.green)
                                    .font(.caption2)
                            }
                        }
                        .tag(strategy)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                if config.strategy == suggested {
                    Text("Suggested")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
                Spacer()
            }
            Text(config.strategy.shortDescription)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Reset Row

private struct ResetRow: View {
    let hasOverride: Bool
    let onReset: () -> Void

    var body: some View {
        if hasOverride {
            Button(action: onReset) {
                Label("Reset to type default", systemImage: "arrow.counterclockwise")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
        } else {
            Text("Using type default")
                .font(.caption2)
                .foregroundColor(Color(NSColor.tertiaryLabelColor))
        }
    }
}

// MARK: - Lead-In Params View

/// Shows the parameter controls relevant to the active strategy.
struct LeadInParamsView: View {
    @Binding var config: LeadInConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if config.strategy == .rotationalArc {
                SliderRow(
                    label: "Sweep", value: $config.rotationalSweepMm,
                    range: 2...20, step: 0.5, unit: "mm",
                    help: "A-axis arc length before reaching cut line"
                )
            }

            if config.strategy == .tangentArc {
                SliderRow(
                    label: "Arc radius", value: $config.arcRadius,
                    range: 1...15, step: 0.5, unit: "mm",
                    help: "Radius of the circular approach arc"
                )
                SliderRow(
                    label: "Arc angle", value: $config.arcAngleDeg,
                    range: 30...180, step: 5, unit: "°",
                    help: "Angle swept by the arc (90° = true tangent entry)"
                )
                SliderRow(
                    label: "Approach", value: $config.approachLength,
                    range: 1...10, step: 0.5, unit: "mm",
                    help: "Straight segment before arc start"
                )
            }

            if config.strategy == .linear {
                SliderRow(
                    label: "Length", value: $config.linearLength,
                    range: 2...20, step: 0.5, unit: "mm",
                    help: "Total straight approach length"
                )
                SliderRow(
                    label: "Angle", value: $config.linearAngleDeg,
                    range: 10...80, step: 5, unit: "°",
                    help: "Approach angle relative to cut-path tangent"
                )
            }

            if config.strategy == .centerPierce {
                IntSliderRow(
                    label: "Steps", value: $config.centerPierceSteps,
                    range: 2...10,
                    help: "Points interpolated from centroid to cut path"
                )
            }

            if config.strategy == .spiral {
                SliderRow(
                    label: "Turns", value: $config.spiralTurns,
                    range: 0.25...2.0, step: 0.25, unit: "×",
                    help: "Number of spiral turns from centroid outward"
                )
                IntSliderRow(
                    label: "Steps", value: $config.spiralSteps,
                    range: 8...48,
                    help: "Points along the spiral path"
                )
            }

            if config.strategy == .none {
                Text("No approach geometry — torch pierces directly on the cut line.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Lead-Out Params View

/// Shows the parameter controls relevant to the active lead-out strategy.
struct LeadOutParamsView: View {
    @Binding var config: LeadOutConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if config.strategy == .linear {
                SliderRow(
                    label: "Extension", value: $config.extensionMm,
                    range: 0.5...15, step: 0.5, unit: "mm",
                    help: "Distance to extend past the exit/closure point (overburn)"
                )
                SliderRow(
                    label: "Angle offset", value: $config.extensionAngleDeg,
                    range: -30...30, step: 2.5, unit: "°",
                    help: "Angular deflection from exit tangent (0° = straight ahead)"
                )
            }

            if config.strategy == .rotationalArc {
                SliderRow(
                    label: "Sweep", value: $config.rotationalSweepMm,
                    range: 1...15, step: 0.5, unit: "mm",
                    help: "A-axis arc length past the exit point during torch ramp-down"
                )
            }

            if config.strategy == .none {
                Text("Torch stops exactly at the exit point — no overburn applied.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Slider helpers

private struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(formattedValue)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(width: 44, alignment: .trailing)
            }
            Slider(value: $value, in: range, step: step)
                .controlSize(.mini)
                .help(help)
        }
    }

    private var formattedValue: String {
        let isWhole = value.truncatingRemainder(dividingBy: 1) == 0
        return isWhole
            ? String(format: "%.0f\(unit)", value)
            : String(format: "%.1f\(unit)", value)
    }
}

private struct IntSliderRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let help: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(value)")
                    .font(.system(.caption2, design: .monospaced))
                    .frame(width: 44, alignment: .trailing)
            }
            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { value = Int($0.rounded()) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 1
            )
            .controlSize(.mini)
            .help(help)
        }
    }
}
