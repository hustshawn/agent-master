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
        XCTAssertEqual(args(["trustAllTools": "true", "model": " claude-sonnet-5 ", "engine": "v3"], hookArguments: ["H"],
                            resumeId: "abc"),
                       ["chat", "--v3", "--resume-id", "abc", "--model", "claude-sonnet-5", "--trust-all-tools", "H"])
    }

    func testAnEngineOtherThanKirosOwnIsPassedOnTheCommandLine() {
        XCTAssertEqual(args(["engine": "v2"]), ["chat", "--v2"])
        XCTAssertEqual(args(["engine": "v3"]), ["chat", "--v3"])
        XCTAssertEqual(args(["engine": ""]), ["chat"], "following Kiro's chat.agentEngine passes nothing")
    }

    // MARK: options

    func testOptionsDeclareModelEngineTrustAndHooksInOrder() {
        let options = KiroAgent().options(environment: [:])
        XCTAssertEqual(options.map(\.id), [AgentOption.modelId, "engine", "trustAllTools", "hooks"])
        XCTAssertEqual(options[0].kind, .choice([], allowsCustom: true))
        XCTAssertEqual(options[1].kind, .choice([AgentChoice(value: "v2", label: "V2"), AgentChoice(value: "v3", label: "V3")],
                                                allowsCustom: false))
        XCTAssertEqual(options[2].kind, .toggle(default: false))
        XCTAssertEqual(options[3].kind, .toggle(default: true))
    }

    func testHooksFollowTheToggle() {
        XCTAssertTrue(KiroAgent().hooksEnabled(preferences: AgentPreferences()))
        XCTAssertFalse(KiroAgent().hooksEnabled(preferences: AgentPreferences(values: ["hooks": "false"])))
    }

    // MARK: launch

    /// A scratch home, so a launch never writes to the real `~/.kiro`.
    private var home: String { install.root.appendingPathComponent("home").path }

    private func launch(_ values: [String: String] = [:], environment: [String: String] = [:]) throws -> AgentLaunch {
        try KiroAgent().launch(AgentLaunchRequest(
            sessionId: "S1", preferences: AgentPreferences(values: values),
            environment: ["AGENTMASTER_KIRO_PATH": try install.executable("kiro-cli"), "HOME": home].merging(environment) { $1 },
            paths: try install.paths(withHook: values["hooks"] != "false")))
    }

    func testLaunchPointsKiroAtASessionAgentWithAHookPerEvent() throws {
        let paths = try install.paths()
        let launch = try self.launch()
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
        let launch = try self.launch(["hooks": "false"])
        XCTAssertNil(launch.environment["KIRO_AGENT_CONFIG_DIR"])
        XCTAssertNil(launch.environment["AGENTMASTER_KIRO_HOOK"])
        XCTAssertEqual(launch.environment["AGENTMASTER_SESSION_ID"], "S1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home + "/.kiro"))
    }

    /// The V3 engine reads hooks only from Kiro's own hooks folder, so every V3 session shares one file there.
    func testLaunchSharesOneV3HooksFileThatOnlyRunsInAgentMasterSessions() throws {
        let launch = try self.launch()
        let hook = try XCTUnwrap(try install.paths().hookExecutable())
        XCTAssertEqual(launch.environment["AGENTMASTER_KIRO_HOOK"], hook)
        let file = URL(fileURLWithPath: home + "/.kiro/hooks/agentmaster.json")
        let config = try JSONValue.parse(Data(contentsOf: file))
        XCTAssertEqual(config["version"], "v1")
        let hooks = try XCTUnwrap(config["hooks"]?.arrayValue)
        XCTAssertEqual(hooks.compactMap { $0["trigger"]?.stringValue },
                       ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"])
        XCTAssertEqual(Set(hooks.compactMap { $0["action"]?["command"]?.stringValue }),
                       [#"[ -z "$AGENTMASTER_KIRO_HOOK" ] || exec "$AGENTMASTER_KIRO_HOOK" hook"#])

        // KIRO_HOME moves Kiro's whole config folder; forcing V2 needs no shared file at all.
        let kiroHome = install.root.appendingPathComponent("kiro-home").path
        _ = try self.launch(environment: ["KIRO_HOME": kiroHome])
        XCTAssertTrue(FileManager.default.fileExists(atPath: kiroHome + "/hooks/agentmaster.json"))
        let v2Home = install.root.appendingPathComponent("v2-home").path
        _ = try self.launch(["engine": "v2"], environment: ["KIRO_HOME": v2Home])
        XCTAssertFalse(FileManager.default.fileExists(atPath: v2Home + "/hooks"))
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

    /// Recorded from kiro-cli 2.37 on the V3 engine: create, replace, append, a shell command, both searches, a delete.
    func testARecordedV3SessionReadsLikeClaudes() throws {
        let id = "sess_13141cdc-8afd-4f94-abed-a8c5564a49c2"
        let conversation = URL(fileURLWithPath: home + "/.kiro/sessions/30e062b3ad7f5f12/\(id)")
        try FileManager.default.createDirectory(at: conversation, withIntermediateDirectories: true)
        let events = try Fixtures.translate("kiro-v3-session", dialect: KiroHookDialect(home: home, environment: [:]))
        guard case let .sessionStarted(agentSessionId, cwd, transcriptPath) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(agentSessionId, id)
        XCTAssertEqual(cwd, "/private/tmp/kiro-lab-v3/proj")
        XCTAssertEqual(transcriptPath, conversation.appendingPathComponent("messages.jsonl").path)

        let started = events.compactMap { event -> ToolCall? in
            if case let .toolStarted(call) = event { return call } else { return nil }
        }
        let finished = events.compactMap { event -> String? in
            if case let .toolFinished(toolUseId, .success, _) = event { return toolUseId } else { return nil }
        }
        let notes = "/private/tmp/kiro-lab-v3/proj/notes.txt"
        XCTAssertEqual(started.map(\.kind), [.write(path: notes), .edit(path: notes), .edit(path: notes),
                                            .shell(command: "echo hi", description: "Print hi to the terminal"),
                                            .search(pattern: "two"), .search(pattern: ".txt$"), .other(name: "delete_file")])
        XCTAssertEqual(finished, started.map(\.id), "each PostToolUse closes its PreToolUse")
        XCTAssertEqual(Set(started.map(\.id)).count, started.count)

        let changes = events.compactMap { event -> FileChange? in
            if case let .fileChanged(change) = event { return change } else { return nil }
        }
        XCTAssertEqual(changes.map(\.path), [notes, notes, notes])
        XCTAssertEqual(changes.map { $0.hunks.flatMap(\.lines) }, [
            [DiffLine(kind: .added, text: "one")],
            [DiffLine(kind: .removed, text: "one"), DiffLine(kind: .added, text: "two")],
            [DiffLine(kind: .added, text: "three")],
        ])
        guard case .turnFinished(nil) = events.last else { return XCTFail("\(events)") }
    }

    /// V3 reports no SessionStart for a resumed conversation; its first prompt starts it instead.
    func testAResumedV3ConversationStartsWithItsFirstPrompt() throws {
        let id = "sess_13141cdc-8afd-4f94-abed-a8c5564a49c2"
        var translator = HookTranslator(dialect: KiroHookDialect(home: home, environment: [:]))
        let events = translator.translate(["session_id": .string(id), "hook_event_name": "UserPromptSubmit",
                                           "cwd": "/p", "prompt": "And now?"])
        XCTAssertEqual(events, [.sessionStarted(agentSessionId: id, cwd: "/p", transcriptPath: nil),
                                .promptSubmitted(text: "And now?")])
        XCTAssertEqual(translator.translate(["session_id": .string(id), "hook_event_name": "Stop", "cwd": "/p"]),
                       [.turnFinished(lastMessage: nil)], "only the first one")
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
