import XCTest
import AgentMasterCore
@testable import AgentMasterBridge

final class SessionTitlerTests: XCTestCase {
    private let install = FakeInstall()

    override func tearDown() {
        install.remove()
    }

    func testASessionIsTitledFromItsFirstPromptUntilItHasAName() {
        var state = SessionState()
        XCTAssertNil(SessionTitler.prompt(for: state, customName: nil), "no prompt yet")
        state.apply(.promptSubmitted(text: "fix the bug\nin add()"))
        XCTAssertEqual(SessionTitler.prompt(for: state, customName: nil), "fix the bug\nin add()")
        XCTAssertEqual(SessionTitler.prompt(for: state, customName: "  "), "fix the bug\nin add()", "a blank name is no name")
        XCTAssertNil(SessionTitler.prompt(for: state, customName: "Mine"))
    }

    func testTheInputIsThePromptAndTheReply() {
        XCTAssertEqual(SessionTitler.input(prompt: "Fix it", reply: "Fixed"), "USER: Fix it\n\nAGENT: Fixed")
        XCTAssertEqual(SessionTitler.input(prompt: "Fix it", reply: nil), "USER: Fix it")
        let long = String(repeating: "r", count: SessionTitler.replyLimit + 5)
        XCTAssertEqual(SessionTitler.input(prompt: "P", reply: long), "USER: P\n\nAGENT: " + long.prefix(SessionTitler.replyLimit))
    }

    func testTheTitleIsTheFirstLineWithoutQuotesOrAFinalStop() {
        XCTAssertEqual(SessionTitler.clean("\n\"Fix flaky server tests.\"\nBecause…"), "Fix flaky server tests")
        XCTAssertEqual(SessionTitler.clean("“修复不稳定的测试。”"), "修复不稳定的测试")
        XCTAssertEqual(SessionTitler.clean("# `Add Kiro models`"), "Add Kiro models")
        XCTAssertEqual(SessionTitler.clean(String(repeating: "t", count: 200))?.count, SessionTitler.titleLimit)
        XCTAssertNil(SessionTitler.clean(" \n \"\" "))
    }

    func testRunAsksHaikuWithNoToolsAndNoSavedSession() async throws {
        let claude = try install.executable("claude")
        let args = install.root.appendingPathComponent("args").path
        let input = install.root.appendingPathComponent("input").path
        try Data("""
            #!/bin/sh
            printf '%s\\n' "$@" > '\(args)'
            cat > '\(input)'
            echo '"Fix flaky tests."'
            """.utf8).write(to: URL(fileURLWithPath: claude))
        let title = try await SessionTitler.run(prompt: "the tests fail", reply: "Fixed", environment: ["AGENTMASTER_CLAUDE_PATH": claude],
                                                directory: install.root)
        XCTAssertEqual(title, "Fix flaky tests")
        XCTAssertEqual(try String(contentsOfFile: args, encoding: .utf8),
                       ["-p", "--model", "haiku", "--no-session-persistence", "--tools", "", "--strict-mcp-config", "--system-prompt",
                        SessionTitler.instructions].map { $0 + "\n" }.joined())
        XCTAssertEqual(try String(contentsOfFile: input, encoding: .utf8), "USER: the tests fail\n\nAGENT: Fixed")
    }

    func testAnEmptyAnswerFails() async throws {
        let claude = try install.executable("claude")
        try Data("#!/bin/sh\ncat > /dev/null\necho '\"\"'\n".utf8).write(to: URL(fileURLWithPath: claude))
        do {
            _ = try await SessionTitler.run(prompt: "p", reply: nil, environment: ["AGENTMASTER_CLAUDE_PATH": claude],
                                            directory: install.root)
            XCTFail("an empty title is no title")
        } catch {}
    }
}
