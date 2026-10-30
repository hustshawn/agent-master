import Foundation

public enum SessionStatus: Equatable, Sendable {
    case starting, idle, running, needsAttention, ended

    /// Closing kills claude mid-turn; ask first. The transcript survives either way (`claude --resume`).
    public var needsCloseConfirmation: Bool { self == .running || self == .needsAttention }
}

/// Everything the panels show for one session. Pure value type; only `apply` mutates it.
public struct SessionState: Equatable, Sendable {
    public var status: SessionStatus = .starting
    public var agentSessionId: String?
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
    /// The first real prompt of this conversation (slash commands skipped); names the session by default.
    public var firstPrompt: String?
    public var endReason: String?
    /// When a prompt was last sent, the agent last asked for the user, or a turn last finished. Tool calls and
    /// the status line don't count, so two running sessions don't keep swapping places in the sidebar.
    public var lastActivityAt: Date?

    public init() {}

    /// The first non-blank line of a prompt, or nil for blank prompts and slash commands.
    static func titleLine(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }
        return trimmed.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    public mutating func apply(_ event: SessionEvent, at now: Date = Date()) {
        switch event {
        case let .sessionStarted(agentSessionId, cwd, transcriptPath):
            if let current = self.agentSessionId, current != agentSessionId {
                // A new conversation in the same process (e.g. /clear): start the panels over.
                todos = []
                subagents = []
                changes = []
                runningTools = []
                lastTool = nil
                lastMessage = nil
                firstPrompt = nil
            }
            self.agentSessionId = agentSessionId
            self.cwd = cwd
            self.transcriptPath = transcriptPath
            status = .idle
            attentionMessage = nil
            endReason = nil

        case .promptSubmitted(let text):
            if firstPrompt == nil, let line = Self.titleLine(text) { firstPrompt = line }
            setStatus(.running)
            attentionMessage = nil
            lastActivityAt = now

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
            lastActivityAt = now

        case .turnFinished(let lastMessage):
            runningTools = []
            attentionMessage = nil
            if let lastMessage { self.lastMessage = lastMessage }
            setStatus(.idle)
            lastActivityAt = now

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
