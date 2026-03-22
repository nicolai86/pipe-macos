import Foundation
import SwiftUI

// MARK: - Cut Preset Model

struct CutPreset: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String        // e.g. "Carbon Steel 6mm" or "Mild Steel 1/4 in"
    var source: String      // e.g. "HT Sync 85 Air", "HT Powermax Imperial", "Custom"
    var amperage: Double    // A
    var feedRate: Double    // mm/min
    var kerfWidth: Double   // mm
    var cutHeight: Double   // mm
    var pierceHeight: Double // mm
}

// MARK: - Display Settings

enum ViewBackground: String, Codable {
    case dark
    case light
}

struct DisplaySettings: Codable {
    var viewBackground: ViewBackground = .dark
}

// MARK: - Advanced Settings (all GCodeSettings fields that aren't preset-specific)

struct AdvancedSettings: Codable {
    var rapidRate: Double = 3000.0
    var safeHeight: Double = 25.0
    var leadInDistance: Double = 5.0
    var leadInAngle: Double = 90.0
    var leadInAngleDistance: Double = 3.0
    var overburnDegrees: Double = 10.0
    var enableKerfComp: Bool = true
    var useSimCNC: Bool = true
    // The Issue: You mentioned that IHS and drops to cut-height are delegated to SimCNC's M3 macro. But on HSS (square/rectangular) tubing, your offline TCP interpolation means the G-code is actively commanding constant Z-axis oscillation to track the flat faces and corners as the A-axis rotates. If SimCNC’s Torch Height Control (THC) is active, it will read arc voltage and try to adjust the Z-axis at the same time your G-code is commanding Z-moves. This creates a dual-loop control conflict that will cause the Z-axis to oscillate wildly or dive into the material. The Fix: * Dynamic THC Toggling: Pipe macOS needs to inject THC ON/OFF macros (or utilize SimCNC's specific anti-dive/corner-lock I/O signals) dynamically.
    //    Force THC OFF via G-code just before a corner radius where kinematic Z-acceleration is high, locking the Z-axis to your pre-calculated TCP trajectory. Turn THC back ON during the long, flat segments where Z-kinematics are stable and arc-voltage adjustments are actually needed to handle stock warping.
    var enableDynamicTHC: Bool = true
    var enableDynamicSafeZ: Bool = true
    var enableThermalHedging: Bool = true
    var thermalHedgingWeightX: Double = 1.0
    var thermalHedgingWeightA: Double = 1.0
    var maxAccelX: Double = 500.0
    var maxAccelY: Double = 500.0
    var maxAccelZ: Double = 300.0
    var maxAccelA: Double = 1000.0
}

// MARK: - Preset Manager

class CutPresetManager: ObservableObject {
    static let shared = CutPresetManager()

    @Published var presets: [CutPreset] = []
    @Published var activePresetID: UUID? = nil {
        didSet {
            if let id = activePresetID {
                UserDefaults.standard.set(id.uuidString, forKey: "activePresetID")
            } else {
                UserDefaults.standard.removeObject(forKey: "activePresetID")
            }
        }
    }
    @Published var advancedSettings: AdvancedSettings = AdvancedSettings()
    @Published var displaySettings: DisplaySettings = DisplaySettings()

    var activePreset: CutPreset? {
        presets.first { $0.id == activePresetID }
    }

