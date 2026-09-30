import SwiftUI
import AgentMasterCore

/// One agent's page in Settings, built by the app from the agent registry.
public struct SettingsAgentPage: Identifiable {
    public let id: String
    public let name: String
    public let glyph: AgentGlyphStyle
    /// Where the binary was found, or nil when it was not.
    public let location: String?
    /// What to do when it was not found.
    public let missingHint: String
    public let options: [AgentOption]

    public init(id: String, name: String, glyph: AgentGlyphStyle, location: String?, missingHint: String,
                options: [AgentOption]) {
        self.id = id
        self.name = name
        self.glyph = glyph
        self.location = location
        self.missingHint = missingHint
        self.options = options
    }
}

/// Settings as a sidebar of pages: General first, then one page per agent. Storage stays with the caller.
public struct SettingsScreen<General: View>: View {
    static var generalId: String { "\u{0}general" }

    let agents: [SettingsAgentPage]
    let preferences: (String) -> AgentPreferences
    let isForcedOn: (_ agentId: String, _ optionId: String) -> Bool
    let onSet: (_ agentId: String, _ optionId: String, _ value: String?) -> Void
    let general: General
    @State private var selection: String

    public init(agents: [SettingsAgentPage], preferences: @escaping (String) -> AgentPreferences,
                isForcedOn: @escaping (String, String) -> Bool, onSet: @escaping (String, String, String?) -> Void,
                initialSelection: String? = nil, @ViewBuilder general: () -> General) {
        self.agents = agents
        self.preferences = preferences
        self.isForcedOn = isForcedOn
        self.onSet = onSet
        self.general = general()
        _selection = State(initialValue: initialSelection ?? agents.first?.id ?? Self.generalId)
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
            detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 760, height: 520)
        .background(Palette.bg)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("AGENTS").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.faint)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 4)
            ForEach(agents) { agent in
                sidebarRow(agent.id) {
                    AgentGlyph(style: agent.glyph, size: 18)
                    Text(agent.name)
                }
            }
            Spacer().frame(height: 14)
            sidebarRow(Self.generalId) {
                Image(systemName: "gearshape").font(.system(size: 14)).foregroundStyle(Palette.muted).frame(width: 18)
                Text("General")
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 200)
        .background(Color.white.opacity(0.02))
    }

    private func sidebarRow(_ id: String, @ViewBuilder content: () -> some View) -> some View {
        Button { selection = id } label: {
            HStack(spacing: 10) { content() }
                .font(.system(size: 14, weight: selection == id ? .semibold : .regular))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7).fill(selection == id ? Palette.selection : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()   // the selection is shown already; the ring landed on the first row on open
    }

    @ViewBuilder
    private var detail: some View {
        if let agent = agents.first(where: { $0.id == selection }) {
            page(agent)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                pageHeader { Image(systemName: "gearshape").font(.system(size: 30)).foregroundStyle(Palette.muted) }
                    title: { "General" } subtitle: { Text("AgentMaster itself").foregroundStyle(Palette.muted) }
                Form { general }.formStyle(.grouped).scrollContentBackground(.hidden)
            }
        }
    }

    private func page(_ agent: SettingsAgentPage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            pageHeader { AgentGlyph(style: agent.glyph, size: 40) } title: { agent.name } subtitle: {
                if let location = agent.location {
                    Label(location, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Palette.muted)
                        .labelStyle(StatusLabelStyle(tint: Palette.success))
                } else {
                    Label(agent.missingHint, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warning)
                        .labelStyle(StatusLabelStyle(tint: Palette.warning))
                }
            }
            let prefs = preferences(agent.id)
            Form {
                AgentOptionsView(title: agent.name, sectionTitle: "Defaults for new sessions", options: agent.options,
                                 preferences: prefs, isForcedOn: { isForcedOn(agent.id, $0) },
                                 onSet: { onSet(agent.id, $0, $1) })
                Section {
                    Text("Applies to new sessions. Running sessions keep their settings. Each new session can still pick another model.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            // Picker state lives in AgentOptionsView; a new agent gets a fresh one.
            .id(agent.id)
        }
    }

    private func pageHeader(@ViewBuilder icon: () -> some View, title: () -> String,
                            @ViewBuilder subtitle: () -> some View) -> some View {
        HStack(spacing: 14) {
            icon()
            VStack(alignment: .leading, spacing: 4) {
                Text(title()).font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.text)
                subtitle().font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 4)
    }
}

private struct StatusLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}
