import XCTest
import AgentMasterCore
@testable import AgentMasterBridge

final class ClaudeCodeAgentTests: XCTestCase {
    private let install = FakeInstall()

    override func tearDown() {
        install.remove()
    }

    private func args(_ values: [String: String], resumeId: String? = nil) -> [String] {
        ClaudeCodeAgent().arguments(preferences: AgentPreferences(values: values), hookArguments: ["--settings", "/s.json"],
                                    resumeId: resumeId)
    }

    private let noBypass = ["allowBypass": "false"]

    // MARK: arguments

    func testFollowClaudeWithoutBypassPassesOnlySettings() {
        XCTAssertEqual(args(noBypass), ["--settings", "/s.json"])
    }

    func testAllowBypassDefaultsOn() {
        XCTAssertEqual(args([:]), ["--settings", "/s.json", "--allow-dangerously-skip-permissions"])
    }

    func testModelAliasAndCustomIdArePassedAsIs() {
        XCTAssertEqual(args(noBypass.merging(["model": "opus"]) { $1 }), ["--settings", "/s.json", "--model", "opus"])
        XCTAssertEqual(args(noBypass.merging(["model": " us.anthropic.claude-opus-5-5[1m] "]) { $1 }),
                       ["--settings", "/s.json", "--model", "us.anthropic.claude-opus-5-5[1m]"])
    }

    func testBlankModelFollowsClaude() {
        XCTAssertEqual(args(noBypass.merging(["model": "   "]) { $1 }), ["--settings", "/s.json"])
    }

    func testEveryKnownPermissionModeIsPassed() {
        for mode in ["manual", "acceptEdits", "plan", "auto", "dontAsk"] {
            XCTAssertEqual(args(noBypass.merging(["permissionMode": mode]) { $1 }),
                           ["--settings", "/s.json", "--permission-mode", mode], mode)
        }
    }

    func testUnknownPermissionModeIsIgnored() {
        XCTAssertEqual(args(noBypass.merging(["permissionMode": "default"]) { $1 }), ["--settings", "/s.json"])
        XCTAssertEqual(args(noBypass.merging(["permissionMode": "yolo"]) { $1 }), ["--settings", "/s.json"])
    }

    func testBypassModeImpliesAllowBypassOnce() {
        for allow in ["true", "false"] {
            XCTAssertEqual(args(["permissionMode": "bypassPermissions", "allowBypass": allow]),
                           ["--settings", "/s.json", "--permission-mode", "bypassPermissions",
                            "--allow-dangerously-skip-permissions"], allow)
        }
    }

    func testArgumentOrderIsFixed() {
        XCTAssertEqual(args(["model": "sonnet", "permissionMode": "plan", "allowBypass": "true"], resumeId: "abc-123"),
                       ["--settings", "/s.json", "--model", "sonnet", "--permission-mode", "plan",
                        "--allow-dangerously-skip-permissions", "--resume", "abc-123"])
    }

    // MARK: options

