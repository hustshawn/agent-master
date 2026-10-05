import Foundation
import AgentMasterCore
import AgentMasterBridge

/// A hook request (an approval or a question) waiting for, or answered by, the user in a browser.
public struct ActionRequestJSON: Codable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    /// "permission" or "question".
    public let kind: String
    public let toolName: String
    /// What the tool would do, as the panels word it ("Run swift test").
    public let title: String
    /// The tool's input; for a question, `questions` holds what to show.
    public let input: JSONValue
    public let createdAt: Double
    /// When the request answers itself with a deny, below the hook's own timeout.
    public let expiresAt: Double
    /// "pending", "answered" or "expired".
    public var status: String
    /// How it ended: "allowed", "denied", "answered", "timed out" or why it went away.
    public var outcome: String?
    public var resolvedAt: Double?
}

public enum ActionRequestError: Error, CustomStringConvertible {
    case unknown(String)
    /// Answered elsewhere first, or expired.
    case notPending(ActionRequestJSON)
    case unsupportedDecision

    public var description: String {
        switch self {
        case .unknown(let id): return "Unknown request \(id)."
        case .notPending(let request): return "This request was already \(request.outcome ?? request.status)."
        case .unsupportedDecision: return "That answer does not fit this request."
        }
    }
}

/// The open hook requests and the recently resolved ones. Requests live in memory only: the hook that
/// waits on one is a process of the agent, so neither outlives a server restart. The first answer wins.
final class ActionRequestStore: @unchecked Sendable {
    /// Told to the agent when nobody answers in time, so it stops and waits instead of guessing.
    static let awayMessage = "The user is away and did not answer in time. Stop here and wait for their next instruction."
    /// Resolved requests kept so every browser can show how one ended.
    static let resolvedLimit = 100

    private struct Pending {
        var request: ActionRequestJSON
        let payload: JSONValue
        let agent: any AgentKind
        let reply: (String?) -> Void
    }

    /// Below HookShim.defaultDecisionTimeout (590 s), so the agent gets the deny rather than a silent timeout.
    let timeout: TimeInterval
    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    private var resolved: [ActionRequestJSON] = []
    var onChange: (@Sendable (ActionRequestJSON) -> Void)?

    init(timeout: TimeInterval = 580) {
        self.timeout = timeout
    }

    var all: [ActionRequestJSON] {
        lock.lock()
        defer { lock.unlock() }
        return resolved + pending.values.map(\.request).sorted { $0.createdAt < $1.createdAt }
    }

    func open(sessionId: String, agent: any AgentKind, payload: JSONValue,
              reply: @escaping (String?) -> Void) -> ActionRequestJSON {
        let now = Date()
        let toolName = payload["tool_name"]?.stringValue ?? "tool"
        let input = payload["tool_input"] ?? .null
        let request = ActionRequestJSON(
            id: UUID().uuidString, sessionId: sessionId,
            kind: payload["hook_event_name"]?.stringValue == "PermissionRequest" ? "permission" : "question",
            toolName: toolName, title: ToolClassifier.kind(name: toolName, input: input).title, input: input,
            createdAt: now.timeIntervalSince1970, expiresAt: now.addingTimeInterval(timeout).timeIntervalSince1970,
            status: "pending")
        lock.lock()
        pending[request.id] = Pending(request: request, payload: payload, agent: agent, reply: reply)
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.resolve(request.id, decision: .deny(message: Self.awayMessage, interrupt: true), outcome: "timed out",
                          status: "expired")
        }
        onChange?(request)
        return request
    }

    @discardableResult
    func answer(_ id: String, decision: RemoteDecision) throws -> ActionRequestJSON {
        let outcome: String
        switch decision {
        case .allow: outcome = "allowed"
        case .deny: outcome = "denied"
        case .answer: outcome = "answered"
        }
        if let request = resolve(id, decision: decision, outcome: outcome, status: "answered") { return request }
        lock.lock()
        let found = resolved.last { $0.id == id }
        let stillPending = pending[id] != nil
        lock.unlock()
        if let found { throw ActionRequestError.notPending(found) }
        throw stillPending ? ActionRequestError.unsupportedDecision : ActionRequestError.unknown(id)
    }

    /// Ends a session's open requests without a decision, e.g. once its turn is over or it exited.
    func expire(sessionId: String, reason: String) {
        lock.lock()
        let ids = pending.values.filter { $0.request.sessionId == sessionId }.map(\.request.id)
        lock.unlock()
        for id in ids { resolve(id, decision: nil, outcome: reason, status: "expired") }
    }

    /// Replies to the waiting hook and records the result; nil if `id` is no longer pending or `decision`
    /// does not fit (then it stays pending).
    @discardableResult
    private func resolve(_ id: String, decision: RemoteDecision?, outcome: String, status: String) -> ActionRequestJSON? {
        lock.lock()
        guard var entry = pending[id] else {
            lock.unlock()
            return nil
        }
        var output: String?
        if let decision {
            output = entry.agent.hookOutput(for: entry.payload, decision: decision)
            if output == nil {
                lock.unlock()
                return nil
            }
        }
        pending[id] = nil
        entry.request.status = status
        entry.request.outcome = outcome
        entry.request.resolvedAt = Date().timeIntervalSince1970
        resolved.append(entry.request)
        if resolved.count > Self.resolvedLimit { resolved.removeFirst(resolved.count - Self.resolvedLimit) }
        lock.unlock()
        entry.reply(output)
        onChange?(entry.request)
        return entry.request
    }
}
