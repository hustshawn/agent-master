import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor lazy var model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (`swift run AgentMaster`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model.shutdown() }
    }
}

@main
struct AgentMasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
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
