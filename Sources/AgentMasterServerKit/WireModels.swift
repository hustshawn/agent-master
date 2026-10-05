import Foundation
import AgentMasterCore
import AgentMasterBridge

// The JSON the browser reads. Built from Core's types here, so Core itself needs no Codable conformance.

public struct SessionJSON: Codable, Equatable, Sendable {
    public let id: String
    public let agentId: String
    public let agentName: String
    public let projectPath: String
    public let projectName: String
    public let title: String
    public let customName: String?
    public let subtitle: String
    public let status: String
    public let createdAt: Double
    /// When the agent last reported anything but usage.
    public let lastActivityAt: Double
    /// The user marked the last turn's result as reviewed.
    public let reviewed: Bool
    /// It has had a prompt, here or before a restore resumed it; an idle session without one has not started.
    public let hasConversation: Bool
    public let state: StateJSON
}

public struct StateJSON: Codable, Equatable, Sendable {
    public let status: String
    public let permissionMode: String?
    public let attentionMessage: String?
    public let lastMessage: String?
    public let firstPrompt: String?
    public let endReason: String?
    public let usage: UsageJSON?
    public let todos: [TodoJSON]
    public let subagents: [SubagentJSON]
    public let changes: [ChangeJSON]
    public let runningTools: [ToolJSON]
    public let lastTool: ToolJSON?

    init(_ state: SessionState) {
        status = state.status.name
        permissionMode = state.permissionMode
        attentionMessage = state.attentionMessage
        lastMessage = state.lastMessage
        firstPrompt = state.firstPrompt
        endReason = state.endReason
        usage = state.usage.map(UsageJSON.init)
        todos = state.todos.map { TodoJSON(id: $0.id, subject: $0.subject, status: $0.status.rawValue) }
        subagents = state.subagents.map {
            SubagentJSON(id: $0.id, type: $0.type, description: $0.description,
                         startedAt: $0.startedAt.timeIntervalSince1970, finishedAt: $0.finishedAt?.timeIntervalSince1970)
        }
        changes = state.changes.map(ChangeJSON.init)
        runningTools = state.runningTools.map(ToolJSON.init)
        lastTool = state.lastTool.map(ToolJSON.init)
    }
}

public struct UsageJSON: Codable, Equatable, Sendable {
    public let modelName: String
    public let contextUsedPercent: Int?
    public let inputTokens: Int
    public let outputTokens: Int
    public let costUSD: Double

    init(_ usage: Usage) {
        modelName = usage.modelName
        contextUsedPercent = usage.contextUsedPercent
        inputTokens = usage.inputTokens
        outputTokens = usage.outputTokens
        costUSD = usage.costUSD
    }
}

public struct TodoJSON: Codable, Equatable, Sendable {
    public let id: String
    public let subject: String
    public let status: String
}

public struct SubagentJSON: Codable, Equatable, Sendable {
    public let id: String
    public let type: String
    public let description: String?
    public let startedAt: Double
    public let finishedAt: Double?
}

public struct ToolJSON: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let title: String

    init(_ call: ToolCall) {
        id = call.id
        name = call.name
        title = call.kind.title
    }
}

public struct ChangeJSON: Codable, Equatable, Sendable {
    public struct Hunk: Codable, Equatable, Sendable {
        /// "@@ -a,b +c,d @@", or "@@" when the agent reports no line numbers (Codex).
        public let header: String
        public let lines: [Line]
    }

    public struct Line: Codable, Equatable, Sendable {
        /// "context", "added" or "removed".
        public let kind: String
        public let text: String
    }

    public let path: String
    public let added: Int
    public let removed: Int
    public let hunks: [Hunk]

    init(_ change: FileChange) {
        path = change.path
        added = change.added
        removed = change.removed
        hunks = change.hunks.map { hunk in
            Hunk(header: hunk.oldStart == 0 && hunk.newStart == 0 ? "@@"
                     : "@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@",
                 lines: hunk.lines.map { Line(kind: $0.kind.name, text: $0.text) })
        }
    }
}

