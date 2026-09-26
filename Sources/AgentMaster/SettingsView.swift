import SwiftUI
import AgentMasterCore
import AgentMasterBridge
import AgentMasterUI

/// Defaults for new sessions, one section per agent. Values live in UserDefaults via AgentPreferenceStore.
struct SettingsView: View {
    let model: AppModel
    @State private var preferences: [String: AgentPreferences] = [:]
    @AppStorage(GeneralSettings.restoreSessionsOnLaunchKey) private var restoreSessions = true
    private let store = AgentPreferenceStore(defaults: .standard)

    var body: some View {
        Form {
            ForEach(AgentRegistry.all, id: \.id) { agent in
                let prefs = preferences[agent.id] ?? store.preferences(for: agent.id)
                AgentOptionsView(
                    title: agent.displayName,
                    options: agent.options(environment: model.capturedEnvironment ?? [:]),
                    preferences: prefs,
                    isForcedOn: { agent.isForcedOn(optionId: $0, preferences: prefs) },
                    onSet: { optionId, value in
                        store.set(value, agentId: agent.id, optionId: optionId)
                        preferences[agent.id] = store.preferences(for: agent.id)
                    })
            }
            Section("General") {
                Toggle("Restore sessions on launch", isOn: $restoreSessions)
            }
            Section {
                Text("Applies to new sessions. Running sessions keep their settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}
