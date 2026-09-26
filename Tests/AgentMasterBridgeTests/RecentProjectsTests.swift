import XCTest
@testable import AgentMasterBridge

final class RecentProjectsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var scratch: URL!

    override func setUpWithError() throws {
        suite = "am-recents-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("am-recents-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: scratch)
    }

    private func dir(_ name: String) throws -> String {
        let url = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    func testEmptyByDefault() {
        XCTAssertEqual(RecentProjects(defaults: defaults).paths, [])
    }

    func testRecordMovesToFrontWithoutDuplicates() throws {
        let a = try dir("a"), b = try dir("b")
        let recents = RecentProjects(defaults: defaults)
        recents.record(a)
        recents.record(b)
        recents.record(a)
        XCTAssertEqual(recents.paths, [a, b])
        XCTAssertEqual(RecentProjects(defaults: defaults).paths, [a, b], "persists across instances")
    }

    func testKeepsAtMostTheLimit() throws {
        let recents = RecentProjects(defaults: defaults)
        let all = try (0..<12).map { try dir("p\($0)") }
        all.forEach(recents.record)
        XCTAssertEqual(recents.paths, Array(all.reversed().prefix(RecentProjects.limit)))
    }

    func testSkipsDirectoriesThatNoLongerExist() throws {
        let a = try dir("a"), b = try dir("b")
        let recents = RecentProjects(defaults: defaults)
        recents.record(a)
        recents.record(b)
        try FileManager.default.removeItem(atPath: b)
        XCTAssertEqual(recents.paths, [a])
    }
}
