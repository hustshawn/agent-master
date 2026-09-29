import XCTest
import Hummingbird
@testable import AgentMasterServerKit

final class ServerBasicsTests: XCTestCase {
    func testOptionsDefaultToLoopbackAndTheHomeDataDirectory() throws {
        let options = try ServerMain.Options.parse([], environment: [:])
        XCTAssertEqual(options.host, "127.0.0.1")
        XCTAssertEqual(options.port, 8765)
        XCTAssertEqual(options.dataDirectory, NSHomeDirectory() + "/.agentmaster-server")
        XCTAssertNil(options.token)
    }

    func testOptionsParseEveryFlagAndTheTokenVariable() throws {
        let options = try ServerMain.Options.parse(["--host", "0.0.0.0", "--port", "9000", "--data-dir", "~/x"],
                                                   environment: ["AGENTMASTER_SERVER_TOKEN": "env"])
        XCTAssertEqual(options.host, "0.0.0.0")
        XCTAssertEqual(options.port, 9000)
        XCTAssertEqual(options.dataDirectory, NSHomeDirectory() + "/x")
        XCTAssertEqual(options.token, "env")
        XCTAssertEqual(try ServerMain.Options.parse(["--token", "flag"], environment: ["AGENTMASTER_SERVER_TOKEN": "env"]).token,
                       "flag")
    }

    func testBadOptionsAreRejected() {
        XCTAssertThrowsError(try ServerMain.Options.parse(["--port", "0"], environment: [:]))
        XCTAssertThrowsError(try ServerMain.Options.parse(["--port"], environment: [:]))
        XCTAssertThrowsError(try ServerMain.Options.parse(["--nope"], environment: [:]))
    }

    func testTokenIsCreatedOnceAndKeptPrivate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-token-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try ServerMain.loadOrCreateToken(in: dir)
        XCTAssertEqual(first.count, 48)
        XCTAssertEqual(try ServerMain.loadOrCreateToken(in: dir), first)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("token").path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600)
    }

    func testTokenComparison() {
        XCTAssertTrue(TokenMiddleware<BasicRequestContext>.constantTimeEqual("abc", "abc"))
        XCTAssertFalse(TokenMiddleware<BasicRequestContext>.constantTimeEqual("abc", "abd"))
        XCTAssertFalse(TokenMiddleware<BasicRequestContext>.constantTimeEqual("abc", "abcd"))
        XCTAssertFalse(TokenMiddleware<BasicRequestContext>.constantTimeEqual("", "abc"))
    }

    func testFolderListingShowsVisibleSubfoldersOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-folders-\(UUID().uuidString.prefix(8))")
        for name in ["b", "A", ".hidden"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: dir.appendingPathComponent("file.txt"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let listing = try FolderListing.list(dir.path)
        XCTAssertEqual(listing.folders.map(\.name), ["A", "b"])
        XCTAssertEqual(listing.parent, dir.deletingLastPathComponent().path)
        XCTAssertThrowsError(try FolderListing.list(dir.appendingPathComponent("file.txt").path))
    }

    func testProjectPathsResolveLikeTheAgentsCwd() {
        #if os(macOS)
        // Agents report /private/tmp/...; URL.resolvingSymlinksInPath would strip /private again.
        XCTAssertEqual(SessionManager.realPath("/tmp"), "/private/tmp")
        #endif
        XCTAssertEqual(SessionManager.realPath("/"), "/")
        XCTAssertEqual(SessionManager.realPath("/definitely/not/here"), "/definitely/not/here")
    }

    func testTildeExpansion() {
        XCTAssertEqual(SessionManager.expandingTilde("~"), NSHomeDirectory())
        XCTAssertEqual(SessionManager.expandingTilde(" ~/p "), NSHomeDirectory() + "/p")
        XCTAssertEqual(SessionManager.expandingTilde("/a/../b"), "/b")
    }
}