    func currentGCodeSettings() -> GCodeSettings {
        var s = GCodeSettings()
        if let p = activePreset {
            s.feedRate     = CGFloat(p.feedRate)
            s.kerfWidth    = CGFloat(p.kerfWidth)
            s.cutHeight    = CGFloat(p.cutHeight)
            s.pierceHeight = CGFloat(p.pierceHeight)
        }
        s.rapidRate           = CGFloat(advancedSettings.rapidRate)
        s.safeHeight          = CGFloat(advancedSettings.safeHeight)
        s.leadInDistance      = CGFloat(advancedSettings.leadInDistance)
        s.leadInAngle         = CGFloat(advancedSettings.leadInAngle)
        s.leadInAngleDistance = CGFloat(advancedSettings.leadInAngleDistance)
        s.overburnDegrees     = CGFloat(advancedSettings.overburnDegrees)
        s.enableKerfComp      = advancedSettings.enableKerfComp
        s.useSimCNC           = advancedSettings.useSimCNC
        s.enableDynamicTHC       = advancedSettings.enableDynamicTHC
        s.enableDynamicSafeZ     = advancedSettings.enableDynamicSafeZ
        s.enableThermalHedging   = advancedSettings.enableThermalHedging
        s.thermalHedgingWeightX  = CGFloat(advancedSettings.thermalHedgingWeightX)
        s.thermalHedgingWeightA  = CGFloat(advancedSettings.thermalHedgingWeightA)
        s.maxAccelX           = CGFloat(advancedSettings.maxAccelX)
        s.maxAccelY           = CGFloat(advancedSettings.maxAccelY)
        s.maxAccelZ           = CGFloat(advancedSettings.maxAccelZ)
        s.maxAccelA           = CGFloat(advancedSettings.maxAccelA)
        return s
    }

    // MARK: - Persistence

