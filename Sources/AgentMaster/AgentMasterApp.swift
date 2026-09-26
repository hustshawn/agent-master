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
                Button("New Session…") { delegate.model.chooseProjectAndStart() }
                    .keyboardShortcut("n")
            }
        }
    }
}
