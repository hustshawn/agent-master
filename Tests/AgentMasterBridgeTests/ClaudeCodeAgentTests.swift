import XCTest
import AgentMasterCore
@testable import AgentMasterBridge

final class ClaudeCodeAgentTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("am-claude-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func args(_ values: [String: String], resumeId: String? = nil) -> [String] {
        ClaudeCodeAgent.arguments(settingsPath: "/s.json", preferences: AgentPreferences(values: values), resumeId: resumeId)
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

    func testResumeIdIsTheClaudeSessionId() {
        let existing = ClaudeCodeAgent(transcriptExists: { _ in true })
        let missing = ClaudeCodeAgent(transcriptExists: { _ in false })
        var state = SessionState()
        // No id → nil
        XCTAssertNil(existing.resumeId(from: state))
        // Id with no transcriptPath → nil
        state.claudeSessionId = "abc"
        XCTAssertNil(existing.resumeId(from: state))
        // Id with a transcriptPath the injected check says is missing → nil
        state.transcriptPath = "/fake/abc.jsonl"
        XCTAssertNil(missing.resumeId(from: state))
        // Id with an existing transcript → the id
        XCTAssertEqual(existing.resumeId(from: state), "abc")
        XCTAssertTrue(ClaudeCodeAgent().supportsResume)
    }

    // MARK: launch

    /// Each variant gets its own bundle so one call's hook helper cannot leak into another's.
    private func paths(withHook: Bool) throws -> AppPaths {
        let bundle = root.appendingPathComponent(withHook ? "AM.app" : "NoHook.app")
        if withHook {
            let helpers = bundle.appendingPathComponent("Contents/Helpers")
            try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
            let hook = helpers.appendingPathComponent("agentmaster-hook")
            try Data("#!/bin/sh\n".utf8).write(to: hook)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        }
        return AppPaths(supportDirectory: root.appendingPathComponent("Support"), bundleURL: bundle,
                        executableURL: bundle.appendingPathComponent("Contents/MacOS/AgentMaster"))
    }

    func testLaunchWritesHookSettingsAndCleansTheEnvironment() throws {
        let paths = try paths(withHook: true)
        let agent = ClaudeCodeAgent(locate: { _ in "/fake/claude" })
        let launch = try agent.launch(AgentLaunchRequest(
            sessionId: "S1", preferences: AgentPreferences(values: ["model": "opus", "allowBypass": "false"]),
            environment: ["PATH": "/usr/bin", "CMUX_SOCKET_PATH": "/tmp/cmux"], paths: paths, resumeId: "abc"))
        let settings = root.appendingPathComponent("Support/sessions/S1/settings.json").path
        XCTAssertEqual(launch.executable, "/fake/claude")
        XCTAssertEqual(launch.args, ["--settings", settings, "--model", "opus", "--resume", "abc"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings))
        XCTAssertEqual(launch.environment["AGENTMASTER_SESSION_ID"], "S1")
        XCTAssertEqual(launch.environment["AGENTMASTER_SOCKET"], paths.socketPath)
        XCTAssertNil(launch.environment["CMUX_SOCKET_PATH"])
    }

    func testLaunchFailsWithoutClaudeOrHook() throws {
        let request = { (paths: AppPaths) in
            AgentLaunchRequest(sessionId: "S1", preferences: AgentPreferences(), environment: [:], paths: paths)
        }
        XCTAssertThrowsError(try ClaudeCodeAgent(locate: { _ in nil }).launch(request(try paths(withHook: true)))) {
            XCTAssertEqual($0 as? AgentLaunchError, .claudeNotFound)
        }
        XCTAssertThrowsError(try ClaudeCodeAgent(locate: { _ in "/fake/claude" }).launch(request(try paths(withHook: false)))) {
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
