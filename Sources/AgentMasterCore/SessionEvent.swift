import Foundation

/// The only vocabulary the UI understands. Produced by the Bridge's HookTranslator.
public enum SessionEvent: Equatable, Sendable {
    case sessionStarted(claudeSessionId: String, cwd: String, transcriptPath: String?)
    case promptSubmitted(text: String)
    case toolStarted(ToolCall)
    case toolFinished(toolUseId: String, outcome: ToolOutcome, durationMs: Int?)
    case fileChanged(FileChange)
    case todosChanged([TodoItem])
    case subagentStarted(agentId: String, agentType: String)
    case subagentDescribed(agentId: String, description: String, agentType: String?)
    case subagentFinished(agentId: String)
    case permissionModeChanged(String)
    case usageUpdated(Usage)
    case needsAttention(message: String)
    case turnFinished(lastMessage: String?)
    case sessionEnded(reason: String?)
}
