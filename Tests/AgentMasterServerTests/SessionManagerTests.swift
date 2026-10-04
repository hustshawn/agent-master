import XCTest
import AgentMasterCore
import AgentMasterWire
import AgentMasterBridge
import Crypto
@testable import AgentMasterServerKit

/// The manager with a stand-in for `claude`: a script that prints a line and then echoes its input.
final class SessionManagerTests: XCTestCase {
    private var root: URL!
    private var managers: [SessionManager] = []

    override func setUpWithError() throws {
        // Short, so the socket path stays under the sockaddr_un limit.
        root = URL(fileURLWithPath: "/tmp/am-srv-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
        try script("bin/claude", """
        #!/bin/sh
        echo "agent-ready $AGENTMASTER_SESSION_ID $*"
        exec cat
        """)
        try script("server/agentmaster-hook", "#!/bin/sh\n")
    }

    override func tearDown() {
        managers.forEach { $0.shutdown() }
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func script(_ path: String, _ body: String) throws -> String {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func makeManager() throws -> SessionManager {
        let manager = try SessionManager(.init(
            dataDirectory: root.appendingPathComponent("data"),
            executableURL: root.appendingPathComponent("server/agentmaster-server"),
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(),
                          "AGENTMASTER_CLAUDE_PATH": root.appendingPathComponent("bin/claude").path],
            pushTransport: pushes))
        managers.append(manager)
        return manager
    }

    /// Records the push messages the manager sends, by their Urgency header.
    private final class Pushes: WebPushTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func post(url: URL, headers: [String: String], body: Data) async throws -> Int {
            lock.withLock { all.append(headers["Urgency"] ?? "") }
            return 201
        }
        var urgencies: [String] { lock.lock(); defer { lock.unlock() }; return all }
    }

    private let pushes = Pushes()

    private var project: String { SessionManager.realPath(root.appendingPathComponent("project").path) }

    /// Collects a session's terminal output.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [ServerEvent] = []
        func append(_ event: ServerEvent) { lock.lock(); all.append(event); lock.unlock() }
        var list: [ServerEvent] { lock.lock(); defer { lock.unlock() }; return all }
    }

