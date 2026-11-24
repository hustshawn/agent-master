import SwiftUI
import AgentMasterCore
import AgentMasterBridge
import AgentMasterUI

/// Defaults for new sessions, one page per agent. Values live in UserDefaults via AgentPreferenceStore.
struct SettingsView: View {
    let model: AppModel
    @State private var preferences: [String: AgentPreferences] = [:]
    @AppStorage(GeneralSettings.restoreSessionsOnLaunchKey) private var restoreSessions = true
    @AppStorage(GeneralSettings.aiSessionTitlesKey) private var aiSessionTitles = true
    @AppStorage(HotkeyMap.storageKey) private var hotkeys = HotkeyMap()
    @State private var switchProblem: String?
    @State private var policies = GeneralSettings.policies(.standard)
    /// As typed, blank lines included; saved as the patterns without them.
    @State private var patternsText = GeneralSettings.policies(.standard).dangerousBash.patterns.joined(separator: "\n")
    private let store = AgentPreferenceStore(defaults: .standard)

    var body: some View {
        let environment = model.capturedEnvironment ?? ProcessInfo.processInfo.environment
        SettingsScreen(
            agents: AgentRegistry.all.map { agent in
                SettingsAgentPage(
                    id: agent.id, name: agent.displayName, glyph: agent.glyph,
                    location: agent.executable.locate(environment: environment).map(Self.abbreviatingHome),
                    missingHint: "Not found. Install \(agent.executable.name) or set \(agent.executable.overrideVariable).",
                    options: agent.options(environment: model.capturedEnvironment ?? [:], models: model.modelCatalog[agent.id]))
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
                Toggle(isOn: $aiSessionTitles) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AI session titles")
                        Text("After a session's first turn, Claude Haiku names it from the prompt and the reply. Needs Claude Code.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } policies: {
            policySections
        } shortcuts: {
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
            } footer: {
                Text("Click a shortcut, then type the new one. Esc cancels, Delete removes it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The Policies page (ADR 0017): stored as one JSON value under the server's key name.
    @ViewBuilder
    private var policySections: some View {
        Section {
            policyNumber("Ask when a session costs (USD)",
                         note: "Asked once per session. Claude Code only: Codex and Kiro report no cost. The cost can lag one turn behind.",
                         value: \.cost.askAtUSD)
            policyNumber("Deny when a session costs (USD)", note: "Every tool call is denied from here on.",
                         value: \.cost.denyAtUSD)
            LabeledContent {
                // Commits on Return or leaving the field; blank turns the rule off.
                TextField("Off", value: Binding(
                    get: { policies.maxToolCalls },
                    set: { value in updatePolicies { $0.maxToolCalls = value.flatMap { $0 > 0 ? $0 : nil } } }),
                          format: .number)
                    .frame(width: 90).multilineTextAlignment(.trailing)
            } label: {
                settingLabel("Ask after tool calls", note: "Per session; allowing lets as many more through.")
            }
        }
        Section {
            Toggle(isOn: Binding(get: { policies.dangerousBash.enabled },
                                 set: { value in updatePolicies { $0.dangerousBash.enabled = value } })) {
                settingLabel("Ask before dangerous commands",
                             note: "Built-in checks for rm -rf, forced pushes, git reset --hard, terraform apply, kubectl delete, DROP TABLE, curl piped to a shell and similar, plus your own patterns below. They read the command text, so eval, variables or a script get past them: a guard rail, not a sandbox. Not for Kiro, whose hooks cannot stop a call. In Codex, a call nobody answers is denied.")
            }
            TextEditor(text: $patternsText)
                .font(.system(size: 11, design: .monospaced))
                .frame(minHeight: 140)
                .onChange(of: patternsText) { _, text in
                    updatePolicies { policies in
                        policies.dangerousBash.patterns = text.split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                }
        } footer: {
            Text("Your own patterns: regular expressions, one per line, matched without regard to case against each command of the call. Changes apply from the next tool call.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func updatePolicies(_ change: (inout PolicySettings) -> Void) {
        change(&policies)
        GeneralSettings.setPolicies(policies, .standard)
    }

    private func settingLabel(_ title: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// A dollar amount; blank turns the rule off.
    private func policyNumber(_ title: String, note: String, value: WritableKeyPath<PolicySettings, Double?>) -> some View {
        LabeledContent {
            TextField("Off", value: Binding(
                get: { policies[keyPath: value] },
                set: { amount in updatePolicies { $0[keyPath: value] = amount.flatMap { $0 >= 0 ? $0 : nil } } }),
                      format: .number)
                .frame(width: 90).multilineTextAlignment(.trailing)
        } label: {
            settingLabel(title, note: note)
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
