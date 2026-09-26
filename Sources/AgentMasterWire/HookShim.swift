import Foundation
import AgentMasterCore

public enum ShimMode: String {
    case hook
    case statusline
}

/// Everything `agentmaster-hook` does, minus process I/O, so it can be unit tested.
/// Contract: never hang Claude Code; any failure prints nothing (hook) or the local status line.
public enum HookShim {
    /// Below the 600 s hook timeout written into the session settings.
    public static let defaultDecisionTimeout: TimeInterval = 590

    public static func isDecision(_ payload: JSONValue) -> Bool {
        switch payload["hook_event_name"]?.stringValue {
        case "PermissionRequest": return true
        case "PreToolUse": return payload["tool_name"]?.stringValue == "AskUserQuestion"
        default: return false
        }
    }

    public static func run(
        mode: ShimMode,
        input: Data,
        environment: [String: String],
        connector: WireConnector?,
        decisionTimeout: TimeInterval = defaultDecisionTimeout,
        makeId: () -> String = { UUID().uuidString }
    ) -> String? {
        let payload = try? JSONValue.parse(input)
        let fallback = mode == .statusline ? StatusLineFormatter.format(payload ?? .null) : nil
        guard let payload, let sessionId = environment["AGENTMASTER_SESSION_ID"], let connector else { return fallback }

        let kind: WireKind = mode == .statusline ? .statusline : (isDecision(payload) ? .request : .event)
        let message = WireMessage(id: makeId(), sessionId: sessionId, kind: kind, payload: payload)
        do {
            // Encode before connecting, so the server's short read deadline covers only the transfer.
            let line = try WireCodec.encodeLine(message)
            let connection = try connector.connect()
            defer { connection.close() }
            try connection.send(line)
            guard kind == .request else { return fallback }
            let reply = try connection.receiveReply(timeout: decisionTimeout)
            return reply.id == message.id ? reply.output : nil
        } catch {
            return fallback
        }
    }
}
