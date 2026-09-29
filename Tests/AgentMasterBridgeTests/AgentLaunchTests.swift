import XCTest
import AgentMasterCore
@testable import AgentMasterBridge

/// The smallest agent AgentMaster can run: what a new CLI must declare, with every other piece shared.
private struct MinimalAgent: AgentKind {
    let id = "minimal"
    let displayName = "Minimal"
    let executable = ExecutableSpec(name: "am-minimal-agent-\(UUID().uuidString)", overrideVariable: "AM_TEST_MINIMAL_PATH")
    let glyph = AgentGlyphStyle.symbol("terminal")
    var hooks = false

    func options(environment: [String: String]) -> [AgentOption] { [] }
    func hooksEnabled(preferences: AgentPreferences) -> Bool { hooks }
    func hookArguments(for plan: HookPlan) throws -> [String] {
        ["--hook", plan.command, "--events", HookPlan.events.map(\.name).joined(separator: ",")]
    }
    func arguments(preferences: AgentPreferences, hookArguments: [String], resumeId: String?) -> [String] {
        (resumeId.map { ["--resume", $0] } ?? []) + hookArguments
    }
}

final class AgentLaunchTests: XCTestCase {
    private let install = FakeInstall()

    override func tearDown() {
        install.remove()
    }

    private func request(_ environment: [String: String], paths: AppPaths, resumeId: String? = nil) -> AgentLaunchRequest {
        AgentLaunchRequest(sessionId: "S1", preferences: AgentPreferences(), environment: environment, paths: paths,
                           resumeId: resumeId, projectPath: "/p")
    }

    func testTheSharedLaunchFindsTheBinaryAndBuildsTheSessionEnvironment() throws {
        let binary = try install.executable("minimal")
        let paths = try install.paths()
        let launch = try MinimalAgent().launch(request(["AM_TEST_MINIMAL_PATH": binary, "CLAUDECODE": "1", "HOME": "/h"],
                                                       paths: paths, resumeId: "r1"))
        XCTAssertEqual(launch.executable, binary)
        XCTAssertEqual(launch.args, ["--resume", "r1"])
        XCTAssertEqual(launch.environment["AGENTMASTER_SESSION_ID"], "S1")
        XCTAssertEqual(launch.environment["AGENTMASTER_SOCKET"], paths.socketPath)
        XCTAssertEqual(launch.environment["HOME"], "/h")
        XCTAssertNil(launch.environment["CLAUDECODE"])
    }

    func testHooksGetThePlanWithTheBundledHelper() throws {
        let paths = try install.paths()
        let hook = try XCTUnwrap(paths.hookExecutable())
        var agent = MinimalAgent()
        agent.hooks = true
        let launch = try agent.launch(request(["AM_TEST_MINIMAL_PATH": try install.executable("minimal")], paths: paths))
        XCTAssertEqual(launch.args, ["--hook", "'\(hook)' hook", "--events", SessionSettingsBuilderEvents.joined])
    }

    func testAMissingBinaryNamesTheAgentAndItsOverride() throws {
        let agent = MinimalAgent()
        XCTAssertThrowsError(try agent.launch(request([:], paths: try install.paths()))) {
            XCTAssertEqual($0 as? AgentLaunchError, .notFound(agent: "Minimal", executable: agent.executable))
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription,
                           "Minimal not found. Install it (~/.local/bin/\(agent.executable.name)) or set AM_TEST_MINIMAL_PATH.")
        }
    }

    func testHooksNeedTheHelperButAgentsWithoutHooksDoNot() throws {
        let env = ["AM_TEST_MINIMAL_PATH": try install.executable("minimal")]
        let noHelper = try install.paths(withHook: false)
        XCTAssertNoThrow(try MinimalAgent().launch(request(env, paths: noHelper)))
        var agent = MinimalAgent()
        agent.hooks = true
        XCTAssertThrowsError(try agent.launch(request(env, paths: noHelper))) {
            XCTAssertEqual($0 as? AgentLaunchError, .hookHelperMissing)
        }
    }

    func testDefaultsNeedNoResumeNoShortcutAndTheClaudeDialect() {
        let agent = MinimalAgent()
        var state = SessionState()
        state.agentSessionId = "abc"
        XCTAssertFalse(agent.supportsResume)
        XCTAssertNil(agent.resumeId(from: state))
        XCTAssertNil(agent.shortcut)
        XCTAssertTrue(agent.hookDialect is ClaudeHookDialect)
    }

    func testThePlanCoversEveryHookEventWithMatchersAndTimeouts() {
        let byName = Dictionary(uniqueKeysWithValues: HookPlan.events.map { ($0.name, $0) })
        XCTAssertEqual(HookPlan.events.map(\.name).joined(separator: ","), SessionSettingsBuilderEvents.joined)
        XCTAssertEqual(byName["PreToolUse"], HookPlan.Event(name: "PreToolUse", matcher: "*", timeout: 600))
        XCTAssertEqual(byName["PostToolUse"], HookPlan.Event(name: "PostToolUse", matcher: "*", timeout: nil))
        XCTAssertEqual(byName["Stop"], HookPlan.Event(name: "Stop", matcher: nil, timeout: nil))
    }
}

private enum SessionSettingsBuilderEvents {
    static let joined = "SessionStart,SessionEnd,UserPromptSubmit,PreToolUse,PostToolUse,PostToolUseFailure,"
        + "PermissionRequest,Notification,Stop,SubagentStart,SubagentStop"
}