    private var appSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pipe-macos")
    }

    init() { load() }

    func load() {
        try? FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)

        let presetsURL  = appSupportURL.appendingPathComponent("presets.json")
        let advancedURL = appSupportURL.appendingPathComponent("advanced_settings.json")

        if let data = try? Data(contentsOf: presetsURL),
           let decoded = try? JSONDecoder().decode([CutPreset].self, from: data) {
            presets = decoded
        } else {
            presets = CutPresetManager.defaultPresets
            savePresets()
        }

        if let data = try? Data(contentsOf: advancedURL),
           let decoded = try? JSONDecoder().decode(AdvancedSettings.self, from: data) {
            advancedSettings = decoded
        }

        let displayURL = appSupportURL.appendingPathComponent("display_settings.json")
        if let data = try? Data(contentsOf: displayURL),
           let decoded = try? JSONDecoder().decode(DisplaySettings.self, from: data) {
            displaySettings = decoded
        }

        // Restore active preset selection — fall back to first if saved ID is gone
        if let saved = UserDefaults.standard.string(forKey: "activePresetID"),
           let uuid = UUID(uuidString: saved),
           presets.contains(where: { $0.id == uuid }) {
            activePresetID = uuid
        } else {
            activePresetID = presets.first?.id
        }
    }

    func savePresets() {
        let url = appSupportURL.appendingPathComponent("presets.json")
        if let data = try? JSONEncoder().encode(presets) {
            try? data.write(to: url)
        }
    }

    func saveAdvanced() {
        let url = appSupportURL.appendingPathComponent("advanced_settings.json")
        if let data = try? JSONEncoder().encode(advancedSettings) {
            try? data.write(to: url)
        }
    }

    func saveDisplay() {
        let url = appSupportURL.appendingPathComponent("display_settings.json")
        if let data = try? JSONEncoder().encode(displaySettings) {
            try? data.write(to: url)
        }
    }

    func addPreset(_ preset: CutPreset) {
        presets.append(preset)
        savePresets()
    }

    func updatePreset(_ preset: CutPreset) {
        if let idx = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[idx] = preset
            savePresets()
        }
    }

    func deletePresets(ids: Set<UUID>) {
        presets.removeAll { ids.contains($0.id) }
        if let active = activePresetID, ids.contains(active) {
            activePresetID = presets.first?.id
        }
        savePresets()
    }

    func resetToDefaults() {
        presets = CutPresetManager.defaultPresets
        activePresetID = presets.first?.id
        savePresets()
    }

    // MARK: - Built-in Hypertherm Seed Data

    // Metric helper: feed mm/min, heights mm
    private static func m(_ name: String, _ amp: Double, _ feed: Double,
                          _ pierceH: Double, _ cutH: Double, _ kerf: Double) -> CutPreset {
        CutPreset(name: name, source: "HT Sync 85 Air", amperage: amp,
                  feedRate: feed, kerfWidth: kerf, cutHeight: cutH, pierceHeight: pierceH)
    }

    // Imperial helper: feed in/min → mm/min, dimensions inches → mm
    private static func imp(_ name: String, _ amp: Double, _ feedIpm: Double,
                            _ pierceH_in: Double, _ cutH_in: Double, _ kerf_in: Double) -> CutPreset {
        let k = 25.4
        return CutPreset(name: name, source: "HT Powermax Imperial", amperage: amp,
                         feedRate: feedIpm * k, kerfWidth: kerf_in * k,
                         cutHeight: cutH_in * k, pierceHeight: pierceH_in * k)
    }

    static let defaultPresets: [CutPreset] = [
        // ── HT Sync 85 Air ── Aluminum ────────────────────────────────────────
        m("Aluminum 1mm",          45,  8260, 3.8, 3.2, 1.6),
        m("Aluminum 2mm",          45,  5970, 3.8, 3.2, 1.8),
        m("Aluminum 3mm",          45,  3350, 3.8, 3.2, 1.9),
        m("Aluminum 4mm",          45,  2210, 3.8, 3.2, 1.9),
        m("Aluminum 6mm",          45,  1240, 3.8, 3.2, 2.0),
        m("Aluminum 2mm",          65,  9270, 3.8, 3.2, 1.4),
        m("Aluminum 3mm",          65,  7540, 3.8, 3.2, 1.5),
        m("Aluminum 4mm",          65,  5380, 3.8, 3.2, 1.5),
        m("Aluminum 6mm",          65,  2900, 3.8, 3.2, 1.6),
        m("Aluminum 8mm",          65,  1780, 3.8, 3.2, 1.7),
        m("Aluminum 10mm",         65,  1220, 4.8, 3.2, 1.8),
        m("Aluminum 12mm",         65,   940, 4.8, 3.2, 1.9),
        m("Aluminum 3mm",          85,  7980, 3.8, 3.2, 1.9),
        m("Aluminum 4mm",          85,  6050, 3.8, 3.2, 2.0),
        m("Aluminum 6mm",          85,  3630, 3.8, 3.2, 2.2),
        m("Aluminum 8mm",          85,  2440, 3.8, 3.2, 2.4),
        m("Aluminum 10mm",         85,  1780, 4.8, 3.2, 2.5),
        m("Aluminum 12mm",         85,  1400, 4.8, 3.2, 2.6),
        m("Aluminum 16mm",         85,   940, 4.8, 3.2, 2.7),
        // ── Stainless Steel ───────────────────────────────────────────────────
        m("Stainless Steel 0.5mm", 45,  8890, 3.8, 3.2, 1.1),
        m("Stainless Steel 1mm",   45,  8890, 3.8, 3.2, 0.8),
        m("Stainless Steel 1.5mm", 45,  8890, 3.8, 3.2, 0.7),
        m("Stainless Steel 2mm",   45,  6220, 3.8, 3.2, 0.8),
        m("Stainless Steel 3mm",   45,  3230, 3.8, 3.2, 1.4),
        m("Stainless Steel 4mm",   45,  1960, 3.8, 3.2, 2.2),
        m("Stainless Steel 6mm",   45,   860, 3.8, 3.2, 2.4),
        m("Stainless Steel 2mm",   65,  8760, 3.8, 3.2, 0.8),
        m("Stainless Steel 3mm",   65,  7650, 3.8, 3.2, 1.1),
        m("Stainless Steel 4mm",   65,  5160, 3.8, 3.2, 1.3),
        m("Stainless Steel 6mm",   65,  2440, 3.8, 3.2, 1.6),
        m("Stainless Steel 8mm",   65,  1350, 3.8, 3.2, 1.8),
        m("Stainless Steel 10mm",  65,   940, 4.8, 3.2, 2.0),
        m("Stainless Steel 12mm",  65,   740, 4.8, 3.2, 2.1),
        m("Stainless Steel 3mm",   85,  8100, 3.8, 3.2, 1.3),
        m("Stainless Steel 4mm",   85,  6220, 3.8, 3.2, 1.6),
        m("Stainless Steel 6mm",   85,  3630, 3.8, 3.2, 2.0),
        m("Stainless Steel 8mm",   85,  2260, 3.8, 3.2, 2.3),
        m("Stainless Steel 10mm",  85,  1500, 4.8, 3.2, 2.4),
        m("Stainless Steel 12mm",  85,  1040, 4.8, 3.2, 2.5),
        m("Stainless Steel 16mm",  85,   690, 4.8, 3.2, 2.5),
        // ── Carbon Steel ──────────────────────────────────────────────────────
        m("Carbon Steel 0.5mm",    45,  8890, 3.8, 3.2, 1.1),
        m("Carbon Steel 1mm",      45,  8890, 3.8, 3.2, 1.4),
        m("Carbon Steel 1.5mm",    45,  8890, 3.8, 3.2, 1.5),
        m("Carbon Steel 2mm",      45,  6600, 3.8, 3.2, 1.7),
        m("Carbon Steel 3mm",      45,  3630, 3.8, 3.2, 1.8),
        m("Carbon Steel 4mm",      45,  2260, 3.8, 3.2, 1.9),
        m("Carbon Steel 6mm",      45,  1240, 3.8, 3.2, 1.9),
        m("Carbon Steel 3mm",      65,  5330, 3.8, 3.2, 1.3),
        m("Carbon Steel 4mm",      65,  4220, 3.8, 3.2, 1.4),
        m("Carbon Steel 6mm",      65,  2570, 3.8, 3.2, 1.5),
        m("Carbon Steel 8mm",      65,  1550, 3.8, 3.2, 1.7),
        m("Carbon Steel 10mm",     65,  1040, 3.8, 3.2, 1.9),
        m("Carbon Steel 12mm",     65,   840, 3.8, 3.2, 2.0),
        m("Carbon Steel 16mm",     65,   560, 6.4, 3.2, 2.3),
        m("Carbon Steel 3mm",      85,  6930, 3.8, 3.2, 1.5),
        m("Carbon Steel 4mm",      85,  5560, 3.8, 3.2, 1.7),
        m("Carbon Steel 6mm",      85,  3560, 3.8, 3.2, 1.9),
        m("Carbon Steel 8mm",      85,  2360, 3.8, 3.2, 2.1),
        m("Carbon Steel 10mm",     85,  1630, 4.8, 3.2, 2.3),
        m("Carbon Steel 12mm",     85,  1240, 4.8, 3.2, 2.4),
        m("Carbon Steel 16mm",     85,   840, 4.8, 3.2, 2.6),
        m("Carbon Steel 20mm",     85,   580, 6.4, 3.2, 2.8),

        // ── HT Powermax Imperial ── Mild Steel FineCut ────────────────────────
        imp("Mild Steel 26 GA FineCut",  45, 350, 0.140, 0.140, 0.033),
        imp("Mild Steel 24 GA FineCut",  45, 350, 0.140, 0.140, 0.032),
        imp("Mild Steel 22 GA FineCut",  45, 350, 0.140, 0.140, 0.026),
        imp("Mild Steel 20 GA FineCut",  45, 350, 0.140, 0.140, 0.024),
        imp("Mild Steel 18 GA FineCut",  45, 250, 0.140, 0.140, 0.021),
        imp("Mild Steel 16 GA FineCut",  45, 250, 0.140, 0.140, 0.021),
        imp("Mild Steel 14 GA FineCut",  45, 220, 0.140, 0.140, 0.021),
        imp("Mild Steel 12 GA FineCut",  45, 115, 0.140, 0.140, 0.032),
        imp("Mild Steel 10 GA FineCut",  45, 100, 0.140, 0.140, 0.031),
        // Mild Steel standard
        imp("Mild Steel 10 GA",          45, 115, 0.150, 0.125, 0.073),
        imp("Mild Steel 3/16 in",        45,  68, 0.150, 0.125, 0.074),
        imp("Mild Steel 1/4 in",         45,  46, 0.150, 0.125, 0.075),
        imp("Mild Steel 10 GA",          65, 186, 0.150, 0.125, 0.053),
        imp("Mild Steel 3/16 in",        65, 138, 0.150, 0.125, 0.057),
        imp("Mild Steel 1/4 in",         65,  93, 0.150, 0.125, 0.062),
        imp("Mild Steel 3/8 in",         65,  44, 0.150, 0.125, 0.072),
        imp("Mild Steel 1/2 in",         65,  30, 0.150, 0.125, 0.081),
        imp("Mild Steel 5/8 in",         65,  22, 0.250, 0.125, 0.089),
        imp("Mild Steel 3/4 in",         65,  16, 0.250, 0.125, 0.097),
        imp("Mild Steel 10 GA",          85, 250, 0.150, 0.125, 0.063),
        imp("Mild Steel 3/16 in",        85, 185, 0.150, 0.125, 0.070),
        imp("Mild Steel 1/4 in",         85, 130, 0.125, 0.125, 0.077),
        imp("Mild Steel 3/8 in",         85,  70, 0.188, 0.125, 0.088),
        imp("Mild Steel 1/2 in",         85,  46, 0.150, 0.125, 0.096),
        imp("Mild Steel 5/8 in",         85,  34, 0.200, 0.125, 0.103),
        imp("Mild Steel 3/4 in",         85,  25, 0.250, 0.125, 0.108),
        imp("Mild Steel 7/8 in",         85,  19, 0.200, 0.125, 0.114),
        imp("Mild Steel 1 in",           85,  13, 0.250, 0.125, 0.120),
        imp("Mild Steel 1-1/8 in",       85,   9, 0.200, 0.125, 0.128),
        imp("Mild Steel 1-1/4 in",       85,   6, 0.250, 0.125, 0.139),
        // Stainless Steel FineCut
        imp("Stainless Steel 26 GA FineCut", 45, 350, 0.020, 0.140, 0.028),
        imp("Stainless Steel 24 GA FineCut", 45, 350, 0.140, 0.140, 0.024),
        imp("Stainless Steel 22 GA FineCut", 45, 350, 0.140, 0.140, 0.020),
        imp("Stainless Steel 20 GA FineCut", 45, 350, 0.140, 0.140, 0.016),
        imp("Stainless Steel 18 GA FineCut", 45, 240, 0.140, 0.140, 0.017),
        imp("Stainless Steel 16 GA FineCut", 45, 240, 0.140, 0.140, 0.017),
        imp("Stainless Steel 14 GA FineCut", 45,  50, 0.140, 0.140, 0.017),
        imp("Stainless Steel 12 GA FineCut", 45, 120, 0.140, 0.140, 0.026),
        imp("Stainless Steel 10 GA FineCut", 45,  75, 0.140, 0.140, 0.023),
        // Stainless Steel standard
        imp("Stainless Steel 10 GA",     45,  94, 0.150, 0.150, 0.072),
        imp("Stainless Steel 3/16 in",   45,  55, 0.150, 0.150, 0.102),
        imp("Stainless Steel 1/4 in",    45,  30, 0.150, 0.150, 0.082),
        imp("Stainless Steel 10 GA",     65, 241, 0.150, 0.150, 0.047),
        imp("Stainless Steel 3/16 in",   65, 150, 0.150, 0.150, 0.055),
        imp("Stainless Steel 1/4 in",    65,  86, 0.150, 0.150, 0.064),
        imp("Stainless Steel 3/8 in",    65,  40, 0.188, 0.150, 0.075),
        imp("Stainless Steel 1/2 in",    65,  27, 0.188, 0.150, 0.082),
        imp("Stainless Steel 5/8 in",    65,  19, 0.188, 0.150, 0.087),
        imp("Stainless Steel 3/4 in",    65,  14, 0.188, 0.150, 0.096),
        imp("Stainless Steel 10 GA",     85, 275, 0.150, 0.150, 0.060),
        imp("Stainless Steel 3/16 in",   85, 199, 0.150, 0.150, 0.071),
        imp("Stainless Steel 1/4 in",    85, 131, 0.150, 0.150, 0.082),
        imp("Stainless Steel 3/8 in",    85,  65, 0.188, 0.150, 0.094),
        imp("Stainless Steel 1/2 in",    85,  36, 0.188, 0.150, 0.098),
        imp("Stainless Steel 5/8 in",    85,  27, 1.000, 0.150, 0.098),
        imp("Stainless Steel 3/4 in",    85,  21, 0.150, 0.150, 0.102),
        imp("Stainless Steel 7/8 in",    85,  16, 0.150, 0.150, 0.114),
        imp("Stainless Steel 1 in",      85,  11, 0.150, 0.150, 0.141),
        // Aluminum FineCut
        imp("Aluminum 1/32 in FineCut",  45, 325, 0.140, 0.140, 0.062),
        imp("Aluminum 1/16 in FineCut",  45, 325, 0.140, 0.140, 0.069),
        imp("Aluminum 3/32 in FineCut",  45, 183, 0.140, 0.140, 0.073),
        imp("Aluminum 1/8 in FineCut",   45, 121, 0.140, 0.140, 0.074),
        imp("Aluminum 1/4 in FineCut",   45,  46, 0.140, 0.140, 0.081),
        // Aluminum standard
        imp("Aluminum 1/32 in",          45, 325, 0.150, 0.150, 0.062),
        imp("Aluminum 1/16 in",          45, 325, 0.150, 0.150, 0.069),
        imp("Aluminum 3/32 in",          45, 183, 0.150, 0.150, 0.073),
        imp("Aluminum 1/8 in",           45, 121, 0.150, 0.150, 0.074),
        imp("Aluminum 1/4 in",           45,  46, 0.150, 0.150, 0.081),
        imp("Aluminum 1/16 in",          65, 365, 0.150, 0.150, 0.056),
        imp("Aluminum 1/8 in",           65, 280, 0.150, 0.150, 0.059),
        imp("Aluminum 1/4 in",           65, 104, 0.150, 0.150, 0.064),
        imp("Aluminum 3/8 in",           65,  52, 0.188, 0.150, 0.069),
        imp("Aluminum 1/2 in",           65,  34, 0.188, 0.150, 0.076),
        imp("Aluminum 5/8 in",           65,  25, 0.188, 0.150, 0.083),
        imp("Aluminum 3/4 in",           65,  17, 0.188, 0.150, 0.092),
        imp("Aluminum 1/8 in",           85, 300, 0.150, 0.125, 0.076),
        imp("Aluminum 1/4 in",           85, 133, 0.150, 0.125, 0.089),
        imp("Aluminum 3/8 in",           85,  75, 0.150, 0.125, 0.097),
        imp("Aluminum 1/2 in",           85,  51, 0.150, 0.125, 0.102),
        imp("Aluminum 5/8 in",           85,  38, 0.150, 0.125, 0.106),
        imp("Aluminum 3/4 in",           85,  26, 0.150, 0.125, 0.109),
        imp("Aluminum 7/8 in",           85,  19, 0.150, 0.125, 0.113),
        imp("Aluminum 1 in",             85,  15, 0.150, 0.125, 0.119),
    ]
}
