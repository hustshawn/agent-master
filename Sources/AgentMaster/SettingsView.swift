import SwiftUI
import AgentMasterCore
import AgentMasterBridge
import AgentMasterUI

/// Defaults for new sessions, one page per agent. Values live in UserDefaults via AgentPreferenceStore.
struct SettingsView: View {
    let model: AppModel
    @State private var preferences: [String: AgentPreferences] = [:]
    @AppStorage(GeneralSettings.restoreSessionsOnLaunchKey) private var restoreSessions = true
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
        }
    }

    private static func abbreviatingHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
