import XCTest
@testable import AgentMasterWire

final class UnixSocketTests: XCTestCase {
    private var path: String!

    override func setUp() {
        path = "/tmp/am-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        unlink(path)
    }

    func testRoundTripsLinesInBothDirections() throws {
        let listener = try UnixSocketListener(path: path)
        defer { listener.close() }
        let client = try UnixSocket.connect(path: path)
        let server = try XCTUnwrap(try listener.accept(timeout: 1))
        try client.write(Data("hello\nwor".utf8))
        try client.write(Data("ld\n".utf8))
        XCTAssertEqual(try server.readLine(timeout: 1), Data("hello".utf8))
        XCTAssertEqual(try server.readLine(timeout: 1), Data("world".utf8))
        try server.write(Data("back\n".utf8))
        XCTAssertEqual(try client.readLine(timeout: 1), Data("back".utf8))
    }

    func testSocketFileIsOwnerOnly() throws {
        let listener = try UnixSocketListener(path: path)
        defer { listener.close() }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testStaleFileAtPathIsReplaced() throws {
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let listener = try UnixSocketListener(path: path)
        defer { listener.close() }
        XCTAssertNoThrow(try UnixSocket.connect(path: path))
    }

    func testAcceptReturnsNilOnTimeout() throws {
        let listener = try UnixSocketListener(path: path)
        defer { listener.close() }
        XCTAssertNil(try listener.accept(timeout: 0.1))
    }

    func testReadLineTimesOut() throws {
        let listener = try UnixSocketListener(path: path)
        defer { listener.close() }
        let client = try UnixSocket.connect(path: path)
        _ = client
        let server = try XCTUnwrap(try listener.accept(timeout: 1))
        XCTAssertThrowsError(try server.readLine(timeout: 0.2)) { XCTAssertEqual($0 as? UnixSocketError, .timeout) }
    }

    func testPeerCloseSurfacesAsClosed() throws {
        let listener = try UnixSocketListener(path: path)
        defer { listener.close() }
        let client = try UnixSocket.connect(path: path)
        let server = try XCTUnwrap(try listener.accept(timeout: 1))
        client.close()
        XCTAssertThrowsError(try server.readLine(timeout: 1)) { XCTAssertEqual($0 as? UnixSocketError, .closed) }
    }

    func testWriteAfterCloseThrowsInsteadOfTouchingTheFd() throws {
        let listener = try UnixSocketListener(path: path)
        defer { listener.close() }
        let client = try UnixSocket.connect(path: path)
        client.close()
        client.close()
        XCTAssertThrowsError(try client.write(Data("x\n".utf8))) { XCTAssertEqual($0 as? UnixSocketError, .closed) }
    }

    func testWriteToDeadPeerThrowsWithoutSIGPIPE() throws {
        let listener = try UnixSocketListener(path: path)
        defer { listener.close() }
        let client = try UnixSocket.connect(path: path)
        let server = try XCTUnwrap(try listener.accept(timeout: 1))
        client.close()
        XCTAssertThrowsError(try (0..<64).forEach { _ in try server.write(Data(repeating: 0x41, count: 65536)) })
    }

    func testWriteToListenerThatNeverAcceptsTimesOut() throws {
        let listener = try UnixSocketListener(path: path)
        defer { listener.close() }
        let client = try UnixSocket.connect(path: path)
        let done = expectation(description: "write returned")
        var result: Error?
        let started = Date()
        Thread.detachNewThread {
            do { try client.write(Data(repeating: 0x41, count: 256 * 1024)) } catch { result = error }
            done.fulfill()
        }
        wait(for: [done], timeout: UnixSocket.sendTimeout + 1.5)
        XCTAssertLessThan(Date().timeIntervalSince(started), UnixSocket.sendTimeout + 1.5)
        XCTAssertEqual(result as? UnixSocketError, .timeout)
    }

    func testCloseDoesNotWaitForAStuckWrite() throws {
        let listener = try UnixSocketListener(path: path)
        defer { listener.close() }
        let client = try UnixSocket.connect(path: path)
        Thread.detachNewThread { try? client.write(Data(repeating: 0x41, count: 256 * 1024)) }
        Thread.sleep(forTimeInterval: 0.2)   // let the writer fill the buffer and block
        let started = Date()
        client.close()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testConnectWithoutListenerFails() {
        XCTAssertThrowsError(try UnixSocket.connect(path: path))
    }

    func testRejectsPathsLongerThanSunPath() {
        XCTAssertThrowsError(try UnixSocket.connect(path: "/tmp/" + String(repeating: "a", count: 200))) {
            XCTAssertEqual($0 as? UnixSocketError, .pathTooLong)
        }
    }
}
