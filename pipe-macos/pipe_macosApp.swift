import SwiftUI

@main
struct pipe_macosApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("File") {
                Button("Open 3D Model...") {
                    NotificationCenter.default.post(name: .openModel, object: nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                
                Divider()
                
                Button("Save GCode...") {
                    NotificationCenter.default.post(name: .saveGCode, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }
}

extension Notification.Name {
    static let openModel = Notification.Name("openModel")
    static let saveGCode = Notification.Name("saveGCode")
    static let saveGCodePacks = Notification.Name("saveGCodePacks")
}
