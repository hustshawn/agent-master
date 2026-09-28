import XCTest
import AgentMasterCore
@testable import AgentMasterBridge

final class CodexAgentTests: XCTestCase {
    private func args(_ values: [String: String]) -> [String] {
        CodexAgent.arguments(preferences: AgentPreferences(values: values))
    }

    // MARK: arguments

    func testFollowCodexPassesNothing() {
        XCTAssertEqual(args([:]), [])
        XCTAssertEqual(args(["model": "  "]), [])
    }

    func testModelIsPassedTrimmed() {
        XCTAssertEqual(args(["model": " gpt-5-codex "]), ["--model", "gpt-5-codex"])
    }

    func testEveryKnownSandboxAndApprovalIsPassed() {
        for mode in ["read-only", "workspace-write", "danger-full-access"] {
            XCTAssertEqual(args(["sandbox": mode]), ["--sandbox", mode], mode)
        }
        for policy in ["on-request", "never"] {
            XCTAssertEqual(args(["approval": policy]), ["--ask-for-approval", policy], policy)
        }
    }

    func testUnknownSandboxAndApprovalAreIgnored() {
        XCTAssertEqual(args(["sandbox": "yolo", "approval": "untrusted"]), [])
    }

    func testArgumentOrderIsFixed() {
        XCTAssertEqual(args(["approval": "never", "sandbox": "read-only", "model": "o3"]),
                       ["--model", "o3", "--sandbox", "read-only", "--ask-for-approval", "never"])
    }

    // MARK: options

    func testOptionsDeclareModelSandboxAndApprovalInOrder() {
        let options = CodexAgent().options(environment: [:])
        XCTAssertEqual(options.map(\.id), ["model", "sandbox", "approval"])
        XCTAssertEqual(options[0].kind, .choice([], allowsCustom: true))
        guard case let .choice(modes, modesCustom) = options[1].kind else { return XCTFail("sandbox is a choice") }
        XCTAssertEqual(modes.map(\.value), ["read-only", "workspace-write", "danger-full-access"])
        XCTAssertFalse(modesCustom)
        guard case let .choice(policies, policiesCustom) = options[2].kind else { return XCTFail("approval is a choice") }
        XCTAssertEqual(policies.map(\.value), ["on-request", "never"])
        XCTAssertFalse(policiesCustom)
        XCTAssertFalse(CodexAgent().supportsResume)
    }

    // MARK: launch

    private let paths = AppPaths(supportDirectory: URL(fileURLWithPath: "/tmp/am-codex"),
                                 bundleURL: URL(fileURLWithPath: "/tmp/am-codex/AM.app"),
                                 executableURL: URL(fileURLWithPath: "/tmp/am-codex/AM.app/Contents/MacOS/AgentMaster"))

    func testLaunchUsesTheLocatedCodexAndCleansTheEnvironment() throws {
        let launch = try CodexAgent(locate: { _ in "/fake/codex" }).launch(AgentLaunchRequest(
            sessionId: "S1", preferences: AgentPreferences(values: ["sandbox": "read-only"]),
            environment: ["PATH": "/usr/bin", "CLAUDECODE": "1"], paths: paths))
        XCTAssertEqual(launch.executable, "/fake/codex")
        XCTAssertEqual(launch.args, ["--sandbox", "read-only"])
        XCTAssertEqual(launch.environment["AGENTMASTER_SESSION_ID"], "S1")
        XCTAssertEqual(launch.environment["PATH"], "/usr/bin")
        XCTAssertNil(launch.environment["CLAUDECODE"])
    }

    func testLaunchFailsWithoutCodex() {
        XCTAssertThrowsError(try CodexAgent(locate: { _ in nil }).launch(AgentLaunchRequest(
            sessionId: "S1", preferences: AgentPreferences(), environment: [:], paths: paths))) {
            XCTAssertEqual($0 as? AgentLaunchError, .codexNotFound)
        }
    }

    // MARK: locator

    func testLocatorPrefersTheOverrideThenKnownPathsThenPATH() {
        let env = ["AGENTMASTER_CODEX_PATH": "/custom/codex", "PATH": "/a:/b"]
        XCTAssertEqual(CodexLocator.locate(environment: env, home: "/h") { $0 == "/custom/codex" || $0 == "/b/codex" },
                       "/custom/codex")
        XCTAssertEqual(CodexLocator.locate(environment: env, home: "/h") { $0 == "/h/.local/bin/codex" || $0 == "/b/codex" },
                       "/h/.local/bin/codex")
        XCTAssertEqual(CodexLocator.locate(environment: env, home: "/h") { $0 == "/b/codex" }, "/b/codex")
        XCTAssertNil(CodexLocator.locate(environment: [:], home: "/h") { _ in false })
    }
}
