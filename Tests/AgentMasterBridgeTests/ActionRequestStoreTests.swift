import XCTest
import AgentMasterCore
@testable import AgentMasterBridge

/// The pending table the Mac app and the server share, and the policy routing in front of it.
final class ActionRequestStoreTests: XCTestCase {
    /// Collects the hook's replies; `.some(nil)` is an empty answer.
    private final class Replies: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String?] = []
        func append(_ output: String?) { lock.lock(); all.append(output); lock.unlock() }
        var list: [String?] { lock.lock(); defer { lock.unlock() }; return all }
        var json: [JSONValue?] { list.map { $0.flatMap { try? JSONValue.parse(Data($0.utf8)) } } }
    }

    private func wait(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private let permission: JSONValue = ["hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                         "tool_input": ["command": "swift test"]]
    private let dangerous: JSONValue = ["hook_event_name": "PreToolUse", "tool_name": "Bash",
                                        "tool_input": ["command": "rm -rf build"]]

    private func decision(_ output: JSONValue??) -> JSONValue? { output??["hookSpecificOutput"]?["permissionDecision"] }

    func testOnTheMacAnUnansweredApprovalGoesBackToTheTerminal() {
        let store = ActionRequestStore(timeout: 0.05, timeoutDecision: nil)
        let replies = Replies()
        store.open(sessionId: "s1", agent: ClaudeCodeAgent(), payload: permission, reply: replies.append)
        XCTAssertTrue(wait { replies.list.count == 1 })
        XCTAssertEqual(replies.list, [nil], "no output: Claude Code asks in its terminal")
        XCTAssertEqual(store.all.first?.outcome, "timed out")
    }

    func testExpiringEverythingHandsBackPolicyChecksAndReleasesTheRest() {
        let store = ActionRequestStore()
        let replies = Replies()
        store.open(sessionId: "s1", agent: ClaudeCodeAgent(), payload: permission, reply: replies.append)
        store.openPolicy(sessionId: "s2", agent: CodexAgent(), payload: dangerous, reason: "r", onAllow: { _ in }, reply: replies.append)
        store.expireAll(reason: "AgentMaster quit")
        XCTAssertEqual(replies.list.count, 2)
        XCTAssertEqual(replies.json.compactMap(decision), ["deny"], "Codex's policy check is denied; the approval gets no output")
        XCTAssertEqual(store.open, [])
    }

    func testTheFirstAnswerWinsAndTheRestAreRefused() throws {
        let store = ActionRequestStore()
        let replies = Replies()
        let request = store.open(sessionId: "s1", agent: ClaudeCodeAgent(), payload: permission, reply: replies.append)
        XCTAssertThrowsError(try store.answer(request.id, decision: .answer(["q": "a"]))) {
            guard case ActionRequestError.unsupportedDecision = $0 else { return XCTFail("\($0)") }
        }
        try store.answer(request.id, decision: .deny(message: "No", interrupt: false))
        XCTAssertThrowsError(try store.answer(request.id, decision: .allow)) {
            guard case ActionRequestError.notPending(let current) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(current.outcome, "denied")
        }
        store.expire(sessionId: "s1", reason: "turn ended")
        XCTAssertEqual(replies.list.count, 1, "one reply per hook")
        XCTAssertThrowsError(try store.answer("nope", decision: .allow)) {
            guard case ActionRequestError.unknown = $0 else { return XCTFail("\($0)") }
        }
    }

    func testAnApprovalHandedToTheTerminalGetsNoOutput() throws {
        let store = ActionRequestStore()
        let replies = Replies()
        let request = store.open(sessionId: "s1", agent: ClaudeCodeAgent(), payload: permission, reply: replies.append)
        XCTAssertEqual(try store.answer(request.id, decision: .handBack).outcome, "handed to the terminal")
        XCTAssertEqual(replies.list, [nil])
    }

    func testAPolicyRequestIsAllowedDeniedOrHandedBack() throws {
        let store = ActionRequestStore()
        let replies = Replies()
        var allowed: [Bool] = []
        func open() throws -> ActionRequestJSON {
            try XCTUnwrap(store.openPolicy(sessionId: "s1", agent: ClaudeCodeAgent(), payload: dangerous,
                                           reason: "Looks destructive", onAllow: { allowed.append($0) }, reply: replies.append))
        }
        let first = try open()
        XCTAssertEqual(first.kind, "policy")
        XCTAssertEqual(first.reason, "Looks destructive")
        XCTAssertThrowsError(try store.answer(first.id, decision: .answer(["q": "a"])))
        try store.answer(first.id, decision: .allow)
        try store.answer(try open().id, decision: .deny(message: "Not here", interrupt: false))
        let handedBack = try store.answer(try open().id, decision: .handBack)
        XCTAssertEqual(handedBack.outcome, "handed to the terminal")
        XCTAssertEqual(replies.json.map(decision), ["allow", "deny", "ask"])
        XCTAssertEqual(replies.json[1]?["hookSpecificOutput"]?["permissionDecisionReason"], "Not here")
        XCTAssertEqual(allowed, [false], "only an allow tells the rules")
        let forSession = try store.answer(try open().id, decision: .allow, forSession: true)
        XCTAssertEqual(forSession.outcome, "allowed for this session")
        XCTAssertEqual(allowed, [false, true])
    }

    func testAPolicyRequestNobodyAnswersIsHandedBackNeverLetThrough() throws {
        let store = ActionRequestStore(timeout: 0.05)
        let replies = Replies()
        store.openPolicy(sessionId: "s1", agent: CodexAgent(), payload: dangerous, reason: "r", onAllow: { _ in },
                         reply: replies.append)
        XCTAssertTrue(wait { replies.list.count == 1 })
        XCTAssertEqual(decision(replies.json[0]), "deny", "Codex takes no ask, and no output would run the call")
        let expiring = ActionRequestStore()
        expiring.openPolicy(sessionId: "s1", agent: ClaudeCodeAgent(), payload: dangerous, reason: "r", onAllow: { _ in },
                            reply: replies.append)
        expiring.expire(sessionId: "s1", reason: "turn ended")
        XCTAssertEqual(decision(replies.json[1]), "ask")
        XCTAssertNil(store.openPolicy(sessionId: "s1", agent: KiroAgent(), payload: dangerous, reason: "r", onAllow: { _ in },
                                      reply: replies.append), "Kiro's calls cannot be stopped")
    }

    // MARK: routing

    private func route(_ payload: JSONValue, agent: any AgentKind = ClaudeCodeAgent(),
                       settings: PolicySettings = PolicySettings(), policies: PolicyBook = PolicyBook(),
                       store: ActionRequestStore, remote: Bool = true) -> (Replies, [ActionRequestJSON]) {
        let replies = Replies()
        var opened: [ActionRequestJSON] = []
        HookRequestRouter.route(sessionId: "s1", payload: payload, reply: replies.append, agent: agent, settings: settings,
                                policies: policies, requests: store, remote: remote) { opened.append($0) }
        return (replies, opened)
    }

    func testAToolCallNothingObjectsToIsAnsweredAtOnceWithNoOutput() {
        let store = ActionRequestStore()
        let (replies, opened) = route(["hook_event_name": "PreToolUse", "tool_name": "Bash",
                                       "tool_input": ["command": "swift test"]], store: store)
        XCTAssertEqual(replies.list, [nil])
        XCTAssertEqual(opened, [])
    }

    func testADeniedToolCallIsAnsweredAtOnce() {
        let policies = PolicyBook()
        policies.observe(statusLine: ["cost": ["total_cost_usd": 30]], sessionId: "s1")
        let (replies, opened) = route(["hook_event_name": "PreToolUse", "tool_name": "Read", "tool_input": [:]],
                                      settings: PolicySettings(cost: .init(denyAtUSD: 20)), policies: policies,
                                      store: ActionRequestStore())
        XCTAssertEqual(decision(replies.json.first), "deny")
        XCTAssertEqual(opened, [])
    }

    func testAnAskWaitsForTheUserAndAnAllowStopsTheBudgetAsking() throws {
        let policies = PolicyBook()
        let settings = PolicySettings(cost: .init(askAtUSD: 1))
        policies.observe(statusLine: ["cost": ["total_cost_usd": 2]], sessionId: "s1")
        let store = ActionRequestStore()
        let read: JSONValue = ["hook_event_name": "PreToolUse", "tool_name": "Read", "tool_input": [:]]
        let (replies, opened) = route(read, settings: settings, policies: policies, store: store)
        XCTAssertEqual(replies.list.count, 0, "the hook waits")
        let request = try XCTUnwrap(opened.first)
        try store.answer(request.id, decision: .allow)
        XCTAssertEqual(decision(replies.json.first), "allow")
        XCTAssertEqual(route(read, settings: settings, policies: policies, store: store).0.list, [nil],
                       "allowed once, the budget does not ask again")
    }

    func testAQuestionPassesTheRulesAndWaitsOnlyWhereAnsweredRemotely() {
        let question: JSONValue = ["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
                                   "tool_input": ["questions": []]]
        let store = ActionRequestStore()
        XCTAssertEqual(route(question, store: store).1.map(\.kind), ["question"])
        XCTAssertEqual(route(question, store: store, remote: false).0.list, [nil])
        XCTAssertEqual(route(permission, agent: CodexAgent(), store: store).0.list, [nil], "Codex approves in its terminal")
    }

    /// Review of #19 on a Mac, item 3: "Allow for this session" stops the dangerous-command rule asking in that
    /// session only; a plain allow does not.
    func testAllowForThisSessionStopsTheRuleAskingInThatSession() throws {
        let policies = PolicyBook()
        let store = ActionRequestStore()
        let (_, first) = route(dangerous, policies: policies, store: store)
        try store.answer(XCTUnwrap(first.first).id, decision: .allow)
        let (_, second) = route(dangerous, policies: policies, store: store)
        XCTAssertEqual(second.map(\.kind), ["policy"], "a plain allow: the next one asks again")
        try store.answer(XCTUnwrap(second.first).id, decision: .allow, forSession: true)
        let (replies, third) = route(dangerous, policies: policies, store: store)
        XCTAssertEqual(third, [])
        XCTAssertEqual(replies.list, [nil], "answered at once")
        var other: [ActionRequestJSON] = []
        HookRequestRouter.route(sessionId: "s2", payload: dangerous, reply: { _ in }, agent: ClaudeCodeAgent(),
                                settings: PolicySettings(), policies: policies, requests: store, remote: true) { other.append($0) }
        XCTAssertEqual(other.map(\.kind), ["policy"], "another session still asks")
    }

    /// The Mac routes with remote: false (review of #19 on a Mac, item 2): approvals and questions are answered
    /// at once with no output, so Claude Code draws its own prompt; policy checks still wait on a card.
    func testWithoutRemoteOnlyPolicyChecksWait() {
        let store = ActionRequestStore()
        let question: JSONValue = ["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
                                   "tool_input": ["questions": []]]
        XCTAssertEqual(route(permission, store: store, remote: false).0.list, [nil])
        XCTAssertEqual(route(question, store: store, remote: false).0.list, [nil])
        XCTAssertEqual(route(dangerous, store: store, remote: false).1.map(\.kind), ["policy"])
    }

    func testKiroIsNotChecked() {
        let (replies, opened) = route(dangerous, agent: KiroAgent(), store: ActionRequestStore())
        XCTAssertEqual(replies.list, [nil])
        XCTAssertEqual(opened, [])
    }
}
