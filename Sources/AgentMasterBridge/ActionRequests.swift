import Foundation
import AgentMasterCore

/// A hook request (an approval, a question or a call the policy rules asked about) waiting for, or answered
/// by, the user in AgentMaster: a card in the Mac app or in a browser.
public struct ActionRequestJSON: Codable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    /// "permission", "question" or "policy".
    public let kind: String
    public let toolName: String
    /// What the tool would do, as the panels word it ("Run swift test").
    public let title: String
    /// The tool's input; for a question, `questions` holds what to show.
    public let input: JSONValue
    /// For a policy request: why the rules asked.
    public var reason: String?
    public let createdAt: Double
    /// When the request answers itself (see `ActionRequestStore`), below the hook's own timeout.
    public let expiresAt: Double
    /// "pending", "answered" or "expired".
    public var status: String
    /// How it ended: "allowed", "denied", "answered", "handed to the terminal", "timed out" or why it went away.
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

/// The open hook requests and the recently resolved ones, shared by the Mac app and the server. Requests live
/// in memory only: the hook that waits on one is a process of the agent, so neither outlives a restart.
/// The first answer wins, and every request ends with an answer to its hook, so no agent waits forever:
/// - an approval or a question that times out gets `timeoutDecision` (nil: no output, the agent's own UI asks);
/// - one that expires (its turn ended, the session closed) gets no output;
/// - a policy request that times out or expires is handed back (`PolicyReply.handBack`): to Claude Code's own
///   approval prompt, or denied where the agent has none, since no output would let the call run.
public final class ActionRequestStore: @unchecked Sendable {
    /// Told to the agent when nobody answers in time, so it stops and waits instead of guessing.
    public static let awayMessage = "The user is away and did not answer in time. Stop here and wait for their next instruction."
    /// Told to the agent when a policy request goes unanswered in AgentMaster.
    public static let unansweredPolicyMessage = "Nobody answered this in AgentMaster."
    /// Resolved requests kept so every window can show how one ended.
    static let resolvedLimit = 100

    private struct Pending {
        var request: ActionRequestJSON
        /// The hook output for an answer: nil when it does not fit, `.some(nil)` for no output.
        let output: (RemoteDecision) -> String??
        /// Output for a timeout, and for an expiry.
        let timedOut: String?
        let expired: String?
        let onAllow: (() -> Void)?
        let reply: (String?) -> Void
    }

    /// Below HookShim.defaultDecisionTimeout (590 s), so the agent gets this store's answer rather than a silent timeout.
    public let timeout: TimeInterval
    private let timeoutDecision: RemoteDecision?
    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    private var resolved: [ActionRequestJSON] = []
    public var onChange: (@Sendable (ActionRequestJSON) -> Void)?

    public init(timeout: TimeInterval = 580,
                timeoutDecision: RemoteDecision? = .deny(message: ActionRequestStore.awayMessage, interrupt: true)) {
        self.timeout = timeout
        self.timeoutDecision = timeoutDecision
    }

    public var all: [ActionRequestJSON] {
        lock.lock()
        defer { lock.unlock() }
        return resolved + pending.values.map(\.request).sorted { $0.createdAt < $1.createdAt }
    }

    public var open: [ActionRequestJSON] {
        lock.lock()
        defer { lock.unlock() }
        return pending.values.map(\.request).sorted { $0.createdAt < $1.createdAt }
    }

    /// An approval (PermissionRequest) or a question (AskUserQuestion), answered with `agent.hookOutput`.
    @discardableResult
    public func open(sessionId: String, agent: any AgentKind, payload: JSONValue,
                     reply: @escaping (String?) -> Void) -> ActionRequestJSON {
        let kind = payload["hook_event_name"]?.stringValue == "PermissionRequest" ? "permission" : "question"
        return add(sessionId: sessionId, kind: kind, payload: payload, reason: nil,
                   output: { decision in agent.hookOutput(for: payload, decision: decision).map { .some($0) } },
                   timedOut: timeoutDecision.flatMap { agent.hookOutput(for: payload, decision: $0) },
                   expired: nil, onAllow: nil, reply: reply)
    }

