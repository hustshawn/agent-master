import Foundation
import AgentMasterCore

/// How one agent's hook payloads differ from Claude Code's, which HookTranslator reads.
public protocol HookDialect: Sendable {
    /// Rewrites a payload into Claude Code's shape: event names, tool names, field names.
    func normalize(_ payload: JSONValue) -> JSONValue
    /// Edits this agent reports in a way the Claude-shaped Edit/Write PostToolUse cannot carry.
    func fileChanges(in payload: JSONValue) -> [FileChange]
}

extension HookDialect {
    public func normalize(_ payload: JSONValue) -> JSONValue { payload }
    public func fileChanges(in payload: JSONValue) -> [FileChange] { [] }
}

/// Claude Code's payloads are the reference shape.
public struct ClaudeHookDialect: HookDialect {
    public init() {}
}
