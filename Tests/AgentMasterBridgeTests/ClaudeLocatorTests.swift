import XCTest
@testable import AgentMasterBridge

final class ClaudeLocatorTests: XCTestCase {
    func testOverrideWins() {
        let found = ClaudeLocator.locate(environment: ["AGENTMASTER_CLAUDE_PATH": "/opt/claude"], home: "/Users/me",
                                         isExecutable: { _ in true })
        XCTAssertEqual(found, "/opt/claude")
    }

    func testPrefersLocalBinOverPath() {
        let found = ClaudeLocator.locate(environment: ["PATH": "/usr/bin"], home: "/Users/me", isExecutable: {
            ["/Users/me/.local/bin/claude", "/usr/bin/claude"].contains($0)
        })
        XCTAssertEqual(found, "/Users/me/.local/bin/claude")
    }

    func testSkipsTheCmuxWrapper() {
        let found = ClaudeLocator.locate(environment: ["PATH": "/Applications/cmux.app/Contents/Resources/bin:/usr/bin"],
                                         home: "/Users/me", isExecutable: {
            ["/Applications/cmux.app/Contents/Resources/bin/claude", "/usr/bin/claude"].contains($0)
        })
        XCTAssertEqual(found, "/usr/bin/claude")
    }

    func testReturnsNilWhenMissing() {
        XCTAssertNil(ClaudeLocator.locate(environment: ["PATH": "/usr/bin"], home: "/Users/me", isExecutable: { _ in false }))
    }
}