public struct AgentJSON: Codable, Sendable {
    public struct Glyph: Codable, Sendable {
        /// "spark", "terminalPrompt" or "symbol".
        public let kind: String
        public let value: String?
    }

    public struct Option: Codable, Sendable {
        public let id: String
        public let title: String
        public let note: String?
        /// "choice" or "toggle".
        public let kind: String
        public let choices: [Choice]
        public let allowsCustom: Bool
        public let toggleDefault: Bool
    }

    public struct Choice: Codable, Sendable {
        public let value: String
        public let label: String
        public let detail: String?
    }

    public let id: String
    public let name: String
    public let glyph: Glyph
    /// Where the binary was found, or nil.
    public let location: String?
    public let missingHint: String
    public let options: [Option]
    public let preferences: [String: String]
    /// Toggles the current preferences force on.
    public let forcedOn: [String]
    public let defaultModel: String?
    /// Whether its sessions report usage at all, so the browser can tell "not yet" from "never".
    public let reportsUsage: Bool

    init(_ agent: any AgentKind, environment: [String: String], preferences: AgentPreferences) {
        id = agent.id
        reportsUsage = agent.reportsUsage
        name = agent.displayName
        switch agent.glyph {
        case .spark(let hex): glyph = Glyph(kind: "spark", value: hex)
        case .terminalPrompt: glyph = Glyph(kind: "terminalPrompt", value: nil)
        case .ghost(let hex): glyph = Glyph(kind: "ghost", value: hex)
        case .symbol(let name): glyph = Glyph(kind: "symbol", value: name)
        }
        location = agent.executable.locate(environment: environment)
        missingHint = "Not found. Install \(agent.executable.name) or set \(agent.executable.overrideVariable)."
        let declared = agent.options(environment: environment)
        options = declared.map { option in
            switch option.kind {
            case let .choice(choices, allowsCustom):
                return Option(id: option.id, title: option.title, note: option.note, kind: "choice",
                              choices: choices.map { Choice(value: $0.value, label: $0.label, detail: $0.detail) },
                              allowsCustom: allowsCustom, toggleDefault: false)
            case let .toggle(fallback):
                return Option(id: option.id, title: option.title, note: option.note, kind: "toggle", choices: [],
                              allowsCustom: false, toggleDefault: fallback)
            }
        }
        self.preferences = preferences.values
        forcedOn = declared.map(\.id).filter { agent.isForcedOn(optionId: $0, preferences: preferences) }
        defaultModel = preferences.string(AgentOption.modelId)
    }
}

extension SessionStatus {
    var name: String {
        switch self {
        case .starting: return "starting"
        case .idle: return "idle"
        case .running: return "running"
        case .needsAttention: return "needsAttention"
        case .ended: return "ended"
        }
    }
}

extension DiffLine.Kind {
    var name: String {
        switch self {
        case .context: return "context"
        case .added: return "added"
        case .removed: return "removed"
        }
    }
}

/// The second line of a sidebar row, as the Mac app words it.
enum RowText {
    static func subtitle(for state: SessionState, agentName: String?) -> String {
        let text: String
        switch state.status {
        case .starting: text = "starting"
        case .running: text = joined("running", state.runningTools.last?.name)
        case .needsAttention: text = joined("needs you", state.attentionMessage)
        case .idle: text = joined("idle", state.usage?.modelName)
        case .ended: text = "ended"
        }
        return agentName.map { "\($0) · \(text)" } ?? text
    }

    static func title(customName: String?, firstPrompt: String?) -> String {
        if let name = customName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if let prompt = firstPrompt, !prompt.isEmpty { return prompt }
        return "New session"
    }

    private static func joined(_ status: String, _ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return status }
        return "\(status) · \(detail)"
    }
}
