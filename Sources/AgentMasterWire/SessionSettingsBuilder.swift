import Foundation
import AgentMasterCore

/// The per-session `--settings` file. Claude Code merges it with the user's own settings
/// (verified on 2.1.283: user/project hooks keep firing alongside these).
public struct SessionSettingsBuilder {
    public static let hookEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "Notification", "Stop", "SubagentStart", "SubagentStop",
    ]
    public static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"]
    public static let decisionEvents: Set<String> = ["PreToolUse", "PermissionRequest"]
    /// Seconds. The shim gives up at 590 so it always answers before Claude Code kills it.
    public static let decisionTimeout = 600

    public let hookExecutable: String

    public init(hookExecutable: String) {
        self.hookExecutable = hookExecutable
    }

    public func command(_ subcommand: String) -> String {
        Self.shellQuote(hookExecutable) + " " + subcommand
    }

    public func settings() -> JSONValue {
        var hooks: [String: JSONValue] = [:]
        for event in Self.hookEvents {
            var hook: [String: JSONValue] = ["type": "command", "command": .string(command("hook"))]
            if Self.decisionEvents.contains(event) { hook["timeout"] = .number(Double(Self.decisionTimeout)) }
            var group: [String: JSONValue] = ["hooks": .array([.object(hook)])]
            if Self.toolEvents.contains(event) { group["matcher"] = "*" }
            hooks[event] = .array([.object(group)])
        }
        return [
            "hooks": .object(hooks),
            "statusLine": ["type": "command", "command": .string(command("statusline")), "padding": 0],
        ]
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(settings())
    }

    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