    func testOptionsDeclareModelModeAndBypassInOrder() {
        let options = ClaudeCodeAgent().options(environment: [:])
        XCTAssertEqual(options.map(\.id), ["model", "permissionMode", "allowBypass"])
        guard case let .choice(models, allowsCustom) = options[0].kind else { return XCTFail("model is a choice") }
        XCTAssertEqual(models.map(\.value), ["opus", "sonnet", "haiku", "fable"])
        XCTAssertTrue(allowsCustom)
        guard case let .choice(modes, modesCustom) = options[1].kind else { return XCTFail("mode is a choice") }
        XCTAssertEqual(modes.map(\.value), ["manual", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions"])
        XCTAssertEqual(modes[0].label, "manual (default)")
        XCTAssertFalse(modesCustom)
        XCTAssertEqual(options[2].kind, .toggle(default: true))
    }

    func testModelDetailComesFromTheAliasEnvironmentVariable() {
        let options = ClaudeCodeAgent().options(environment: ["ANTHROPIC_DEFAULT_OPUS_MODEL": "us.anthropic.claude-opus-5-5[1m]"])
        guard case let .choice(models, _) = options[0].kind else { return XCTFail("model is a choice") }
        XCTAssertEqual(models[0].detail, "us.anthropic.claude-opus-5-5[1m]")
        XCTAssertNil(models[1].detail)
    }

    func testBypassModeForcesTheBypassToggle() {
        let agent = ClaudeCodeAgent()
        XCTAssertTrue(agent.isForcedOn(optionId: "allowBypass",
                                       preferences: AgentPreferences(values: ["permissionMode": "bypassPermissions"])))
        XCTAssertFalse(agent.isForcedOn(optionId: "allowBypass", preferences: AgentPreferences(values: ["permissionMode": "plan"])))
        XCTAssertFalse(agent.isForcedOn(optionId: "model",
                                        preferences: AgentPreferences(values: ["permissionMode": "bypassPermissions"])))
    }

    func testResumeIdIsTheSessionIdWhileTheTranscriptExists() throws {
        let agent = ClaudeCodeAgent()
        var state = SessionState()
        // No id → nil
        XCTAssertNil(agent.resumeId(from: state))
        // Id with no transcriptPath → nil
        state.agentSessionId = "abc"
        XCTAssertNil(agent.resumeId(from: state))
        // Id with a transcript that is gone → nil
        state.transcriptPath = install.root.appendingPathComponent("gone.jsonl").path
        XCTAssertNil(agent.resumeId(from: state))
        // Id with an existing transcript → the id
        state.transcriptPath = try install.executable("abc.jsonl")
        XCTAssertEqual(agent.resumeId(from: state), "abc")
        XCTAssertTrue(agent.supportsResume)
    }

    // MARK: launch

    func testLaunchWritesHookSettingsAndCleansTheEnvironment() throws {
        let paths = try install.paths()
        let claude = try install.executable("claude")
        let launch = try ClaudeCodeAgent().launch(AgentLaunchRequest(
            sessionId: "S1", preferences: AgentPreferences(values: ["model": "opus", "allowBypass": "false"]),
            environment: ["PATH": "/usr/bin", "CMUX_SOCKET_PATH": "/tmp/cmux", "AGENTMASTER_CLAUDE_PATH": claude],
            paths: paths, resumeId: "abc"))
        let settings = install.root.appendingPathComponent("Support/sessions/S1/settings.json").path
        XCTAssertEqual(launch.executable, claude)
        XCTAssertEqual(launch.args, ["--settings", settings, "--model", "opus", "--resume", "abc"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings))
        XCTAssertEqual(launch.environment["AGENTMASTER_SESSION_ID"], "S1")
        XCTAssertEqual(launch.environment["AGENTMASTER_SOCKET"], paths.socketPath)
        XCTAssertNil(launch.environment["CMUX_SOCKET_PATH"])
    }

    func testLaunchNeedsTheHookHelper() throws {
        let request = AgentLaunchRequest(sessionId: "S1", preferences: AgentPreferences(),
                                         environment: ["AGENTMASTER_CLAUDE_PATH": try install.executable("claude")],
                                         paths: try install.paths(withHook: false))
        XCTAssertThrowsError(try ClaudeCodeAgent().launch(request)) {
            XCTAssertEqual($0 as? AgentLaunchError, .hookHelperMissing)
        }
    }

    // MARK: registry

    func testRegistryHasClaudeAsTheDefault() {
        XCTAssertEqual(AgentRegistry.all.map(\.id), ["claude", "codex"])
        XCTAssertEqual(AgentRegistry.defaultAgent.id, "claude")
        XCTAssertEqual(AgentRegistry.agent(id: "claude")?.displayName, "Claude Code")
        XCTAssertEqual(AgentRegistry.agent(id: "codex")?.displayName, "Codex")
        XCTAssertNil(AgentRegistry.agent(id: "kiro"))
    }
}
