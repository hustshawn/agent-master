import Foundation

/// One setting an agent exposes in Settings, declared as data so one generic view renders every agent.
public struct AgentOption: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// "Follow the agent's own settings" (no stored value) is always offered first by the UI.
        case choice([AgentChoice], allowsCustom: Bool)
        case toggle(default: Bool)
    }

    public let id: String
    public let title: String
    public let kind: Kind

    public init(id: String, title: String, kind: Kind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
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
