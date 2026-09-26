import XCTest
import AgentMasterCore
import AgentMasterWire
@testable import AgentMasterBridge

final class HookServerTests: XCTestCase {
    private var path: String!
    private var server: HookServer?

    override func setUp() {
        path = "/tmp/amhs-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        server?.stop()
        unlink(path)
    }

    private func startServer(_ handler: @escaping HookServer.Handler) throws -> HookServer {
        let server = HookServer(socketPath: path, handler: handler)
        try server.start()
        self.server = server
        return server
    }

    private func shim(_ json: String, timeout: TimeInterval = 5, id: String = UUID().uuidString) -> String? {
        HookShim.run(mode: .hook, input: Data(json.utf8), environment: ["AGENTMASTER_SESSION_ID": "S1"],
                     connector: UnixWireConnector(path: path), decisionTimeout: timeout, makeId: { id })
    }

    func testEventsAreDeliveredInOrder() throws {
        let received = Box<[String]>([])
        _ = try startServer { message, _ in received.mutate { $0.append(message.id) } }
        let ids = (0..<50).map { "e\($0)" }
        for id in ids { XCTAssertNil(shim(#"{"hook_event_name":"PostToolUse"}"#, id: id)) }
        XCTAssertTrue(waitUntil { received.value.count == 50 })
        XCTAssertEqual(received.value, ids)
    }

    func testRequestRoundTripReturnsTheAppsOutput() throws {
        let kinds = Box<[WireKind]>([])
        _ = try startServer { message, reply in
            kinds.mutate { $0.append(message.kind) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { reply(#"{"ok":true}"#) }
        }
        XCTAssertEqual(shim(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#), #"{"ok":true}"#)
        XCTAssertEqual(kinds.value, [.request])
        XCTAssertEqual(server?.pendingCount, 0)
    }

    func testNilReplyMeansHandleInTerminal() throws {
        _ = try startServer { _, reply in reply(nil) }
        XCTAssertNil(shim(#"{"hook_event_name":"PermissionRequest"}"#))
    }

    func testStopReleasesPendingRequestsImmediately() throws {
        let server = try startServer { _, _ in }
        let output = Box<String?>("unset")
        let returned = expectation(description: "shim returned")
        DispatchQueue.global().async {
            output.value = self.shim(#"{"hook_event_name":"PermissionRequest"}"#, timeout: 30)
            returned.fulfill()
        }
        XCTAssertTrue(waitUntil { server.pendingCount == 1 })
        let start = Date()
        server.stop()
        wait(for: [returned], timeout: 3)
        XCTAssertNil(output.value)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(server.pendingCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "stop removes the socket file")
    }

    func testLateAndDuplicateRepliesAreIgnored() throws {
        let saved = Box<HookServer.Reply?>(nil)
        let server = try startServer { _, reply in saved.value = reply }
        XCTAssertNil(shim(#"{"hook_event_name":"PermissionRequest"}"#, timeout: 0.3), "the shim gave up waiting")
        let reply = try XCTUnwrap(saved.value)
        XCTAssertEqual(server.pendingCount, 1)
        reply("late")
        reply("again")
        XCTAssertEqual(server.pendingCount, 0)
        server.stop()
        reply("after stop")
    }

    func testGarbageAndSilentClientsDoNotStopDelivery() throws {
        let received = Box<[String]>([])
        _ = try startServer { message, _ in received.mutate { $0.append(message.id) } }
        let garbage = try UnixSocket.connect(path: path)
        try garbage.write(Data("not json\n".utf8))
        let silent = try UnixSocket.connect(path: path)
        XCTAssertNil(shim(#"{"hook_event_name":"Stop"}"#, id: "after"))
        XCTAssertTrue(waitUntil(timeout: 4) { received.value == ["after"] })
        silent.close()
        garbage.close()
    }

    func testStartReplacesAStaleSocketFile() throws {
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let received = Box(0)
        _ = try startServer { _, _ in received.mutate { $0 += 1 } }
        XCTAssertNil(shim(#"{"hook_event_name":"Stop"}"#))
        XCTAssertTrue(waitUntil { received.value == 1 })
    }

    func testShimReturnsImmediatelyWhenTheAppIsNotRunning() {
        let start = Date()
        XCTAssertNil(shim(#"{"hook_event_name":"PermissionRequest"}"#, timeout: 30))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}
