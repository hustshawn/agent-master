import Foundation
import AgentMasterCore

/// The only place that understands Claude Code hook payloads. One instance per AgentMaster session.
public struct HookTranslator {
    private var sessionId: String?
    private var permissionMode: String?
    /// TaskCreate/TaskUpdate are deltas, so the full list is rebuilt here.
    private var todos: [TodoItem] = []

    public init() {}

    public mutating func translate(_ payload: JSONValue) -> [SessionEvent] {
        guard let event = payload["hook_event_name"]?.stringValue else { return [] }
        if let id = payload["session_id"]?.stringValue, id != sessionId {
            if sessionId != nil { todos = [] }   // new conversation in the same process (/clear)
            sessionId = id
        }

        var events: [SessionEvent] = []
        if let mode = payload["permission_mode"]?.stringValue, mode != permissionMode {
            permissionMode = mode
            events.append(.permissionModeChanged(mode))
        }

        switch event {
        case "SessionStart":
            events.append(.sessionStarted(claudeSessionId: sessionId ?? "", cwd: payload["cwd"]?.stringValue ?? "",
                                          transcriptPath: payload["transcript_path"]?.stringValue))
        case "UserPromptSubmit":
            events.append(.promptSubmitted(text: payload["prompt"]?.stringValue ?? ""))
        case "PreToolUse":
            if let id = payload["tool_use_id"]?.stringValue, let name = payload["tool_name"]?.stringValue {
                events.append(.toolStarted(ToolCall(id: id, name: name,
                                                    kind: ToolClassifier.kind(name: name, input: payload["tool_input"] ?? .null))))
            }
        case "PostToolUse":
            events += toolResultEvents(payload)
            if let id = payload["tool_use_id"]?.stringValue {
                events.append(.toolFinished(toolUseId: id, outcome: .success, durationMs: payload["duration_ms"]?.intValue))
            }
        case "PostToolUseFailure":
            if let id = payload["tool_use_id"]?.stringValue {
                events.append(.toolFinished(toolUseId: id, outcome: .failure(message: payload["error"]?.stringValue ?? "Failed"),
                                            durationMs: payload["duration_ms"]?.intValue))
            }
        case "PermissionRequest":
            let kind = ToolClassifier.kind(name: payload["tool_name"]?.stringValue ?? "tool", input: payload["tool_input"] ?? .null)
            events.append(.needsAttention(message: "Permission needed: " + kind.title))
        case "Notification":
            if payload["notification_type"]?.stringValue != "idle_prompt" {
                events.append(.needsAttention(message: payload["message"]?.stringValue ?? "Claude needs your attention"))
            }
        case "Stop":
            events.append(.turnFinished(lastMessage: payload["last_assistant_message"]?.stringValue))
        case "SubagentStart":
            if let id = payload["agent_id"]?.stringValue {
                events.append(.subagentStarted(agentId: id, agentType: payload["agent_type"]?.stringValue ?? "agent"))
            }
        case "SubagentStop":
            if let id = payload["agent_id"]?.stringValue {
                events.append(.subagentFinished(agentId: id))
            }
        case "SessionEnd":
            let reason = payload["reason"]?.stringValue
            if reason != "clear" { events.append(.sessionEnded(reason: reason)) }
        default:
            break
        }
        return events
    }

    public func translate(statusLine payload: JSONValue) -> [SessionEvent] {
        UsageParser.usage(from: payload).map { [.usageUpdated($0)] } ?? []
    }

    private mutating func toolResultEvents(_ payload: JSONValue) -> [SessionEvent] {
        let input = payload["tool_input"] ?? .null
        let response = payload["tool_response"] ?? .null
        switch payload["tool_name"]?.stringValue {
        case "TaskCreate":
            guard let id = Self.idString(response["task"]?["id"]) else { return [] }
            let subject = response["task"]?["subject"]?.stringValue ?? input["subject"]?.stringValue ?? ""
            todos.removeAll { $0.id == id }
            todos.append(TodoItem(id: id, subject: subject, status: .pending))
            return [.todosChanged(todos)]

        case "TaskUpdate":
            guard let id = Self.idString(input["taskId"]) ?? Self.idString(response["taskId"]) else { return [] }
            let rawStatus = input["status"]?.stringValue
            let status = rawStatus.flatMap(TodoStatus.init(rawValue:))
            if rawStatus == "deleted" {
                todos.removeAll { $0.id == id }
            } else if let index = todos.firstIndex(where: { $0.id == id }) {
                if let status { todos[index].status = status }
                if let subject = input["subject"]?.stringValue { todos[index].subject = subject }
            } else {
                // Created before AgentMaster was listening; keep a placeholder so progress still shows.
                todos.append(TodoItem(id: id, subject: input["subject"]?.stringValue ?? "Task \(id)", status: status ?? .pending))
            }
            return [.todosChanged(todos)]

        case "TodoWrite":
            let items = input["todos"]?.arrayValue ?? []
            todos = items.enumerated().map { index, item in
                TodoItem(id: "\(index + 1)", subject: item["content"]?.stringValue ?? "",
                         status: item["status"]?.stringValue.flatMap(TodoStatus.init(rawValue:)) ?? .pending)
            }
            return [.todosChanged(todos)]

        case "Edit", "MultiEdit", "Write":
            return PatchParser.change(fromToolResponse: response).map { [.fileChanged($0)] } ?? []

        case "Agent", "Task":
            guard let agentId = response["agentId"]?.stringValue else { return [] }
            let description = response["description"]?.stringValue ?? input["description"]?.stringValue ?? ""
            return [.subagentDescribed(agentId: agentId, description: description, agentType: input["subagent_type"]?.stringValue)]

        default:
            return []
        }
    }

    private static func idString(_ value: JSONValue?) -> String? {
        value?.stringValue ?? value?.intValue.map(String.init)
    }
}
