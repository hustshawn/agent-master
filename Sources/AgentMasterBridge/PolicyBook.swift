import Foundation
import AgentMasterCore

/// Every session's `PolicyState`, behind a lock: the hook server's accept thread checks a PreToolUse here
/// synchronously, without waiting on the main thread, so later hook events are not held up.
public final class PolicyBook: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [String: PolicyState] = [:]

    public init() {}

    /// What the policy rules say about one PreToolUse: nil when there is nothing to check (another event,
    /// or an agent whose hooks cannot stop a call), which the hook answers at once with no output.
    public func check(sessionId: String, agent: any AgentKind, payload: JSONValue,
                      settings: PolicySettings) -> PolicyCheck? {
        let normalized = agent.hookDialect.normalize(payload)
        guard normalized["hook_event_name"]?.stringValue == "PreToolUse",
              agent.policyHookOutput(.allow) != nil else { return nil }
        let toolName = normalized["tool_name"]?.stringValue ?? ""
        return sync { states in
            PolicyReducer.evaluate(toolName: toolName, input: normalized["tool_input"] ?? .null, settings: settings,
                                   state: &states[sessionId, default: PolicyState()])
        }
    }

    /// A status line's cost, for the budget.
    public func observe(statusLine payload: JSONValue, sessionId: String) {
        guard let cost = payload["cost"]?["total_cost_usd"]?.doubleValue else { return }
        sync { PolicyReducer.observeCost(cost, in: &$0[sessionId, default: PolicyState()]) }
    }

    public func approve(_ check: PolicyCheck, forSession: Bool = false, sessionId: String, settings: PolicySettings) {
        sync {
            PolicyReducer.approve(check, forSession: forSession, settings: settings,
                                  state: &$0[sessionId, default: PolicyState()])
        }
    }

    public func remove(sessionId: String) {
        sync { $0[sessionId] = nil }
    }

    public func state(sessionId: String) -> PolicyState? {
        sync { $0[sessionId] }
    }

    private func sync<T>(_ body: (inout [String: PolicyState]) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&states)
    }
}

/// What the Mac app and the server do with a hook request: a PreToolUse goes through the policy rules,
/// which answer it, ask the user or let it through; anything else that `remote` accepts waits for the user.
public enum HookRequestRouter {
    /// - Parameters:
    ///   - remote: whether approvals and questions wait for an answer in AgentMaster. The Mac app passes false:
    ///     Claude Code draws its own prompt in the terminal while the hook waits, so a card only repeated it.
    ///   - opened: called with each request a card should show.
    public static func route(sessionId: String, payload: JSONValue, reply: @escaping (String?) -> Void,
                             agent: any AgentKind, settings: PolicySettings, policies: PolicyBook,
                             requests: ActionRequestStore, remote: Bool, opened: (ActionRequestJSON) -> Void) {
        if let check = policies.check(sessionId: sessionId, agent: agent, payload: payload, settings: settings) {
            switch check.verdict {
            case .allow:
                // AskUserQuestion passes the rules untouched and may still wait for an answer below.
                guard agent.hookDialect.normalize(payload)["tool_name"]?.stringValue == "AskUserQuestion" else {
                    return reply(nil)
                }
            case .deny:
                return reply(agent.policyHookOutput(.deny(reason: check.reason)) ?? nil)
            case .ask:
                if let request = requests.openPolicy(
                    sessionId: sessionId, agent: agent, payload: payload, reason: check.reason,
                    onAllow: { forSession in
                        policies.approve(check, forSession: forSession, sessionId: sessionId, settings: settings)
                    },
                    reply: reply) {
                    opened(request)
                } else {
                    reply(nil)
                }
                return
            }
        }
        // Every request an agent answers in AgentMaster can be denied, which is also what a timeout may send.
        guard remote, agent.hookOutput(for: payload, decision: .deny(message: "", interrupt: false)) != nil else {
            return reply(nil)
        }
        opened(requests.open(sessionId: sessionId, agent: agent, payload: payload, reply: reply))
    }
}
