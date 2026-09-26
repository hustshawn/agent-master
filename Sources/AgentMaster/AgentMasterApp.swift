import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor lazy var model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (`swift run AgentMaster`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A lone `Window` scene quits the app when closed, which would kill every running claude session.
    /// Keep running; the window is reopened from the Dock or the Window menu.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model.shutdown() }
    }
}

@main
struct AgentMasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // A single Window, not a WindowGroup: there is one terminal NSView per session, and a second
        // window (tab bar "+", state restoration) would reparent it away from the first.
        Window("AgentMaster", id: "main") {
            MainWindow(model: delegate.model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") { delegate.model.newSessionInCurrentProject() }
                    .keyboardShortcut("n")
                Button("New Session in Folder…") { delegate.model.chooseProjectAndStart() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                // In the main window ⌘W closes the selected session; elsewhere (Settings) it closes the window.
                // SwiftUI autosaves the `Window(id: "main")` frame under the scene id.
                Button("Close") {
                    let inMain = NSApp.keyWindow?.frameAutosaveName == "main"
                    if !(inMain && delegate.model.closeSelected()) { NSApp.keyWindow?.performClose(nil) }
                }
                .keyboardShortcut("w")
            }
        }

        Settings {
            SettingsView(model: delegate.model)
                .preferredColorScheme(.dark)
        }
    }
}
