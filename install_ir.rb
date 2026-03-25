require 'fileutils'

ir_dir = 'pipe-macos/IR'
FileUtils.mkdir_p(ir_dir)

# Create the Swift files
File.write(File.join(ir_dir, 'MachineCommand.swift'), <<~SWIFT)
import Foundation

enum MachineCommand: Equatable {
    case rapid(x: CGFloat?, y: CGFloat?, z: CGFloat?, a: CGFloat?)
    case cut(x: CGFloat, y: CGFloat, z: CGFloat, a: CGFloat, feed: CGFloat, segment: TrajectorySegment?)
    case setPosition(x: CGFloat?, y: CGFloat?, z: CGFloat?, a: CGFloat?)
    case retract(z: CGFloat)
    case torchOn
    case torchOff
    case setTHCOn
    case setTHCOff(isCorner: Bool)
    case cancelCutterComp
    case cancelToolOffset
    case absoluteMode
    case unitMode(inches: Bool)
    case programEnd
    case comment(String)
    case blank
    case raw(String)
}
SWIFT

File.write(File.join(ir_dir, 'GCodeFormatter.swift'), <<~SWIFT)
import Foundation

struct GCodeFormatter {
    var settings: GCodeSettings
    
    private var unitLabel: String { settings.units == .inches ? "in" : "mm" }
    private var unitModeWord: String { settings.units == .inches ? "G20" : "G21" }
    private var unitModeComment: String { settings.units == .inches ? "inch mode" : "metric mode" }
    
    private func fmt(_ val: CGFloat) -> String { String(format: "%.3f", val) }
    
    private func fmtU(_ val: CGFloat) -> String {
        settings.units == .inches ? String(format: "%.4f", val / 25.4) : String(format: "%.3f", val)
    }
    
    private func fmtF(_ val: CGFloat, segment: TrajectorySegment?) -> String {
        var rate = val
        if settings.units == .inches {
            if settings.useSimCNC, let seg = segment, seg.dMachine > 1e-9 {
                rate = val * sqrt(pow(seg.dXm / 25.4, 2) + pow(seg.dYm / 25.4, 2) + pow(seg.dZm / 25.4, 2) + pow(seg.dAm, 2)) / seg.dMachine
            } else {
                rate = val / 25.4
            }
        }
        return String(format: "%.3f", rate)
    }
    
    func format(_ commands: [MachineCommand]) -> [String] {
        return commands.compactMap { formatSingle($0) }
    }
    
    private func formatSingle(_ cmd: MachineCommand) -> String? {
        switch cmd {
        case .rapid(let x, let y, let z, let a):
            var parts = ["G0"]
            if let x = x { parts.append("X\\(fmtU(x))") }
            if let y = y { parts.append("Y\\(fmtU(y))") }
            if let z = z { parts.append("Z\\(fmtU(z))") }
            if let a = a { parts.append("A\\(fmt(a))") }
            return parts.joined(separator: " ")
            
        case .cut(let x, let y, let z, let a, let feed, let segment):
            return "G1 X\\(fmtU(x)) Y\\(fmtU(y)) Z\\(fmtU(z)) A\\(fmt(a)) F\\(fmtF(feed, segment: segment))"
            
        case .setPosition(let x, let y, let z, let a):
            var parts = ["G92"]
            if let x = x { parts.append("X\\(fmtU(x))") }
            if let y = y { parts.append("Y\\(fmtU(y))") }
            if let z = z { parts.append("Z\\(fmtU(z))") }
            if let a = a { parts.append("A\\(fmt(a))") }
            return parts.joined(separator: " ")
            
        case .retract(let z):
            return "G0 Z\\(fmtU(z))"
            
        case .torchOn:
            return "M3 S1"
            
        case .torchOff:
            return "M5"
            
        case .setTHCOn:
            return "#4061 = #50"
            
        case .setTHCOff(let isCorner):
            if isCorner {
                return "#50 = #4061                  ; THC OFF (Corner Lock)\\n#4061 = 100                  ; THC OFF (Corner Lock)"
            } else {
                return "#50 = #4061\\n#4061 = 100"
            }
            
        case .cancelCutterComp:
            return "G40"
            
        case .cancelToolOffset:
            return "G49"
            
        case .absoluteMode:
            return "G90"
            
        case .unitMode(let inches):
            let mode = inches ? "G20" : "G21"
            let comment = inches ? "inch mode" : "metric mode"
            return "\\(mode) ; \\(comment)"
            
        case .programEnd:
            return "M30"
            
        case .comment(let text):
            return "; \\(text)"
            
        case .blank:
            return ""
            
        case .raw(let str):
            return str
        }
    }
}
SWIFT

# Read the original GCodeGenerator.swift to duplicate it into IRGCodeGenerator.swift
original = File.read('pipe-macos/GCodeGenerator.swift')

# Quick find/replace to bootstrap IRGCodeGenerator
ir_gen = original.gsub('class GCodeGenerator', 'class IRGCodeGenerator')
# Keep structs like PackEntry, GlobalFeature, etc. out if they are already defined in GCodeGenerator.swift
# We'll just append IRGCodeGenerator to the same file for now to avoid target integration issues,
# but the user requested a separate implementation. Let's just create IRGCodeGenerator.swift and add it to the project!

# Actually, the most foolproof way to not break xcodeproj is to run `gem install xcodeproj` and use it.
