import Foundation

public enum SessionStatus: Equatable, Sendable {
    case starting, idle, running, needsAttention, ended
}

/// Everything the panels show for one session. Pure value type; only `apply` mutates it.
public struct SessionState: Equatable, Sendable {
    public var status: SessionStatus = .starting
    public var claudeSessionId: String?
    public var cwd: String?
    public var transcriptPath: String?
    public var todos: [TodoItem] = []
    public var subagents: [SubagentInfo] = []
    public var changes: [FileChange] = []
    public var runningTools: [ToolCall] = []
    public var lastTool: ToolCall?
    public var usage: Usage?
    public var permissionMode: String?
    public var attentionMessage: String?
    public var lastMessage: String?
    public var endReason: String?

    public init() {}

    public mutating func apply(_ event: SessionEvent, at now: Date = Date()) {
        switch event {
        case let .sessionStarted(claudeSessionId, cwd, transcriptPath):
            if let current = self.claudeSessionId, current != claudeSessionId {
                // A new conversation in the same process (e.g. /clear): start the panels over.
                todos = []
                subagents = []
                changes = []
                runningTools = []
                lastTool = nil
                lastMessage = nil
            }
            self.claudeSessionId = claudeSessionId
            self.cwd = cwd
            self.transcriptPath = transcriptPath
            status = .idle
            attentionMessage = nil
            endReason = nil

        case .promptSubmitted:
            setStatus(.running)
            attentionMessage = nil

        case .toolStarted(let call):
            runningTools.removeAll { $0.id == call.id }
            runningTools.append(call)
            lastTool = call
            setStatus(.running)
            attentionMessage = nil

        case let .toolFinished(toolUseId, _, _):
            runningTools.removeAll { $0.id == toolUseId }
            if status == .needsAttention {
                setStatus(.running)
                attentionMessage = nil
            }

        case .fileChanged(let change):
            if let index = changes.firstIndex(where: { $0.path == change.path }) {
                changes[index].hunks += change.hunks
            } else {
                changes.append(change)
            }

        case .todosChanged(let items):
            todos = items

        case let .subagentStarted(agentId, agentType):
            if let index = subagentIndex(agentId) {
                subagents[index].type = agentType
            } else {
                subagents.append(SubagentInfo(id: agentId, type: agentType, startedAt: now))
            }

        case let .subagentDescribed(agentId, description, agentType):
            if let index = subagentIndex(agentId) {
                subagents[index].description = description
                if let agentType { subagents[index].type = agentType }
            } else {
                subagents.append(SubagentInfo(id: agentId, type: agentType ?? "agent", description: description, startedAt: now))
            }

        case .subagentFinished(let agentId):
            if let index = subagentIndex(agentId) {
                if subagents[index].finishedAt == nil { subagents[index].finishedAt = now }
            } else {
                subagents.append(SubagentInfo(id: agentId, type: "agent", startedAt: now, finishedAt: now))
            }

        case .permissionModeChanged(let mode):
            permissionMode = mode

        case .usageUpdated(let usage):
            self.usage = usage

        case .needsAttention(let message):
            setStatus(.needsAttention)
            attentionMessage = message

        case .turnFinished(let lastMessage):
            runningTools = []
            attentionMessage = nil
            if let lastMessage { self.lastMessage = lastMessage }
            setStatus(.idle)

        case .sessionEnded(let reason):
            runningTools = []
            attentionMessage = nil
            endReason = reason
            status = .ended
        }
    }

    /// `ended` is sticky; only `sessionStarted` (which assigns `status` directly) revives a session.
    private mutating func setStatus(_ newStatus: SessionStatus) {
        if status != .ended { status = newStatus }
    }

    private func subagentIndex(_ id: String) -> Int? {
        subagents.firstIndex { $0.id == id }
    }
}
