import SwiftUI
import AgentMasterCore
import AgentMasterBridge
import AgentMasterUI

/// Defaults for new sessions, one page per agent. Values live in UserDefaults via AgentPreferenceStore.
struct SettingsView: View {
    let model: AppModel
    @State private var preferences: [String: AgentPreferences] = [:]
    @AppStorage(GeneralSettings.restoreSessionsOnLaunchKey) private var restoreSessions = true
    @AppStorage(HotkeyMap.storageKey) private var hotkeys = HotkeyMap()
    @State private var switchProblem: String?
    private let store = AgentPreferenceStore(defaults: .standard)

    var body: some View {
        let environment = model.capturedEnvironment ?? ProcessInfo.processInfo.environment
        SettingsScreen(
            agents: AgentRegistry.all.map { agent in
                SettingsAgentPage(
                    id: agent.id, name: agent.displayName, glyph: agent.glyph,
                    location: agent.executable.locate(environment: environment).map(Self.abbreviatingHome),
                    missingHint: "Not found. Install \(agent.executable.name) or set \(agent.executable.overrideVariable).",
                    options: agent.options(environment: model.capturedEnvironment ?? [:]))
            },
            preferences: { preferences[$0] ?? store.preferences(for: $0) },
            isForcedOn: { agentId, optionId in
                AgentRegistry.agent(id: agentId)?.isForcedOn(
                    optionId: optionId, preferences: preferences[agentId] ?? store.preferences(for: agentId)) ?? false
            },
            onSet: { agentId, optionId, value in
                store.set(value, agentId: agentId, optionId: optionId)
                preferences[agentId] = store.preferences(for: agentId)
            }) {
            Section {
                Toggle(isOn: $restoreSessions) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Restore sessions on launch")
                        Text("Sessions open when AgentMaster quits come back, resuming their conversations.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                LabeledContent {
                    VStack(alignment: .trailing, spacing: 3) {
                        Picker("", selection: Binding(get: { hotkeys.switchModifiers }, set: setSwitchModifiers)) {
                            ForEach(HotkeyMap.switchModifierChoices, id: \.self) { Text($0.symbols + "1…9").tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        if let switchProblem {
                            Text(switchProblem).font(.caption).foregroundStyle(.orange)
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Switch to session 1…9")
                        Text("9 is the last session. Hold the modifiers to see each session's number.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(AppHotkeys.all) { action in
                    LabeledContent(action.title) {
                        HStack(spacing: 6) {
                            HotkeyRecorder(hotkey: hotkeys.hotkey(for: action),
                                           validate: { hotkeys.problem(with: $0, for: action.id, among: AppHotkeys.all) },
                                           onSet: { hotkeys.set($0, for: action.id) })
                            Button { hotkeys.reset(action.id) } label: { Image(systemName: "arrow.uturn.backward") }
                                .buttonStyle(.borderless)
                                .help("Restore \(action.defaultHotkey?.symbols ?? "no shortcut")")
                                .opacity(hotkeys.isCustomized(action.id) ? 1 : 0)
                                .disabled(!hotkeys.isCustomized(action.id))
                        }
                    }
                }
            } header: {
                Text("Keyboard shortcuts")
            } footer: {
                Text("Click a shortcut, then type the new one. Esc cancels, Delete removes it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func setSwitchModifiers(_ modifiers: Hotkey) {
        switchProblem = hotkeys.problem(with: modifiers, for: HotkeyMap.switchSessionId, among: AppHotkeys.all)
        if switchProblem == nil { hotkeys.set(modifiers, for: HotkeyMap.switchSessionId) }
    }

    private static func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
