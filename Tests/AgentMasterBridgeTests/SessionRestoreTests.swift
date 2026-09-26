import XCTest
import AgentMasterCore
@testable import AgentMasterBridge

/// An agent that cannot resume, to prove such sessions are never recorded or restored.
private struct NoResumeAgent: AgentKind {
    let id = "noresume"
    let displayName = "No Resume"
    func options(environment: [String: String]) -> [AgentOption] { [] }
    func launch(_ request: AgentLaunchRequest) throws -> AgentLaunch { throw AgentLaunchError.claudeNotFound }
}

final class SessionRestoreTests: XCTestCase {
    private var root: URL!
    private let agents: [any AgentKind] = [ClaudeCodeAgent(locate: { _ in nil }, transcriptExists: { _ in true }), NoResumeAgent()]

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("am-restore-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func state(_ status: SessionStatus, claudeId: String?) -> SessionState {
        var state = SessionState()
        state.status = status
        state.claudeSessionId = claudeId
        state.transcriptPath = claudeId.map { "/fake/\($0).jsonl" }
        return state
    }

    private func snapshot(_ agent: String = "claude", _ path: String = "/p", minute: Double = 0, status: SessionStatus = .idle,
                          claudeId: String? = "c1", selected: Bool = false, fallback: String? = nil) -> OpenSessionSnapshot {
        OpenSessionSnapshot(agentId: agent, projectPath: path, createdAt: Date(timeIntervalSince1970: minute * 60),
                            state: state(status, claudeId: claudeId), selected: selected, fallbackResumeId: fallback)
    }

    private func record(_ agent: String = "claude", _ path: String = "/p", minute: Double = 0, resumeId: String = "c1",
                        selected: Bool = false) -> OpenSessionRecord {
        OpenSessionRecord(agentId: agent, projectPath: path, createdAt: Date(timeIntervalSince1970: minute * 60),
                          resumeId: resumeId, selected: selected)
    }

    private func record(path: String, minute: Double = 0, resumeId: String) -> OpenSessionRecord {
        record("claude", path, minute: minute, resumeId: resumeId)
    }

    private func record(_ agent: String, path: String, minute: Double = 0, resumeId: String) -> OpenSessionRecord {
        record(agent, path, minute: minute, resumeId: resumeId)
    }

    // MARK: records(from:)

    func testRecordsKeepLiveResumableSessions() {
        let records = RestorePlan.records(from: [
            snapshot(status: .idle, claudeId: "a", selected: true),
            snapshot(status: .running, claudeId: "b"),
            snapshot(status: .needsAttention, claudeId: "c"),
            snapshot(status: .ended, claudeId: "d"),
            snapshot(status: .starting, claudeId: nil),
            snapshot("noresume", claudeId: "e"),
            snapshot("unknown", claudeId: "f"),
        ], agents: agents)
        XCTAssertEqual(records.map(\.resumeId), ["a", "b", "c"])
        XCTAssertEqual(records.map(\.selected), [true, false, false])
    }

    func testRecordsFallBackToTheRestoredResumeId() {
        let records = RestorePlan.records(from: [snapshot(status: .starting, claudeId: nil, fallback: "old")], agents: agents)
        XCTAssertEqual(records.map(\.resumeId), ["old"])
        let newer = RestorePlan.records(from: [snapshot(claudeId: "new", fallback: "old")], agents: agents)
        XCTAssertEqual(newer.map(\.resumeId), ["new"], "a live id (e.g. after /clear) wins over the restored one")
    }

    // MARK: make(records:)

    func testPlanSkipsMissingDirectoriesAndNonResumableAgentsAndSortsOldestFirst() {
        let plan = RestorePlan.make(records: [
            record(path: "/b", minute: 2, resumeId: "b"),
            record(path: "/gone", minute: 1, resumeId: "gone"),
            record("noresume", path: "/a", minute: 0, resumeId: "x"),
            record("unknown", path: "/a", minute: 0, resumeId: "y"),
            record(path: "/a", minute: 0, resumeId: ""),
            record(path: "/a", minute: 1, resumeId: "a"),
        ], agents: agents, directoryExists: { $0 != "/gone" })
        XCTAssertEqual(plan.map(\.resumeId), ["a", "b"])
    }

    // MARK: journal

    private var journalURL: URL { root.appendingPathComponent("Support/open-sessions.json") }

    func testMissingFileLoadsAsEmptyAndSaveRoundTrips() {
        let journal = OpenSessionJournal(fileURL: journalURL)
        XCTAssertEqual(journal.load(), [])
        let records = [record(minute: 1.5, resumeId: "a", selected: true), record(path: "/q", resumeId: "b")]
        journal.save(records)
        XCTAssertEqual(OpenSessionJournal(fileURL: journalURL).load(), records)
    }

    func testCorruptFileLoadsAsEmpty() throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[{\"agentId\":".utf8).write(to: journalURL)
        let journal = OpenSessionJournal(fileURL: journalURL)
        XCTAssertEqual(journal.load(), [])
        journal.save([record(resumeId: "a")])
        XCTAssertEqual(journal.load().map(\.resumeId), ["a"])
    }

    func testFreezeIgnoresLaterSaves() {
        let journal = OpenSessionJournal(fileURL: journalURL)
        journal.save([record(resumeId: "a"), record(resumeId: "b")])
        journal.freeze()
        journal.save([])   // what shutdown's SIGTERM → ended would otherwise write
        XCTAssertEqual(OpenSessionJournal(fileURL: journalURL).load().map(\.resumeId), ["a", "b"])
    }

    // MARK: general settings

    func testRestoreOnLaunchDefaultsOn() {
        let suite = "am-general-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(GeneralSettings.restoreSessionsOnLaunch(defaults))
        defaults.set(false, forKey: GeneralSettings.restoreSessionsOnLaunchKey)
        XCTAssertFalse(GeneralSettings.restoreSessionsOnLaunch(defaults))
    }
}
