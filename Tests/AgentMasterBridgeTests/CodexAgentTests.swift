import XCTest
import AgentMasterCore
@testable import AgentMasterBridge

final class CodexAgentTests: XCTestCase {
    private let install = FakeInstall()

    override func tearDown() {
        install.remove()
    }

    private func args(_ values: [String: String], hookArguments: [String] = [], resumeId: String? = nil) -> [String] {
        CodexAgent().arguments(preferences: AgentPreferences(values: values), hookArguments: hookArguments, resumeId: resumeId)
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
        XCTAssertEqual(args(["approval": "never", "sandbox": "read-only", "model": "o3"], hookArguments: ["H"], resumeId: "abc"),
                       ["resume", "abc", "--model", "o3", "--sandbox", "read-only", "--ask-for-approval", "never", "H"])
    }

    // MARK: options

    func testOptionsDeclareModelSandboxApprovalAndHooksInOrder() {
        let options = CodexAgent().options(environment: [:])
        XCTAssertEqual(options.map(\.id), [AgentOption.modelId, "sandbox", "approval", "hooks"])
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
        let args = CodexAgent.hookArguments(command: "'/A M/hook' hook")
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

    func testHooksFollowTheToggle() {
        XCTAssertTrue(CodexAgent().hooksEnabled(preferences: AgentPreferences()))
        XCTAssertFalse(CodexAgent().hooksEnabled(preferences: AgentPreferences(values: ["hooks": "false"])))
    }

    func testTomlStringEscapesQuotesAndBackslashes() {
        XCTAssertEqual(CodexAgent.tomlString(#"a "b" \c"#), #""a \"b\" \\c""#)
    }

    func testResumeIdNeedsTheTranscript() throws {
        var state = SessionState()
        state.agentSessionId = "abc"
        XCTAssertNil(CodexAgent().resumeId(from: state))
        state.transcriptPath = install.root.appendingPathComponent("gone.jsonl").path
        XCTAssertNil(CodexAgent().resumeId(from: state))
        state.transcriptPath = try install.executable("rollout.jsonl")
        XCTAssertEqual(CodexAgent().resumeId(from: state), "abc")
    }

    // MARK: launch

    func testLaunchWithoutHooksUsesTheLocatedCodexAndCleansTheEnvironment() throws {
        let codex = try install.executable("codex")
        let launch = try CodexAgent().launch(AgentLaunchRequest(
            sessionId: "S1", preferences: AgentPreferences(values: ["sandbox": "read-only", "hooks": "false"]),
            environment: ["PATH": "/usr/bin", "CLAUDECODE": "1", "AGENTMASTER_CODEX_PATH": codex],
            paths: try install.paths(withHook: false), resumeId: "abc"))
        XCTAssertEqual(launch.executable, codex)
        XCTAssertEqual(launch.args, ["resume", "abc", "--sandbox", "read-only"])
        XCTAssertEqual(launch.environment["AGENTMASTER_SESSION_ID"], "S1")
        XCTAssertEqual(launch.environment["PATH"], "/usr/bin")
        XCTAssertNil(launch.environment["CLAUDECODE"])
    }

    func testLaunchInjectsTheBundledHookHelper() throws {
        let paths = try install.paths()
        let launch = try CodexAgent().launch(AgentLaunchRequest(
            sessionId: "S1", preferences: AgentPreferences(),
            environment: ["AGENTMASTER_CODEX_PATH": try install.executable("codex")], paths: paths))
        let hook = try XCTUnwrap(paths.hookExecutable())
        XCTAssertEqual(launch.args, CodexAgent.hookArguments(command: "'\(hook)' hook"))
    }

    // MARK: dialect

    func testApplyPatchInPreToolUseBecomesAFileChange() {
        let patch = "apply_patch <<'PATCH'\n*** Begin Patch\n*** Add File: n.txt\n+hi\n*** End Patch\nPATCH"
        let pre: JSONValue = ["hook_event_name": "PreToolUse", "tool_name": "Bash", "cwd": "/p",
                              "tool_input": ["command": .string(patch)]]
        XCTAssertEqual(CodexHookDialect().fileChanges(in: pre).map(\.path), ["/p/n.txt"])
        let otherBash: JSONValue = ["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": "ls"]]
        XCTAssertEqual(CodexHookDialect().fileChanges(in: otherBash), [])
        let post: JSONValue = ["hook_event_name": "PostToolUse", "tool_name": "Bash", "cwd": "/p",
                               "tool_input": ["command": .string(patch)]]
        XCTAssertEqual(CodexHookDialect().fileChanges(in: post), [], "only the PreToolUse carries it")
    }
}