    /// A PreToolUse the policy rules asked about, answered with `agent.policyHookOutput`; `onAllow` runs when
    /// the user allows it, so the rules that asked can stop asking. Nil when the agent's hooks cannot stop a call.
    @discardableResult
    public func openPolicy(sessionId: String, agent: any AgentKind, payload: JSONValue, reason: String,
                           onAllow: @escaping () -> Void, reply: @escaping (String?) -> Void) -> ActionRequestJSON? {
        guard let handBack = agent.policyHookOutput(.handBack(reason: Self.unansweredPolicyMessage)) else { return nil }
        return add(sessionId: sessionId, kind: "policy", payload: payload, reason: reason,
                   output: { decision in
                       switch decision {
                       case .allow: return agent.policyHookOutput(.allow)
                       case .deny(let message, _): return agent.policyHookOutput(.deny(reason: message))
                       case .handBack: return agent.policyHookOutput(.handBack(reason: "The user chose to answer in the terminal."))
                       case .answer: return nil
                       }
                   },
                   timedOut: handBack, expired: handBack, onAllow: onAllow, reply: reply)
    }

    private func add(sessionId: String, kind: String, payload: JSONValue, reason: String?,
                     output: @escaping (RemoteDecision) -> String??, timedOut: String?, expired: String?,
                     onAllow: (() -> Void)?, reply: @escaping (String?) -> Void) -> ActionRequestJSON {
        let now = Date()
        let toolName = payload["tool_name"]?.stringValue ?? "tool"
        let input = payload["tool_input"] ?? .null
        let request = ActionRequestJSON(
            id: UUID().uuidString, sessionId: sessionId, kind: kind,
            toolName: toolName, title: ToolClassifier.kind(name: toolName, input: input).title, input: input,
            reason: reason, createdAt: now.timeIntervalSince1970,
            expiresAt: now.addingTimeInterval(timeout).timeIntervalSince1970, status: "pending")
        lock.lock()
        pending[request.id] = Pending(request: request, output: output, timedOut: timedOut, expired: expired,
                                      onAllow: onAllow, reply: reply)
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.resolve(request.id, outcome: "timed out", status: "expired") { .some($0.timedOut) }
        }
        onChange?(request)
        return request
    }

    @discardableResult
    public func answer(_ id: String, decision: RemoteDecision) throws -> ActionRequestJSON {
        let outcome: String
        switch decision {
        case .allow: outcome = "allowed"
        case .deny: outcome = "denied"
        case .answer: outcome = "answered"
        case .handBack: outcome = "handed to the terminal"
        }
        if let request = resolve(id, outcome: outcome, status: "answered", allowed: decision == .allow,
                                 output: { $0.output(decision) }) {
            return request
        }
        lock.lock()
        let found = resolved.last { $0.id == id }
        let stillPending = pending[id] != nil
        lock.unlock()
        if let found { throw ActionRequestError.notPending(found) }
        throw stillPending ? ActionRequestError.unsupportedDecision : ActionRequestError.unknown(id)
    }

    /// Ends a session's open requests without an answer from the user, e.g. once its turn is over or it exited.
    public func expire(sessionId: String, reason: String) {
        lock.lock()
        let ids = pending.values.filter { $0.request.sessionId == sessionId }.map(\.request.id)
        lock.unlock()
        for id in ids { resolve(id, outcome: reason, status: "expired") { .some($0.expired) } }
    }

    /// Replies to the waiting hook and records the result; nil if `id` is no longer pending or `output` says
    /// the answer does not fit (then it stays pending).
    @discardableResult
    private func resolve(_ id: String, outcome: String, status: String, allowed: Bool = false,
                         output: (Pending) -> String??) -> ActionRequestJSON? {
        lock.lock()
        guard var entry = pending[id], let line = output(entry) else {
            lock.unlock()
            return nil
        }
        pending[id] = nil
        entry.request.status = status
        entry.request.outcome = outcome
        entry.request.resolvedAt = Date().timeIntervalSince1970
        resolved.append(entry.request)
        if resolved.count > Self.resolvedLimit { resolved.removeFirst(resolved.count - Self.resolvedLimit) }
        lock.unlock()
        if allowed { entry.onAllow?() }
        entry.reply(line)
        onChange?(entry.request)
        return entry.request
    }
}
