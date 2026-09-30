import XCTest
import AgentMasterCore
@testable import AgentMasterBridge

final class KiroAgentTests: XCTestCase {
    private let install = FakeInstall()

    override func tearDown() {
        install.remove()
    }

    private func args(_ values: [String: String], hookArguments: [String] = [], resumeId: String? = nil) -> [String] {
        KiroAgent().arguments(preferences: AgentPreferences(values: values), hookArguments: hookArguments, resumeId: resumeId)
    }

    // MARK: arguments

    func testFollowKiroRunsPlainChat() {
        XCTAssertEqual(args([:]), ["chat"])
        XCTAssertEqual(args(["model": "  ", "trustAllTools": "false"]), ["chat"])
    }

    func testArgumentOrderIsFixed() {
        XCTAssertEqual(args(["trustAllTools": "true", "model": " claude-sonnet-5 "], hookArguments: ["H"], resumeId: "abc"),
                       ["chat", "--resume-id", "abc", "--model", "claude-sonnet-5", "--trust-all-tools", "H"])
    }

    // MARK: options

    func testOptionsDeclareModelTrustAndHooksInOrder() {
        let options = KiroAgent().options(environment: [:])
        XCTAssertEqual(options.map(\.id), [AgentOption.modelId, "trustAllTools", "hooks"])
        XCTAssertEqual(options[0].kind, .choice([], allowsCustom: true))
        XCTAssertEqual(options[1].kind, .toggle(default: false))
        XCTAssertEqual(options[2].kind, .toggle(default: true))
    }

    func testHooksFollowTheToggle() {
        XCTAssertTrue(KiroAgent().hooksEnabled(preferences: AgentPreferences()))
        XCTAssertFalse(KiroAgent().hooksEnabled(preferences: AgentPreferences(values: ["hooks": "false"])))
    }

    // MARK: launch

    func testLaunchPointsKiroAtASessionAgentWithAHookPerEvent() throws {
        let paths = try install.paths()
        let launch = try KiroAgent().launch(AgentLaunchRequest(
            sessionId: "S1", preferences: AgentPreferences(),
            environment: ["AGENTMASTER_KIRO_PATH": try install.executable("kiro-cli")], paths: paths))
        XCTAssertEqual(launch.args, ["chat"])
        let folder = try XCTUnwrap(launch.environment["KIRO_AGENT_CONFIG_DIR"])
        XCTAssertEqual(folder, paths.sessionDirectory("S1").appendingPathComponent("kiro-agents").path)

        let config = try JSONValue.parse(Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent("kiro_default.json")))
        XCTAssertEqual(config["name"], "kiro_default")
        XCTAssertEqual(config["tools"], ["*"])
        let hook = try XCTUnwrap(paths.hookExecutable())
        let hooks = try XCTUnwrap(config["hooks"]?.objectValue)
        XCTAssertEqual(Set(hooks.keys), ["agentSpawn", "userPromptSubmit", "preToolUse", "postToolUse", "stop"])
        XCTAssertEqual(hooks["agentSpawn"], [["command": .string("'\(hook)' hook")]])
        XCTAssertEqual(hooks["postToolUse"], [["command": .string("'\(hook)' hook"), "matcher": "*"]])

        paths.removeSessionDirectory(sessionId: "S1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder), "the agent goes with the session")
    }

    func testLaunchWithoutHooksLeavesKirosAgentsAlone() throws {
        let launch = try KiroAgent().launch(AgentLaunchRequest(
            sessionId: "S1", preferences: AgentPreferences(values: ["hooks": "false"]),
            environment: ["AGENTMASTER_KIRO_PATH": try install.executable("kiro-cli")], paths: try install.paths(withHook: false)))
        XCTAssertNil(launch.environment["KIRO_AGENT_CONFIG_DIR"])
        XCTAssertEqual(launch.environment["AGENTMASTER_SESSION_ID"], "S1")
    }

    // MARK: dialect and resume

