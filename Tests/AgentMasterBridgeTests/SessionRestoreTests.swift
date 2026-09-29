import XCTest
import AgentMasterCore
@testable import AgentMasterBridge

/// Claude's resume rule, with every transcript present.
private struct ResumableAgent: AgentKind {
    let id = "claude"
    let displayName = "Resumable"
    let executable = ExecutableSpec(name: "resumable", overrideVariable: "AM_TEST_RESUMABLE")
    let glyph = AgentGlyphStyle.symbol("terminal")
    var supportsResume: Bool { true }
    func options(environment: [String: String]) -> [AgentOption] { [] }
    func resumeId(from state: SessionState) -> String? { SessionResume.id(from: state) { _ in true } }
    func arguments(preferences: AgentPreferences, hookArguments: [String], resumeId: String?) -> [String] { [] }
}

/// An agent that cannot resume, to prove such sessions are never recorded or restored.
private struct NoResumeAgent: AgentKind {
    let id = "noresume"
    let displayName = "No Resume"
    let executable = ExecutableSpec(name: "noresume", overrideVariable: "AM_TEST_NORESUME")
    let glyph = AgentGlyphStyle.symbol("terminal")
    func options(environment: [String: String]) -> [AgentOption] { [] }
    func arguments(preferences: AgentPreferences, hookArguments: [String], resumeId: String?) -> [String] { [] }
}

final class SessionRestoreTests: XCTestCase {
    private var root: URL!
    private let agents: [any AgentKind] = [ResumableAgent(), NoResumeAgent()]

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("am-restore-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func state(_ status: SessionStatus, claudeId: String?) -> SessionState {
        var state = SessionState()
        state.status = status
        state.agentSessionId = claudeId
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

    // MARK: titles

    func testRecordsCarryTheTitle() {
        let snapshot = OpenSessionSnapshot(agentId: "claude", projectPath: "/p", createdAt: Date(timeIntervalSince1970: 0),
                                           state: state(.idle, claudeId: "a"), selected: false,
                                           fallbackResumeId: nil, title: "fix the bug")
        XCTAssertEqual(RestorePlan.records(from: [snapshot], agents: agents).map(\.title), ["fix the bug"])
    }

    func testTitleRoundTripsThroughTheJournal() {
        let journal = OpenSessionJournal(fileURL: journalURL)
        let titled = OpenSessionRecord(agentId: "claude", projectPath: "/p", createdAt: Date(timeIntervalSince1970: 60),
                                       resumeId: "a", selected: true, title: "fix the bug")
        journal.save([titled, record(resumeId: "b")])
        XCTAssertEqual(OpenSessionJournal(fileURL: journalURL).load().map(\.title), ["fix the bug", nil])
    }

    func testLegacyRecordWithoutTitleDecodes() throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = #"[{"agentId":"claude","projectPath":"/p","createdAt":0,"resumeId":"a","selected":false}]"#
        try Data(legacy.utf8).write(to: journalURL)
        let records = OpenSessionJournal(fileURL: journalURL).load()
        XCTAssertEqual(records.map(\.resumeId), ["a"])
        XCTAssertNil(records[0].title)
    }
}
