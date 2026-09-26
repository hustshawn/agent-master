import Foundation
import AgentMasterCore

/// Per-agent settings in UserDefaults under `agents.<agentId>.<optionId>`.
public struct AgentPreferenceStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public static func key(agentId: String, optionId: String) -> String {
        "agents.\(agentId).\(optionId)"
    }

    public func preferences(for agentId: String) -> AgentPreferences {
        let prefix = "agents.\(agentId)."
        var values: [String: String] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            if let text = value as? String { values[String(key.dropFirst(prefix.count))] = text }
        }
        return AgentPreferences(values: values)
    }

    /// nil or blank removes the value, which means "follow the agent's own settings".
    public func set(_ value: String?, agentId: String, optionId: String) {
        let key = Self.key(agentId: agentId, optionId: optionId)
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
