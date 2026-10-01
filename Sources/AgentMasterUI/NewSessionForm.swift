import SwiftUI
import AgentMasterCore

/// An agent the sidebar can start a session with. The first one is the default.
public struct NewSessionAgent: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let glyph: AgentGlyphStyle
    public let modelChoices: [AgentChoice]
    public let allowsCustomModel: Bool
    /// The agent's default model from Settings; nil follows the agent's own configuration.
    public let defaultModel: String?

    public init(id: String, name: String, glyph: AgentGlyphStyle = .symbol("terminal"), modelChoices: [AgentChoice] = [],
                allowsCustomModel: Bool = true, defaultModel: String? = nil) {
        self.id = id
        self.name = name
        self.glyph = glyph
        self.modelChoices = modelChoices
        self.allowsCustomModel = allowsCustomModel
        self.defaultModel = defaultModel
    }
}

/// What the new-session popover asks for. A nil model means "use the agent's default".
public struct NewSessionRequest: Equatable {
    public let projectPath: String
    public let agentId: String
    public let model: String?
}

/// The floating panel behind every ＋: pick the agent, optionally a model other than its default, and the project.
/// A project row's ＋ preselects its project; the sidebar's bottom ＋ starts on the most recent one.
public struct NewSessionForm: View {
    let agents: [NewSessionAgent]
    let projects: [String]
    let chooseFolder: () -> String?
    let onStart: (NewSessionRequest) -> Void
    let onCancel: () -> Void

    @State private var agentId: String
    @State private var modelTag = AgentChoiceSelection.followTag
    @State private var customModel = ""
    @State private var project: String?

    public init(agents: [NewSessionAgent], initialProject: String?, projects: [String] = [],
                chooseFolder: @escaping () -> String? = { nil },
                onStart: @escaping (NewSessionRequest) -> Void, onCancel: @escaping () -> Void) {
        self.agents = agents
        self.projects = projects
        self.chooseFolder = chooseFolder
        self.onStart = onStart
        self.onCancel = onCancel
        _agentId = State(initialValue: agents.first?.id ?? "")
        _project = State(initialValue: initialProject ?? projects.first)
    }

    private var agent: NewSessionAgent? {
        agents.first { $0.id == agentId }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Session").font(.system(size: 22, weight: .semibold)).foregroundStyle(Palette.text)

            field("Agent") {
                HStack(spacing: 12) {
                    ForEach(agents) { agentCard($0) }
                }
            }

            if let agent { field("Model") { modelRows(agent) } }

            field("Project") { projectRow }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Start", action: start).keyboardShortcut(.defaultAction).disabled(project == nil)
            }
            .controlSize(.large)
        }
        .font(.system(size: 15))
        .padding(24)
        .frame(width: 480)
        .background(Palette.bg)
    }

    private func field(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
            content()
        }
    }

    private func agentCard(_ agent: NewSessionAgent) -> some View {
        let selected = agent.id == agentId
        return Button {
            guard agentId != agent.id else { return }
            agentId = agent.id
            modelTag = AgentChoiceSelection.followTag
            customModel = ""
        } label: {
            VStack(spacing: 10) {
                AgentGlyph(style: agent.glyph, size: 44)
                Text(agent.name).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.text)
                Text(agent.defaultModel ?? "default model").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Palette.selection : Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? Palette.accent : Color.white.opacity(0.08), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var projectRow: some View {
        HStack(spacing: 10) {
            Picker("", selection: $project) {
                if projects.isEmpty && project == nil { Text("None").tag(String?.none) }
                ForEach(projectOptions, id: \.self) { path in
                    Text((path as NSString).lastPathComponent).tag(Optional(path)).help(path)
                }
            }
            .labelsHidden()
            Button("Choose…") {
                if let path = chooseFolder() { project = path }
            }
        }
        .controlSize(.large)
    }

    /// Recent projects plus a folder picked with Choose…, which may not be recent yet.
    private var projectOptions: [String] {
        guard let project, !projects.contains(project) else { return projects }
        return [project] + projects
    }

    @ViewBuilder
    private func modelRows(_ agent: NewSessionAgent) -> some View {
        Picker("", selection: $modelTag) {
            Text("Default — \(agent.defaultModel ?? "\(agent.name) setting")").tag(AgentChoiceSelection.followTag)
            if !agent.modelChoices.isEmpty { Divider() }
            ForEach(agent.modelChoices, id: \.value) { choice in
                Text(choice.detail.map { "\(choice.label) — \($0)" } ?? choice.label).tag(choice.value)
            }
            if agent.allowsCustomModel {
                Divider()
                Text("Custom…").tag(AgentChoiceSelection.customTag)
            }
        }
        .labelsHidden()
        .controlSize(.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        if modelTag == AgentChoiceSelection.customTag {
            TextField("Model id", text: $customModel)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
        }
    }

    private func start() {
        guard let project, let agent else { return }
        onStart(NewSessionRequest(projectPath: project, agentId: agent.id, model: Self.model(tag: modelTag, custom: customModel)))
    }

    /// The model to launch with: nil for the default row or an empty custom field.
    static func model(tag: String, custom: String) -> String? {
        switch tag {
        case AgentChoiceSelection.followTag: return nil
        case AgentChoiceSelection.customTag:
            let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default: return tag
        }
    }
}