    private func wait(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    func testASessionRunsTheAgentInItsOwnTerminal() throws {
        let manager = try makeManager()
        let session = try manager.create(projectPath: project)
        XCTAssertEqual(session.agentId, "claude")
        XCTAssertEqual(session.status, "starting")
        XCTAssertEqual(session.projectPath, project)
        let process = try XCTUnwrap(manager.session(id: session.id)).process
        let output = Output()
        let (_, scrollback) = process.subscribe { output.append($0) }
        output.append(scrollback)
        // The launch went through ClaudeCodeAgent: the session id in the environment, --settings on the command line.
        XCTAssertTrue(wait { output.text.contains("agent-ready \(session.id) --settings") }, output.text)
        process.write(Data("ping\n".utf8))
        XCTAssertTrue(wait { output.text.contains("ping") }, output.text)
        XCTAssertEqual(manager.recentProjects.first, project)
    }

    func testHookMessagesReachTheSessionAndEveryBrowser() throws {
        let manager = try makeManager()
        let events = Events()
        let (_, snapshot) = manager.subscribe { events.append($0) }
        XCTAssertEqual(snapshot, [])
        let session = try manager.create(projectPath: project)
        let message = WireMessage(id: "m1", sessionId: session.id, kind: .event, payload: [
            "hook_event_name": "UserPromptSubmit", "session_id": "c1", "prompt": "Fix the tests\nplease",
        ])
        let connection = try UnixSocket.connect(path: manager.paths.socketPath)
        try connection.write(WireCodec.encodeLine(message))
        connection.close()
        XCTAssertTrue(wait { events.list.contains { $0.session?.state.firstPrompt == "Fix the tests" } })
        let latest = try XCTUnwrap(events.list.last { $0.session?.id == session.id }?.session)
        XCTAssertEqual(latest.status, "running")
        XCTAssertEqual(latest.title, "Fix the tests")
        XCTAssertEqual(manager.list().first?.state.firstPrompt, "Fix the tests")
    }

    /// An agent may report a hook the moment it starts, before `create` returns; it must not be dropped.
    func testAHookSentAtStartupIsNotLost() throws {
        // The real shim, built next to the test bundle (macOS: beside the .xctest; Linux: in the bundle's folder).
        let bundle = Bundle(for: Self.self).bundleURL
        let hook = [bundle, bundle.deletingLastPathComponent()].map { $0.appendingPathComponent("agentmaster-hook").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
        try XCTSkipUnless(!hook.isEmpty, "agentmaster-hook is not built")
        try script("bin/claude", """
        #!/bin/sh
        echo '{"hook_event_name":"UserPromptSubmit","session_id":"c1","prompt":"early"}' | '\(hook)' hook
        exec cat
        """)
        for _ in 0..<5 {
            let manager = try makeManager()
            let session = try manager.create(projectPath: project)
            XCTAssertTrue(wait { manager.list().first { $0.id == session.id }?.state.firstPrompt == "early" })
            manager.shutdown()
            managers.removeAll()
        }
    }

    func testRenameAndCloseAreBroadcast() throws {
        let manager = try makeManager()
        let events = Events()
        _ = manager.subscribe { events.append($0) }
        let session = try manager.create(projectPath: project)
        try manager.rename(id: session.id, to: "  My session ")
        XCTAssertTrue(wait { events.list.contains { $0.session?.title == "My session" } })
        try manager.rename(id: session.id, to: " ")
        XCTAssertTrue(wait { events.list.last?.session?.title == "New session" })
        let process = try XCTUnwrap(manager.session(id: session.id)).process
        try manager.close(id: session.id)
        XCTAssertTrue(events.list.contains { $0.type == "removed" && $0.id == session.id })
        XCTAssertEqual(manager.list(), [])
        XCTAssertTrue(wait { process.hasExited }, "closing must stop the agent")
    }

    func testAnAgentThatExitsEndsItsSession() throws {
        let manager = try makeManager()
        let session = try manager.create(projectPath: project)
        let process = try XCTUnwrap(manager.session(id: session.id)).process
        process.write(Data([0x04]))   // ^D: cat sees end of input and exits
        XCTAssertTrue(wait { manager.list().first?.status == "ended" })
        XCTAssertEqual(manager.list().first?.state.endReason, "process_exit")
    }

    func testBadRequestsAreRejected() throws {
        let manager = try makeManager()
        XCTAssertThrowsError(try manager.create(projectPath: root.appendingPathComponent("missing").path)) {
            guard case SessionManagerError.notADirectory = $0 else { return XCTFail("\($0)") }
        }
        let unknown = "no-such-agent"
        XCTAssertNil(AgentRegistry.agent(id: unknown))
        XCTAssertThrowsError(try manager.create(projectPath: project, agentId: unknown)) {
            guard case SessionManagerError.unknownAgent = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try manager.rename(id: "nope", to: "x"))
        XCTAssertThrowsError(try manager.close(id: "nope"))
        XCTAssertThrowsError(try manager.setOption(agentId: unknown, optionId: "model", value: "x"))
    }

    func testAModelOverrideReachesTheCommandLineOnce() throws {
        let manager = try makeManager()
        let output = Output()
        let session = try manager.create(projectPath: project, model: "sonnet")
        let process = try XCTUnwrap(manager.session(id: session.id)).process
        output.append(process.subscribe { output.append($0) }.scrollback)
        XCTAssertTrue(wait { output.text.contains("--model sonnet") }, output.text)
        XCTAssertNil(manager.agents().first { $0.id == "claude" }?.defaultModel, "the override is not stored")
    }

    func testSettingsLiveInTheDataDirectory() throws {
        let first = try makeManager()
        try first.setOption(agentId: "claude", optionId: "model", value: "opus")
        first.restoreSessionsOnLaunch = false
        first.shutdown()
        managers.removeAll()
        let data = try Data(contentsOf: root.appendingPathComponent("data/settings.json"))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((saved["options"] as? [String: String])?["agents.claude.model"], "opus", "the Mac app's key names")
        XCTAssertEqual(saved["restoreSessionsOnLaunch"] as? Bool, false)
        XCTAssertEqual(saved["recentProjects"] as? [String], [])
        // A second server on the same data directory reads everything back.
        let second = try makeManager()
        XCTAssertEqual(second.agents().first { $0.id == "claude" }?.defaultModel, "opus")
        XCTAssertFalse(second.restoreSessionsOnLaunch)
    }

    // MARK: requests and messages

    /// Sends `payload` as `agentmaster-hook` does. A request's connection stays open for the reply.
    @discardableResult
    private func hook(_ manager: SessionManager, _ sessionId: String, _ payload: JSONValue,
                      kind: WireKind = .event) throws -> UnixSocketConnection {
        let connection = try UnixSocket.connect(path: manager.paths.socketPath)
        try connection.write(WireCodec.encodeLine(WireMessage(id: UUID().uuidString, sessionId: sessionId, kind: kind,
                                                              payload: payload)))
        if kind != .request { connection.close() }
        return connection
    }

    private func reply(_ connection: UnixSocketConnection) throws -> JSONValue? {
        let reply = try WireCodec.decode(WireReply.self, line: connection.readLine(timeout: 5))
        connection.close()
        return try reply.output.map { try JSONValue.parse(Data($0.utf8)) }
    }

    private let permission: JSONValue = ["hook_event_name": "PermissionRequest", "session_id": "c1", "tool_name": "Bash",
                                         "tool_input": ["command": "swift test"]]

    func testAnApprovalWaitsForTheFirstAnswerFromABrowser() throws {
        let manager = try makeManager()
        let events = Events()
        _ = manager.subscribe { events.append($0) }
        let session = try manager.create(projectPath: project)
        let connection = try hook(manager, session.id, permission, kind: .request)
        XCTAssertTrue(wait { manager.actionRequests.count == 1 })
        let request = try XCTUnwrap(manager.actionRequests.first)
        XCTAssertEqual(request.kind, "permission")
        XCTAssertEqual(request.title, "$ swift test")
        XCTAssertEqual(request.status, "pending")
        XCTAssertEqual(manager.list().first?.status, "needsAttention")
        XCTAssertTrue(events.list.contains { $0.type == "request" && $0.request?.id == request.id })

        try manager.answer(requestId: request.id, decision: .allow)
        XCTAssertEqual(try reply(connection)?["hookSpecificOutput"]?["decision"]?["behavior"], "allow")
        XCTAssertThrowsError(try manager.answer(requestId: request.id, decision: .deny(message: "no", interrupt: false))) {
            guard case ActionRequestError.notPending(let current) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(current.outcome, "allowed", "the second device sees the first answer")
        }
        XCTAssertEqual(manager.actionRequests.first?.status, "answered")
    }

    func testAQuestionIsAnsweredWithTheChosenOption() throws {
        let manager = try makeManager()
        let session = try manager.create(projectPath: project)
        let connection = try hook(manager, session.id, [
            "hook_event_name": "PreToolUse", "session_id": "c1", "tool_name": "AskUserQuestion", "tool_use_id": "t1",
            "tool_input": ["questions": [["question": "Which API?", "options": [["label": "New"], ["label": "Both"]]]]],
        ], kind: .request)
        XCTAssertTrue(wait { manager.list().first?.state.attentionMessage == "Question: Which API?" })
        let request = try XCTUnwrap(manager.actionRequests.first)
        XCTAssertEqual(request.kind, "question")
        XCTAssertThrowsError(try manager.answer(requestId: request.id, decision: .allow)) {
            guard case ActionRequestError.unsupportedDecision = $0 else { return XCTFail("\($0)") }
        }
        try manager.answer(requestId: request.id, decision: .answer(["Which API?": "New"]))
        XCTAssertEqual(try reply(connection)?["hookSpecificOutput"]?["updatedInput"]?["answers"], ["Which API?": "New"])
    }

    func testARequestEndsWithItsTurn() throws {
        let manager = try makeManager()
        let session = try manager.create(projectPath: project)
        let connection = try hook(manager, session.id, permission, kind: .request)
        XCTAssertTrue(wait { manager.actionRequests.count == 1 })
        try hook(manager, session.id, ["hook_event_name": "Stop", "session_id": "c1"])
        XCTAssertNil(try reply(connection), "the hook is released without a decision")
        XCTAssertEqual(manager.actionRequests.first?.status, "expired")
        XCTAssertEqual(manager.actionRequests.first?.outcome, "turn ended")
    }

    func testAnUnansweredRequestTimesOutWithADenyThatStopsTheAgent() throws {
        let store = ActionRequestStore(timeout: 0.1)
        let output = Output()
        let request = store.open(sessionId: "s1", agent: ClaudeCodeAgent(), payload: permission) { output.append(Data(($0 ?? "").utf8)) }
        XCTAssertTrue(wait { store.all.first?.status == "expired" })
        XCTAssertEqual(store.all.first?.outcome, "timed out")
        let decision = try JSONValue.parse(Data(output.text.utf8))["hookSpecificOutput"]?["decision"]
        XCTAssertEqual(decision?["behavior"], "deny")
        XCTAssertEqual(decision?["interrupt"], true)
        XCTAssertThrowsError(try store.answer(request.id, decision: .allow))
    }

    func testDevicesArePushedWhenARequestWaitsATurnEndsOrTheAgentExits() throws {
        let manager = try makeManager()
        let device = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        manager.push.store.add(PushSubscription(endpoint: "https://web.push.apple.com/abc",
                                                keys: .init(p256dh: Base64URL.encode(device),
                                                            auth: Base64URL.encode(Data(repeating: 7, count: 16)))))
        let session = try manager.create(projectPath: project)
        let connection = try hook(manager, session.id, permission, kind: .request)
        XCTAssertTrue(wait { self.pushes.urgencies == ["high"] }, "\(pushes.urgencies)")
        try hook(manager, session.id, ["hook_event_name": "Stop", "session_id": "c1"])
        XCTAssertTrue(wait { self.pushes.urgencies == ["high", "normal"] }, "\(pushes.urgencies)")
        _ = try reply(connection)
        try XCTUnwrap(manager.session(id: session.id)).process.write(Data([0x04]))   // the agent quits by itself
        XCTAssertTrue(wait { self.pushes.urgencies.count == 3 }, "\(pushes.urgencies)")
        let closed = try manager.create(projectPath: project)
        try manager.close(id: closed.id)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(pushes.urgencies.count, 3, "closing a session is not news")
    }

    func testAMessageIsTypedOnceAndConfirmedByThePrompt() throws {
        let manager = try makeManager()
        let session = try manager.create(projectPath: project)
        let output = Output()
        let process = try XCTUnwrap(manager.session(id: session.id)).process
        _ = process.subscribe { output.append($0) }
        XCTAssertThrowsError(try manager.send(sessionId: session.id, messageId: "m0", text: "hi"), "not ready for a prompt")

        try hook(manager, session.id, ["hook_event_name": "SessionStart", "session_id": "c1", "cwd": .string(project)])
        XCTAssertTrue(wait { manager.list().first?.status == "idle" })
        let receipt = try manager.send(sessionId: session.id, messageId: "m1", text: "Fix it\nplease ")
        XCTAssertEqual(receipt.status, "written")
        XCTAssertEqual(receipt.text, "Fix it\nplease")
        XCTAssertTrue(wait { output.text.contains("Fix it") }, output.text)
        XCTAssertEqual(try manager.send(sessionId: session.id, messageId: "m1", text: "Fix it\nplease"), receipt,
                       "a retry gets the first receipt")
        XCTAssertThrowsError(try manager.send(sessionId: session.id, messageId: "m2", text: "more"), "one in flight")

        try hook(manager, session.id, ["hook_event_name": "UserPromptSubmit", "session_id": "c1", "prompt": "Fix it\nplease"])
        XCTAssertTrue(wait { manager.messageReceipts.first?.status == "delivered" })
        XCTAssertEqual(manager.list().first?.status, "running")
        XCTAssertThrowsError(try manager.send(sessionId: session.id, messageId: "m3", text: "more"), "busy while running")

        // Claude Code reports nothing for an interrupted turn; the interrupt itself ends it.
        try manager.interrupt(sessionId: session.id)
        XCTAssertEqual(manager.list().first?.status, "idle")
        XCTAssertEqual(try manager.send(sessionId: session.id, messageId: "m3", text: "more").status, "written")
    }
}
