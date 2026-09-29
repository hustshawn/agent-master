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

    func testOptionsDeclareModelSandboxApprovalAndHooksInOrder() {
        let options = CodexAgent().options(environment: [:])
        XCTAssertEqual(options.map(\.id), ["model", "sandbox", "approval", "hooks"])
        XCTAssertEqual(options[0].kind, .choice([], allowsCustom: true))
        guard case let .choice(modes, modesCustom) = options[1].kind else { return XCTFail("sandbox is a choice") }
        XCTAssertEqual(modes.map(\.value), ["read-only", "workspace-write", "danger-full-access"])
        XCTAssertFalse(modesCustom)
        guard case let .choice(policies, policiesCustom) = options[2].kind else { return XCTFail("approval is a choice") }
        XCTAssertEqual(policies.map(\.value), ["on-request", "never"])
        XCTAssertFalse(policiesCustom)
        XCTAssertEqual(options[3].kind, .toggle(default: true))
    }

    // MARK: hooks and resume

    func testHooksAreInjectedForEveryEventWithTheTrustBypass() {
        let args = CodexAgent.arguments(preferences: AgentPreferences(), hookCommand: "'/A M/hook' hook")
        XCTAssertEqual(args.first, "--dangerously-bypass-hook-trust")
        let flags = stride(from: 1, to: args.count, by: 2).map { args[$0] }
        let configs = stride(from: 1, to: args.count, by: 2).map { args[$0 + 1] }
        XCTAssertEqual(Set(flags), ["-c"])
        XCTAssertEqual(configs.count, 11)
        XCTAssertTrue(configs.contains(#"hooks.SessionStart=[{hooks=[{type="command",command="'/A M/hook' hook"}]}]"#))
        XCTAssertTrue(configs.contains(
            #"hooks.PermissionRequest=[{matcher="*",hooks=[{type="command",command="'/A M/hook' hook",timeout=600}]}]"#))
        XCTAssertTrue(configs.contains(#"hooks.PostToolUse=[{matcher="*",hooks=[{type="command",command="'/A M/hook' hook"}]}]"#))
    }

    func testTomlStringEscapesQuotesAndBackslashes() {
        XCTAssertEqual(CodexAgent.tomlString(#"a "b" \c"#), #""a \"b\" \\c""#)
    }

    func testResumeGoesFirst() {
        XCTAssertEqual(CodexAgent.arguments(preferences: AgentPreferences(values: ["model": "o3"]), resumeId: "abc"),
                       ["resume", "abc", "--model", "o3"])
    }

    func testResumeIdNeedsTheTranscript() {
        var state = SessionState()
        state.claudeSessionId = "abc"
        XCTAssertNil(CodexAgent(transcriptExists: { _ in true }).resumeId(from: state))
        state.transcriptPath = "/x/rollout.jsonl"
        XCTAssertNil(CodexAgent(transcriptExists: { _ in false }).resumeId(from: state))
        XCTAssertEqual(CodexAgent(transcriptExists: { _ in true }).resumeId(from: state), "abc")
        XCTAssertTrue(CodexAgent().supportsResume)
    }

    // MARK: launch

    /// No hook helper in this bundle.
    private let paths = AppPaths(supportDirectory: URL(fileURLWithPath: "/tmp/am-codex"),
                                 bundleURL: URL(fileURLWithPath: "/tmp/am-codex/AM.app"),
                                 executableURL: URL(fileURLWithPath: "/tmp/am-codex/AM.app/Contents/MacOS/AgentMaster"))

    func testLaunchUsesTheLocatedCodexAndCleansTheEnvironment() throws {
        let launch = try CodexAgent(locate: { _ in "/fake/codex" }).launch(AgentLaunchRequest(
            sessionId: "S1", preferences: AgentPreferences(values: ["sandbox": "read-only", "hooks": "false"]),
            environment: ["PATH": "/usr/bin", "CLAUDECODE": "1"], paths: paths, resumeId: "abc"))
        XCTAssertEqual(launch.executable, "/fake/codex")
        XCTAssertEqual(launch.args, ["resume", "abc", "--sandbox", "read-only"])
        XCTAssertEqual(launch.environment["AGENTMASTER_SESSION_ID"], "S1")
        XCTAssertEqual(launch.environment["PATH"], "/usr/bin")
        XCTAssertNil(launch.environment["CLAUDECODE"])
    }

    func testLaunchFailsWithoutCodexOrWithHooksButNoHelper() {
        XCTAssertThrowsError(try CodexAgent(locate: { _ in nil }).launch(AgentLaunchRequest(
            sessionId: "S1", preferences: AgentPreferences(), environment: [:], paths: paths))) {
            XCTAssertEqual($0 as? AgentLaunchError, .codexNotFound)
        }
        XCTAssertThrowsError(try CodexAgent(locate: { _ in "/fake/codex" }).launch(AgentLaunchRequest(
            sessionId: "S1", preferences: AgentPreferences(), environment: [:], paths: paths))) {
            XCTAssertEqual($0 as? AgentLaunchError, .hookHelperMissing)
        }
    }

    func testLaunchInjectsTheBundledHookHelper() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("am-codex-\(UUID().uuidString.prefix(8)).app")
        defer { try? FileManager.default.removeItem(at: bundle) }
        let helpers = bundle.appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let hook = helpers.appendingPathComponent("agentmaster-hook")
        try Data("#!/bin/sh\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let paths = AppPaths(supportDirectory: bundle, bundleURL: bundle,
                             executableURL: bundle.appendingPathComponent("Contents/MacOS/AgentMaster"))
        let launch = try CodexAgent(locate: { _ in "/fake/codex" }).launch(AgentLaunchRequest(
            sessionId: "S1", preferences: AgentPreferences(), environment: [:], paths: paths))
        XCTAssertEqual(launch.args.first, "--dangerously-bypass-hook-trust")
        XCTAssertTrue(launch.args.contains { $0.contains("command=\"'\(hook.path)' hook\"") })
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
