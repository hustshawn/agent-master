import SwiftUI
import AgentMasterCore

/// Which picker row a stored value selects.
public enum AgentChoiceSelection {
    public static let followTag = ""
    /// Starts with NUL so it can never equal a real option value.
    public static let customTag = "\u{0}custom"

    public static func tag(for value: String?, choices: [AgentChoice], allowsCustom: Bool, customActive: Bool) -> String {
        if allowsCustom && customActive { return customTag }
        if let value, choices.contains(where: { $0.value == value }) { return value }
        if allowsCustom && (value != nil || customActive) { return customTag }
        return followTag
    }
}

/// Renders one agent's declared options as a Form section. Storage stays with the caller:
/// `onSet(optionId, nil)` clears a value, which means "follow the agent's own settings".
public struct AgentOptionsView: View {
    let title: String
    let sectionTitle: String?
    let options: [AgentOption]
    let preferences: AgentPreferences
    let isForcedOn: (String) -> Bool
    let onSet: (String, String?) -> Void
    /// Options whose Custom… row is picked while the text field is still empty.
    @State private var customActive: Set<String> = []

    /// `title` is the agent's name, used in "Follow <title> settings"; `sectionTitle` heads the section (nil for none).
    public init(title: String, sectionTitle: String? = nil, options: [AgentOption], preferences: AgentPreferences,
                isForcedOn: @escaping (String) -> Bool, onSet: @escaping (String, String?) -> Void) {
        self.title = title
        self.sectionTitle = sectionTitle
        self.options = options
        self.preferences = preferences
        self.isForcedOn = isForcedOn
        self.onSet = onSet
    }

    public var body: some View {
        Section {
            ForEach(options, id: \.id) { option in
                switch option.kind {
                case let .choice(choices, allowsCustom):
                    choiceRow(option, choices: choices, allowsCustom: allowsCustom)
                case let .toggle(fallback):
                    toggleRow(option, fallback: fallback)
                }
            }
        } header: {
            if let sectionTitle { Text(sectionTitle) }
        }
    }

    private func label(_ option: AgentOption) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(option.title)
            if let note = option.note {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func choiceRow(_ option: AgentOption, choices: [AgentChoice], allowsCustom: Bool) -> some View {
        let selection = Binding<String>(
            get: {
                AgentChoiceSelection.tag(for: preferences.string(option.id), choices: choices,
                                         allowsCustom: allowsCustom, customActive: customActive.contains(option.id))
            },
            set: { tag in
                if tag == AgentChoiceSelection.customTag {
                    customActive.insert(option.id)
                } else {
                    customActive.remove(option.id)
                    onSet(option.id, tag.isEmpty ? nil : tag)
                }
            })
        Picker(selection: selection) {
            Text("Follow \(title) settings").tag(AgentChoiceSelection.followTag)
            if !choices.isEmpty { Divider() }
            ForEach(choices, id: \.value) { choice in
                // macOS menu items are plain text, so the detail rides along after a dash.
                Text(choice.detail.map { "\(choice.label) — \($0)" } ?? choice.label).tag(choice.value)
            }
            if allowsCustom {
                Divider()
                Text("Custom…").tag(AgentChoiceSelection.customTag)
            }
        } label: {
            label(option)
        }
        if selection.wrappedValue == AgentChoiceSelection.customTag {
            TextField("Custom \(option.title.lowercased())", text: Binding(
                get: { preferences.values[option.id] ?? "" },
                set: {
                    customActive.insert(option.id)
                    onSet(option.id, $0.isEmpty ? nil : $0)
                }))
        }
    }

    private func toggleRow(_ option: AgentOption, fallback: Bool) -> some View {
        let forced = isForcedOn(option.id)
        return Toggle(isOn: Binding(
            get: { forced || preferences.bool(option.id, default: fallback) },
            set: { onSet(option.id, $0 ? "true" : "false") })) {
            label(option)
        }
        .disabled(forced)
    }
}
