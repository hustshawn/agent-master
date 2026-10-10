import SwiftUI
import AgentMasterBridge
import AgentMasterUI

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
    @AppStorage(InspectorSettings.collapsedKey) private var inspectorCollapsed = InspectorSettings.collapsedByDefault
    @AppStorage(HotkeyMap.storageKey) private var hotkeys = HotkeyMap()

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
                    .keyboardShortcut(hotkeys.hotkey(for: AppHotkeys.newSession)?.keyboardShortcut)
                Button("New Session in Folder…") { delegate.model.chooseProjectAndStart() }
                    .keyboardShortcut(hotkeys.hotkey(for: AppHotkeys.newSessionInFolder)?.keyboardShortcut)
                // Agents with a shortcut get their own menu item, which skips the new-session panel.
                ForEach(AgentRegistry.all.indices, id: \.self) { index in
                    let agent = AgentRegistry.all[index]
                    if let hotkey = hotkeys.hotkey(for: AppHotkeys.newAgentSession(agent)) {
                        Button("New \(agent.displayName) Session") { delegate.model.newSessionInCurrentProject(agent: agent) }
                            .keyboardShortcut(hotkey.keyboardShortcut)
                            .disabled(!delegate.model.isInstalled(agent))
                    }
                }
            }
            CommandGroup(after: .sidebar) {
                Button(inspectorCollapsed ? "Show Inspector" : "Hide Inspector") { inspectorCollapsed.toggle() }
                    .keyboardShortcut(hotkeys.hotkey(for: AppHotkeys.toggleInspector)?.keyboardShortcut)
                Button("Summarize Session") { delegate.model.selectedId.map(delegate.model.summarize) }
                    .keyboardShortcut(hotkeys.hotkey(for: AppHotkeys.summarize)?.keyboardShortcut)
                    .disabled(delegate.model.selectedId == nil)
            }
            CommandGroup(replacing: .saveItem) {
                // In the main window ⌘W closes the selected session; elsewhere (Settings) it closes the window.
                // SwiftUI autosaves the `Window(id: "main")` frame under the scene id.
                Button("Close") {
                    let inMain = NSApp.keyWindow?.frameAutosaveName == "main"
                    if !(inMain && delegate.model.closeSelected()) { NSApp.keyWindow?.performClose(nil) }
                }
                .keyboardShortcut(hotkeys.hotkey(for: AppHotkeys.closeSession)?.keyboardShortcut)
            }
        }

        Settings {
            SettingsView(model: delegate.model)
                .preferredColorScheme(.dark)
        }
    }
}
