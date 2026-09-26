import XCTest
import AgentMasterCore
@testable import AgentMasterWire

final class SessionSettingsBuilderTests: XCTestCase {
    private let exe = "/Applications/Agent Master.app/Contents/Helpers/agentmaster-hook"

    func testEveryEventRoutesToTheShimAndDecisionsGetLongTimeouts() throws {
        let settings = SessionSettingsBuilder(hookExecutable: exe).settings()
        let hooks = try XCTUnwrap(settings["hooks"])
        XCTAssertEqual(Set(try XCTUnwrap(hooks.objectValue).keys), Set(SessionSettingsBuilder.hookEvents))
        XCTAssertEqual(Set(SessionSettingsBuilder.hookEvents), [
            "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
            "PermissionRequest", "Notification", "Stop", "SubagentStart", "SubagentStop",
        ])

        let pre = try XCTUnwrap(hooks["PreToolUse"]?[0])
        XCTAssertEqual(pre["matcher"], "*")
        XCTAssertEqual(pre["hooks"]?[0]?["type"], "command")
        XCTAssertEqual(pre["hooks"]?[0]?["command"], .string("'\(exe)' hook"))
        XCTAssertEqual(pre["hooks"]?[0]?["timeout"], 600)
        XCTAssertEqual(hooks["PermissionRequest"]?[0]?["hooks"]?[0]?["timeout"], 600)
        XCTAssertEqual(hooks["PostToolUse"]?[0]?["matcher"], "*")
        XCTAssertNil(hooks["PostToolUse"]?[0]?["hooks"]?[0]?["timeout"])

        let stop = try XCTUnwrap(hooks["Stop"]?[0])
        XCTAssertNil(stop["matcher"])
        XCTAssertNil(stop["hooks"]?[0]?["timeout"])

        XCTAssertEqual(settings["statusLine"]?["type"], "command")
        XCTAssertEqual(settings["statusLine"]?["command"], .string("'\(exe)' statusline"))
    }

    func testDataIsValidJSON() throws {
        let data = try SessionSettingsBuilder(hookExecutable: exe).data()
        XCTAssertEqual(try JSONValue.parse(data), SessionSettingsBuilder(hookExecutable: exe).settings())
    }

    func testShellQuote() {
        XCTAssertEqual(SessionSettingsBuilder.shellQuote("/a b/c"), "'/a b/c'")
        XCTAssertEqual(SessionSettingsBuilder.shellQuote("it's"), "'it'\\''s'")
    }

    func testCommandSurvivesAShellWithSpacesAndQuotesInThePath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am dir's \(UUID().uuidString.prefix(4))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("agentmaster-hook")
        try "#!/bin/sh\necho \"ok $1\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SessionSettingsBuilder(hookExecutable: script.path).command("hook")]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "ok hook\n")
    }
}
