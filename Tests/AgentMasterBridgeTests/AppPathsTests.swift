import XCTest
@testable import AgentMasterBridge

final class AppPathsTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("am-paths-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func paths() -> AppPaths {
        AppPaths(supportDirectory: root.appendingPathComponent("Support Dir"),
                 bundleURL: root.appendingPathComponent("Agent Master.app"),
                 executableURL: root.appendingPathComponent("Agent Master.app/Contents/MacOS/AgentMaster"))
    }

    func testPrepareCreatesAnOwnerOnlyDirectory() throws {
        try paths().prepare()
        let attributes = try FileManager.default.attributesOfItem(atPath: paths().supportDirectory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(paths().socketPath, root.appendingPathComponent("Support Dir/agentmaster.sock").path)
    }

    func testWriteSettingsUsesOneDirectoryPerSession() throws {
        let url = try paths().writeSettings(Data("{}".utf8), sessionId: "S1")
        XCTAssertEqual(url.path, root.appendingPathComponent("Support Dir/sessions/S1/settings.json").path)
        XCTAssertEqual(try Data(contentsOf: url), Data("{}".utf8))
    }

    func testHookExecutablePrefersTheBundledHelper() {
        let helper = root.appendingPathComponent("Agent Master.app/Contents/Helpers/agentmaster-hook").path
        let sibling = root.appendingPathComponent("Agent Master.app/Contents/MacOS/agentmaster-hook").path
        XCTAssertEqual(paths().hookExecutable(isExecutable: { $0 == helper || $0 == sibling }), helper)
        XCTAssertEqual(paths().hookExecutable(isExecutable: { $0 == sibling }), sibling)
        XCTAssertNil(paths().hookExecutable(isExecutable: { _ in false }))
    }

    func testStandardSocketPathFitsInSunPath() {
        XCTAssertLessThan(AppPaths.standard.socketPath.utf8.count, 104)
        XCTAssertTrue(AppPaths.standard.socketPath.hasSuffix("Application Support/AgentMaster/agentmaster.sock"))
    }
}
