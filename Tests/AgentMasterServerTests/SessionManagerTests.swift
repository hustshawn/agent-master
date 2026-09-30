import XCTest
import AgentMasterCore
import AgentMasterWire
import AgentMasterBridge
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
                          "AGENTMASTER_CLAUDE_PATH": root.appendingPathComponent("bin/claude").path]))
        managers.append(manager)
        return manager
    }

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
}