    /// Recorded from kiro-cli 2.25: create, strReplace and a shell command.
    func testARecordedSessionReadsLikeClaudes() throws {
        let events = try Fixtures.translate("kiro-session", dialect: KiroHookDialect(home: "/Users/me"))
        let id = "fcb5b554-ba0e-42cc-b4ed-5d8119357d46"
        guard case let .sessionStarted(agentSessionId, cwd, transcriptPath) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(agentSessionId, id)
        XCTAssertEqual(cwd, "/private/tmp/kiro-lab/proj")
        XCTAssertEqual(transcriptPath, "/Users/me/.kiro/sessions/cli/\(id).json")
        XCTAssertTrue(events.contains { if case let .promptSubmitted(text) = $0 { return text.hasPrefix("Do exactly") } else { return false } })

        let started = events.compactMap { event -> ToolCall? in
            if case let .toolStarted(call) = event { return call } else { return nil }
        }
        let finished = events.compactMap { event -> String? in
            if case let .toolFinished(toolUseId, .success, _) = event { return toolUseId } else { return nil }
        }
        XCTAssertEqual(started.map(\.kind), [.write(path: "/private/tmp/kiro-lab/proj/notes.txt"),
                                            .edit(path: "/private/tmp/kiro-lab/proj/notes.txt"),
                                            .shell(command: "echo hi", description: "Run echo hi.")])
        XCTAssertEqual(finished, started.map(\.id), "each PostToolUse closes its PreToolUse")
        XCTAssertEqual(Set(started.map(\.id)).count, 3)

        let changes = events.compactMap { event -> FileChange? in
            if case let .fileChanged(change) = event { return change } else { return nil }
        }
        XCTAssertEqual(changes, [
            FileChange(path: "/private/tmp/kiro-lab/proj/notes.txt", hunks: [
                DiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 1, lines: [DiffLine(kind: .added, text: "one")]),
            ]),
            FileChange(path: "/private/tmp/kiro-lab/proj/notes.txt", hunks: [
                DiffHunk(oldStart: 0, oldLines: 1, newStart: 0, newLines: 1,
                         lines: [DiffLine(kind: .removed, text: "one"), DiffLine(kind: .added, text: "two")]),
            ]),
        ])
        guard case let .turnFinished(last) = events.last else { return XCTFail("\(events)") }
        XCTAssertTrue(last?.hasPrefix("All three steps done") == true)
    }

    /// Recorded from kiro-cli 2.25: the read, search and insert inputs.
    func testReadSearchAndInsertAreMapped() {
        let dialect = KiroHookDialect(home: "/h")
        func claude(_ tool: String, _ input: JSONValue) -> JSONValue {
            dialect.normalize(["hook_event_name": "postToolUse", "tool_name": .string(tool), "tool_input": input])
        }
        let read = claude("read", ["operations": [["mode": "Line", "path": "/p/notes.txt"]]])
        XCTAssertEqual(read["tool_name"], "Read")
        XCTAssertEqual(read["tool_input"]?["file_path"], "/p/notes.txt")
        XCTAssertEqual(claude("grep", ["pattern": "one", "path": "/p"])["tool_name"], "Grep")
        XCTAssertEqual(claude("glob", ["pattern": "*.txt", "path": "/p"])["tool_input"]?["pattern"], "*.txt")

        let insert = claude("write", ["command": "insert", "content": "zero", "insertLine": 0, "path": "/p/notes.txt"])
        XCTAssertEqual(insert["tool_name"], "Edit")
        XCTAssertEqual(PatchParser.change(fromToolResponse: insert["tool_response"] ?? nil)?.added, 1)

        let unknown = claude("use_aws", ["service_name": "s3"])
        XCTAssertEqual(unknown["tool_name"], "use_aws")
        XCTAssertEqual(unknown["hook_event_name"], "PostToolUse")
    }

    func testResumeNeedsKirosSavedConversation() throws {
        var state = SessionState()
        state.agentSessionId = "abc"
        state.transcriptPath = install.root.appendingPathComponent("gone.json").path
        XCTAssertNil(KiroAgent().resumeId(from: state))
        state.transcriptPath = try install.executable("abc.json")
        XCTAssertEqual(KiroAgent().resumeId(from: state), "abc")
    }
}
