import Foundation
import AgentMasterCore

public enum ShimMode: String {
    case hook
    case statusline
}

/// Everything `agentmaster-hook` does, minus process I/O, so it can be unit tested.
/// Contract: never hang Claude Code; any failure prints nothing (hook) or the local status line
/// (the user's own, when they have one, else ours).
public enum HookShim {
    /// Below the 600 s hook timeout written into the session settings.
    public static let defaultDecisionTimeout: TimeInterval = 590

    /// Every PreToolUse waits for an answer: the policy rules (ADR 0017) may stop any tool call, and
    /// AskUserQuestion is answered from it. With nothing to say the app answers at once with no output.
    public static func isDecision(_ payload: JSONValue) -> Bool {
        switch payload["hook_event_name"]?.stringValue {
        case "PermissionRequest", "PreToolUse": return true
        default: return false
        }
    }

    public static func run(
        mode: ShimMode,
        input: Data,
        environment: [String: String],
        connector: WireConnector?,
        decisionTimeout: TimeInterval = defaultDecisionTimeout,
        userStatusLine: (Data, JSONValue) -> String? = { _, _ in nil },
        makeId: () -> String = { UUID().uuidString }
    ) -> String? {
        let payload = try? JSONValue.parse(input)
        // Evaluated after the app has been told, so a slow user script never delays the usage update.
        func fallback() -> String? {
            guard mode == .statusline else { return nil }
            return payload.flatMap { userStatusLine(input, $0) } ?? StatusLineFormatter.format(payload ?? .null)
        }
        guard let payload, let sessionId = environment["AGENTMASTER_SESSION_ID"], let connector else { return fallback() }

        let kind: WireKind = mode == .statusline ? .statusline : (isDecision(payload) ? .request : .event)
        let message = WireMessage(id: makeId(), sessionId: sessionId, kind: kind, payload: payload)
        do {
            // Encode before connecting, so the server's short read deadline covers only the transfer.
            let line = try WireCodec.encodeLine(message)
            let connection = try connector.connect()
            defer { connection.close() }
            try connection.send(line)
            guard kind == .request else { return fallback() }
            let reply = try connection.receiveReply(timeout: decisionTimeout)
            return reply.id == message.id ? reply.output : nil
        } catch {
            return fallback()
        }
    }
}
