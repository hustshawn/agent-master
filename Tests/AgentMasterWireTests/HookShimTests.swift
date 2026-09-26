import XCTest
import AgentMasterCore
@testable import AgentMasterWire

final class HookShimTests: XCTestCase {
    private let env = ["AGENTMASTER_SESSION_ID": "S1"]

    private func run(_ json: String, mode: ShimMode = .hook, connection: FakeConnection?,
                     env: [String: String]? = nil) -> String? {
        HookShim.run(mode: mode, input: Data(json.utf8), environment: env ?? self.env,
                     connector: FakeConnector(connection: connection), makeId: { "M1" })
    }

    func testNotificationEventIsForwardedWithoutWaiting() {
        let connection = FakeConnection()
        XCTAssertNil(run(#"{"hook_event_name":"PostToolUse","tool_name":"Bash"}"#, connection: connection))
        XCTAssertEqual(connection.sent, [WireMessage(id: "M1", sessionId: "S1", kind: .event,
                                                     payload: ["hook_event_name": "PostToolUse", "tool_name": "Bash"])])
        XCTAssertNil(connection.receiveTimeout)
        XCTAssertTrue(connection.closed)
    }

    func testPermissionRequestWaitsAndPrintsReply() {
        let connection = FakeConnection()
        connection.reply = .success(WireReply(id: "M1", output: #"{"decision":1}"#))
        XCTAssertEqual(run(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#, connection: connection),
                       #"{"decision":1}"#)
        XCTAssertEqual(connection.sent.first?.kind, .request)
        XCTAssertEqual(connection.receiveTimeout, HookShim.defaultDecisionTimeout)
        XCTAssertEqual(HookShim.defaultDecisionTimeout, 590)
    }

    func testOnlyAskUserQuestionPreToolUseIsADecision() {
        XCTAssertTrue(HookShim.isDecision(["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion"]))
        XCTAssertTrue(HookShim.isDecision(["hook_event_name": "PermissionRequest", "tool_name": "Bash"]))
        XCTAssertFalse(HookShim.isDecision(["hook_event_name": "PreToolUse", "tool_name": "Bash"]))
        XCTAssertFalse(HookShim.isDecision(["hook_event_name": "PostToolUse", "tool_name": "AskUserQuestion"]))
    }

    func testMismatchedReplyIdPrintsNothing() {
        let connection = FakeConnection()
        connection.reply = .success(WireReply(id: "OTHER", output: "x"))
        XCTAssertNil(run(#"{"hook_event_name":"PermissionRequest"}"#, connection: connection))
    }

    func testReplyTimeoutPrintsNothing() {
        let connection = FakeConnection()
        XCTAssertNil(run(#"{"hook_event_name":"PermissionRequest"}"#, connection: connection))
        XCTAssertTrue(connection.closed)
    }

    func testAppNotRunningPrintsNothing() {
        XCTAssertNil(run(#"{"hook_event_name":"PermissionRequest"}"#, connection: nil))
        XCTAssertNil(run(#"{"hook_event_name":"Stop"}"#, connection: nil))
    }

    func testMissingSessionIdOrBadJSONNeverConnects() {
        let connection = FakeConnection()
        XCTAssertNil(run(#"{"hook_event_name":"Stop"}"#, connection: connection, env: [:]))
        XCTAssertNil(run("not json", connection: connection))
        XCTAssertEqual(connection.sent, [])
    }

    func testLargePayloadToAppThatNeverReadsReturnsPromptly() throws {
        let path = "/tmp/am-\(UUID().uuidString.prefix(8)).sock"
        let listener = try UnixSocketListener(path: path)   // alive but never accepts or reads
        defer { listener.close() }
        let big = String(repeating: "x", count: 256 * 1024)
        let input = Data(#"{"hook_event_name":"PostToolUse","tool_name":"Read","tool_response":"\#(big)"}"#.utf8)
        let done = expectation(description: "shim returned")
        var output: String? = "unset"
        let started = Date()
        Thread.detachNewThread {
            output = HookShim.run(mode: .hook, input: input, environment: self.env,
                                  connector: UnixWireConnector(path: path))
            done.fulfill()
        }
        wait(for: [done], timeout: 3.5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.5)
        XCTAssertNil(output)
    }

    func testStatusLineIsForwardedAndAlwaysPrinted() {
        let json = #"{"model":{"display_name":"Haiku 4.5"},"cwd":"/tmp/p"}"#
        let payload = try! JSONValue.parse(Data(json.utf8))
        let connection = FakeConnection()
        XCTAssertEqual(run(json, mode: .statusline, connection: connection), StatusLineFormatter.format(payload))
        XCTAssertEqual(connection.sent.first?.kind, .statusline)
        XCTAssertNil(connection.receiveTimeout)
        XCTAssertEqual(run(json, mode: .statusline, connection: nil), StatusLineFormatter.format(payload))
    }

    func testStatusLineFormat() throws {
        let payload = try JSONValue.parse(Data(#"{"model":{"display_name":"Haiku 4.5"},"workspace":{"current_dir":"/tmp/my proj"},"context_window":{"used_percentage":12}}"#.utf8))
        XCTAssertEqual(StatusLineFormatter.format(payload),
                       "\u{1B}[38;2;90;160;255mHaiku 4.5\u{1B}[0m"
                       + "\u{1B}[38;2;138;144;152m · \u{1B}[0m"
                       + "\u{1B}[38;2;204;211;219mmy proj\u{1B}[0m"
                       + "\u{1B}[38;2;138;144;152m · \u{1B}[0m"
                       + "\u{1B}[38;2;138;144;152mctx 12%\u{1B}[0m")
        XCTAssertEqual(StatusLineFormatter.format(.null), "\u{1B}[38;2;90;160;255mclaude\u{1B}[0m")
    }
}
