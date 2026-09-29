import XCTest
@testable import AgentMasterBridge

final class ExecutableSpecTests: XCTestCase {
    private let claude = ExecutableSpec(name: "claude", overrideVariable: "AGENTMASTER_CLAUDE_PATH", excluding: ["cmux.app"])

    func testOverrideWins() {
        let found = claude.locate(environment: ["AGENTMASTER_CLAUDE_PATH": "/opt/claude"], home: "/Users/me",
                                  isExecutable: { _ in true })
        XCTAssertEqual(found, "/opt/claude")
    }

    func testPrefersLocalBinOverPath() {
        let found = claude.locate(environment: ["PATH": "/usr/bin"], home: "/Users/me", isExecutable: {
            ["/Users/me/.local/bin/claude", "/usr/bin/claude"].contains($0)
        })
        XCTAssertEqual(found, "/Users/me/.local/bin/claude")
    }

    func testSkipsExcludedWrappers() {
        let found = claude.locate(environment: ["PATH": "/Applications/cmux.app/Contents/Resources/bin:/usr/bin"],
                                  home: "/Users/me", isExecutable: {
            ["/Applications/cmux.app/Contents/Resources/bin/claude", "/usr/bin/claude"].contains($0)
        })
        XCTAssertEqual(found, "/usr/bin/claude")
    }

    func testReturnsNilWhenMissing() {
        XCTAssertNil(claude.locate(environment: ["PATH": "/usr/bin"], home: "/Users/me", isExecutable: { _ in false }))
    }

    func testTheNameDrivesEveryCandidate() {
        let codex = ExecutableSpec(name: "codex", overrideVariable: "AGENTMASTER_CODEX_PATH")
        var tried: [String] = []
        _ = codex.locate(environment: ["PATH": "/a"], home: "/h") { tried.append($0); return false }
        XCTAssertEqual(tried, ["/h/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/a/codex"])
    }
}
