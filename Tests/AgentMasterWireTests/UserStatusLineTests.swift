import XCTest
import AgentMasterCore
@testable import AgentMasterWire

final class UserStatusLineTests: XCTestCase {
    func testSettingsFilesFollowClaudeCodePrecedence() {
        XCTAssertEqual(UserStatusLine.settingsFiles(directory: "/p", home: "/h"),
                       ["/p/.claude/settings.local.json", "/p/.claude/settings.json", "/h/.claude/settings.json"])
        XCTAssertEqual(UserStatusLine.settingsFiles(directory: nil, home: "/h"), ["/h/.claude/settings.json"])
    }

    func testCommandComesFromTheFirstFileThatHasOne() {
        let files = ["/a", "/b", "/c"]
        let contents = [
            "/a": #"{"model":"x"}"#,
            "/b": #"{"statusLine":{"type":"command","command":"python3 mine.py"}}"#,
            "/c": #"{"statusLine":{"type":"command","command":"other"}}"#,
        ]
        XCTAssertEqual(UserStatusLine.command(in: files, read: { contents[$0].map { Data($0.utf8) } }), "python3 mine.py")
        XCTAssertNil(UserStatusLine.command(in: ["/missing"], read: { _ in nil }))
    }

    func testOurOwnShimIsNeverRunAsTheUserStatusLine() {
        let json = #"{"statusLine":{"type":"command","command":"'/x/agentmaster-hook' statusline"}}"#
        XCTAssertNil(UserStatusLine.command(in: ["/a"], read: { _ in Data(json.utf8) }))
    }

    func testRunFeedsStdinAndReturnsStdout() {
        XCTAssertEqual(UserStatusLine.run(command: "cat", input: Data("hello".utf8), directory: nil), "hello")
    }

    func testRunReturnsNilOnFailureEmptyOutputOrTimeout() {
        XCTAssertNil(UserStatusLine.run(command: "echo partial; exit 1", input: Data(), directory: nil))
        XCTAssertNil(UserStatusLine.run(command: "true", input: Data(), directory: nil))
        XCTAssertNil(UserStatusLine.run(command: "sleep 5", input: Data(), directory: nil, timeout: 0.2))
    }

    func testRunWorksFromTheSessionDirectory() throws {
        let directory = NSTemporaryDirectory() + "am-cwd-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let output = UserStatusLine.run(command: "pwd -P", input: Data(), directory: directory)
        XCTAssertEqual(output?.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "/").last,
                       (directory as NSString).lastPathComponent)
    }

    func testOutputReadsHomeSettingsAndRunsTheCommand() throws {
        let home = NSTemporaryDirectory() + "am-home-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        try Data(#"{"statusLine":{"type":"command","command":"echo user-bar"}}"#.utf8)
            .write(to: URL(fileURLWithPath: home + "/.claude/settings.json"))
        let payload: JSONValue = ["cwd": "/nonexistent"]
        XCTAssertEqual(UserStatusLine.output(for: Data(), payload: payload, home: home), "user-bar\n")
        XCTAssertNil(UserStatusLine.output(for: Data(), payload: payload, home: "/nonexistent-home"))
    }
}
