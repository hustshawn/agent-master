import Foundation

/// One setting an agent exposes in Settings, declared as data so one generic view renders every agent.
public struct AgentOption: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// "Follow the agent's own settings" (no stored value) is always offered first by the UI.
        case choice([AgentChoice], allowsCustom: Bool)
        case toggle(default: Bool)
    }

    /// The id every agent gives its default-model option, so a new session can override it without knowing the agent.
    public static let modelId = "model"

    public let id: String
    public let title: String
    public let kind: Kind
    /// A secondary line under the title, e.g. what turning a toggle on costs.
    public let note: String?

    public init(id: String, title: String, kind: Kind, note: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.note = note
    }
}

/// How an agent is drawn in the new-session panel. Outlines only, not the vendors' official artwork.
public enum AgentGlyphStyle: Equatable, Sendable {
    /// Rays around a centre in the given colour, like Claude's spark.
    case spark(hex: String)
    /// A `>_` prompt in a rounded square.
    case terminalPrompt
    /// A white ghost on a rounded square of the given colour, like Kiro's.
    case ghost(hex: String)
    /// An SF Symbol name.
    case symbol(String)
}

public struct AgentChoice: Equatable, Sendable {
    public let value: String
    public let label: String
    /// Secondary text, e.g. the model id an alias resolves to.
    public let detail: String?

    public init(value: String, label: String? = nil, detail: String? = nil) {
        self.value = value
        self.label = label ?? value
        self.detail = detail
    }
}

/// Stored values for one agent, keyed by option id. A missing value means "follow" (or the toggle default).
public struct AgentPreferences: Equatable, Sendable {
    public var values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public func string(_ id: String) -> String? {
        guard let value = values[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    public func bool(_ id: String, default fallback: Bool) -> Bool {
        switch string(id) {
        case "true": return true
        case "false": return false
        default: return fallback
        }
    }
}
