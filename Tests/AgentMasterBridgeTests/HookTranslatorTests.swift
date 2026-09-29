import XCTest
import AgentMasterCore
@testable import AgentMasterBridge

final class HookTranslatorTests: XCTestCase {
    // MARK: Recorded sessions

    func testBasicSession() throws {
        let events = try Fixtures.translate("basic-session")
        XCTAssertEqual(Array(events.prefix(6)), [
            .sessionStarted(claudeSessionId: "4235ee52-bbf1-433c-92ef-f861de1d754b", cwd: "/private/tmp/ccspike",
                            transcriptPath: "/Users/shawn/.claude/projects/-private-tmp-ccspike/4235ee52-bbf1-433c-92ef-f861de1d754b.jsonl"),
            .permissionModeChanged("default"),
            .promptSubmitted(text: "Run exactly these two bash commands one after another: 'echo hello' and 'echo forbidden'. Then report what happened."),
            .toolStarted(ToolCall(id: "toolu_bdrk_01SBnNd6wSooPxSFmSyBp6iB", name: "Bash",
                                  kind: .shell(command: "echo hello", description: "Run first command"))),
            .toolFinished(toolUseId: "toolu_bdrk_01SBnNd6wSooPxSFmSyBp6iB", outcome: .success, durationMs: 1674),
            .toolStarted(ToolCall(id: "toolu_bdrk_017ZztthcE5TmhJdqnrZpLoj", name: "Bash",
                                  kind: .shell(command: "echo forbidden", description: "Run second command"))),
        ])
        XCTAssertEqual(events.count, 7)
        guard case .turnFinished(let message) = events.last else { return XCTFail("expected turnFinished") }
        XCTAssertTrue(message?.hasPrefix("**What happened:**") == true)

        var state = SessionState()
        events.forEach { state.apply($0) }
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.runningTools, [], "the hook-denied command never gets a PostToolUse")
    }

    /// Recorded from codex-cli 0.154: a command, then an edit through `apply_patch` (which gets no PostToolUse).
    func testCodexSession() throws {
        let events = try Fixtures.translate("codex-session")
        // Unlike Claude's, Codex's SessionStart already carries the permission mode.
        XCTAssertEqual(Array(events.prefix(3)), [
            .permissionModeChanged("bypassPermissions"),
            .sessionStarted(claudeSessionId: "01a0e8c2-1de6-78d2-9fde-fb5efd13ff48", cwd: "/tmp/cx-hook.dV4Q",
                            transcriptPath: "/Users/shawnzh/.codex/sessions/2026/09/29/rollout-2026-09-29T00-03-50-01a0e8c2-1de6-78d2-9fde-fb5efd13ff48.jsonl"),
            .promptSubmitted(text: "Do these in order without asking: 1) run the shell command: echo smoke-done  2) edit app.py so add() returns a + b  3) reply with just the word Finished."),
        ])
        XCTAssertTrue(events.contains(.fileChanged(FileChange(path: "/tmp/cx-hook.dV4Q/app.py", hunks: [
            DiffHunk(oldStart: 0, oldLines: 2, newStart: 0, newLines: 2, lines: [
                DiffLine(kind: .context, text: "def add(a, b):"),
                DiffLine(kind: .removed, text: "    return a - b"),
                DiffLine(kind: .added, text: "    return a + b"),
            ]),
        ]))))

        var state = SessionState()
        events.forEach { state.apply($0) }
        XCTAssertEqual(state.firstPrompt, "Do these in order without asking: 1) run the shell command: echo smoke-done  2) edit app.py so add() returns a + b  3) reply with just the word Finished.")
        XCTAssertEqual(state.changes.map(\.path), ["/tmp/cx-hook.dV4Q/app.py"])
        XCTAssertEqual(state.runningTools, [], "Stop clears the apply_patch call that never finished")
        XCTAssertEqual(state.lastMessage, "Finished.")
        XCTAssertEqual(state.status, .ended)
        XCTAssertEqual(state.endReason, "other")
    }

    func testTasksEditsFailureAndSubagentSession() throws {
        let start = Date(timeIntervalSince1970: 0)
        let events = try Fixtures.translate("session-tasks-edit-agent")

        let todoLists = events.compactMap { event -> [TodoItem]? in
            if case .todosChanged(let items) = event { return items }
            return nil
        }
        XCTAssertEqual(todoLists, [
            [TodoItem(id: "1", subject: "Fix add", status: .pending)],
            [TodoItem(id: "1", subject: "Fix add", status: .pending), TodoItem(id: "2", subject: "Write notes", status: .pending)],
            [TodoItem(id: "1", subject: "Fix add", status: .inProgress), TodoItem(id: "2", subject: "Write notes", status: .pending)],
            [TodoItem(id: "1", subject: "Fix add", status: .completed), TodoItem(id: "2", subject: "Write notes", status: .pending)],
        ])

        let changes = events.compactMap { event -> FileChange? in
            if case .fileChanged(let change) = event { return change }
            return nil
        }
        XCTAssertEqual(changes, [
            FileChange(path: "/private/tmp/ccspike/app.py", hunks: [
                DiffHunk(oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, lines: [
                    DiffLine(kind: .context, text: "def add(a, b):"),
                    DiffLine(kind: .removed, text: "    return a - b"),
                    DiffLine(kind: .added, text: "    return a + b"),
                ]),
            ]),
            FileChange(path: "/private/tmp/ccspike/notes.txt", hunks: [
                DiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 1, lines: [DiffLine(kind: .added, text: "done")]),
            ]),
        ])

        XCTAssertTrue(events.contains(.toolFinished(toolUseId: "toolu_bdrk_01BuRwtxFnbdrPTYub8cNnsy",
                                                    outcome: .failure(message: "Exit code 1"), durationMs: 1250)))

        let subagentEvents = events.filter {
            switch $0 {
            case .subagentStarted, .subagentDescribed, .subagentFinished: return true
            default: return false
            }
        }
        XCTAssertEqual(subagentEvents, [
            .subagentStarted(agentId: "abbe8c2524e79903d", agentType: "general-purpose"),
            .subagentDescribed(agentId: "abbe8c2524e79903d", description: "Reply with OK", agentType: nil),
            .subagentFinished(agentId: "abbe8c2524e79903d"),
        ])

        XCTAssertEqual(events.filter { if case .toolStarted = $0 { return true }; return false }.count, 10)
        XCTAssertEqual(events.filter { if case .toolFinished = $0 { return true }; return false }.count, 10)
        XCTAssertEqual(events.filter { if case .permissionModeChanged = $0 { return true }; return false }.count, 1)
        XCTAssertFalse(events.contains { if case .needsAttention = $0 { return true }; return false },
                       "idle_prompt notifications are not attention requests")
        XCTAssertEqual(events.last, .sessionEnded(reason: "prompt_input_exit"))

        var state = SessionState()
        events.forEach { state.apply($0, at: start) }
        XCTAssertEqual(state.status, .ended)
        XCTAssertEqual(state.todos.map(\.status), [.completed, .pending])
        XCTAssertEqual(state.changes.map(\.path), ["/private/tmp/ccspike/app.py", "/private/tmp/ccspike/notes.txt"])
        XCTAssertEqual(state.subagents.count, 1)
        XCTAssertEqual(state.subagents.first?.description, "Reply with OK")
        XCTAssertEqual(state.subagents.first?.finished, true)
        XCTAssertEqual(state.lastTool?.kind, .agent(description: "Reply with OK"))
        XCTAssertEqual(state.lastMessage, "Finished.")
    }

    func testAskUserQuestionSession() throws {
        let events = try Fixtures.translate("ask-user-question")
        let started = events.compactMap { event -> ToolCall? in
            if case .toolStarted(let call) = event { return call }
            return nil
        }
        XCTAssertEqual(started.map(\.name), ["AskUserQuestion", "ToolSearch", "TaskCreate", "Agent"])
        XCTAssertEqual(started[0].kind, .other(name: "AskUserQuestion"))
        XCTAssertEqual(started[3].kind, .agent(description: "Confirm task creation"))
        XCTAssertTrue(events.contains(.todosChanged([TodoItem(id: "1", subject: "Paint in chosen color", status: .pending)])))
        XCTAssertTrue(events.contains(.subagentDescribed(agentId: "aeb5bb9a1a27b5900", description: "Confirm task creation", agentType: nil)))
        XCTAssertEqual(events.last, .subagentFinished(agentId: "aeb5bb9a1a27b5900"))

        var state = SessionState()
        events.forEach { state.apply($0) }
        XCTAssertEqual(state.subagents.map(\.id), ["aeb5bb9a1a27b5900"], "SubagentStop without SubagentStart still lists the agent")
    }

    func testPermissionRequestsBecomeAttention() throws {
        let events = try Fixtures.translate("permission-request")
        let messages = events.compactMap { event -> String? in
            if case .needsAttention(let message) = event { return message }
            return nil
        }
        XCTAssertEqual(messages, ["Permission needed: $ touch /tmp/ccspike/made.txt",
                                  "Permission needed: $ echo forbidden > /tmp/ccspike/f.txt"])
        var state = SessionState()
        events.forEach { state.apply($0) }
        XCTAssertEqual(state.status, .needsAttention)
        XCTAssertEqual(state.attentionMessage, "Permission needed: $ echo forbidden > /tmp/ccspike/f.txt")
    }

    func testStatusLine() throws {
        let translator = HookTranslator()
        XCTAssertEqual(translator.translate(statusLine: try Fixtures.json("statusline")), [
            .usageUpdated(Usage(modelName: "Haiku 4.5", contextUsedPercent: 12, inputTokens: 23361,
                                outputTokens: 753, costUSD: 0.03296375)),
        ])
        XCTAssertEqual(translator.translate(statusLine: ["model": ["display_name": "Opus 5.5"]]), [
            .usageUpdated(Usage(modelName: "Opus 5.5", contextUsedPercent: nil, inputTokens: 0, outputTokens: 0, costUSD: 0)),
        ])
        XCTAssertEqual(translator.translate(statusLine: .null), [])
    }

    // MARK: Rules not covered by the recordings

    func testClearDropsSessionEndAndResetsTodosForTheNewConversation() {
        var translator = HookTranslator()
        var state = SessionState()
        let payloads: [JSONValue] = [
            ["hook_event_name": "SessionStart", "session_id": "A", "cwd": "/p"],
            ["hook_event_name": "PostToolUse", "session_id": "A", "tool_name": "TaskCreate", "tool_use_id": "t1",
             "tool_input": ["subject": "Old"], "tool_response": ["task": ["id": "1", "subject": "Old"]]],
            ["hook_event_name": "SessionEnd", "session_id": "A", "reason": "clear"],
            ["hook_event_name": "SessionStart", "session_id": "B", "cwd": "/p", "source": "clear"],
            ["hook_event_name": "PostToolUse", "session_id": "B", "tool_name": "TaskCreate", "tool_use_id": "t2",
             "tool_input": ["subject": "New"], "tool_response": ["task": ["id": "2", "subject": "New"]]],
        ]
        let perPayload = payloads.map { translator.translate($0) }
        XCTAssertEqual(perPayload[2], [])
        XCTAssertEqual(perPayload[3], [.sessionStarted(claudeSessionId: "B", cwd: "/p", transcriptPath: nil)])
        XCTAssertEqual(perPayload[4].first, .todosChanged([TodoItem(id: "2", subject: "New", status: .pending)]))
        perPayload.joined().forEach { state.apply($0) }
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.claudeSessionId, "B")
        XCTAssertEqual(state.todos, [TodoItem(id: "2", subject: "New", status: .pending)])
    }

    func testOtherSessionEndReasonsEndTheSession() {
        var translator = HookTranslator()
        XCTAssertEqual(translator.translate(["hook_event_name": "SessionEnd", "reason": "logout"]), [.sessionEnded(reason: "logout")])
    }

    func testPermissionModeIsReportedOnlyWhenItChanges() {
        var translator = HookTranslator()
        let prompt: JSONValue = ["hook_event_name": "UserPromptSubmit", "permission_mode": "default", "prompt": "a"]
        XCTAssertEqual(translator.translate(prompt), [.permissionModeChanged("default"), .promptSubmitted(text: "a")])
        XCTAssertEqual(translator.translate(prompt), [.promptSubmitted(text: "a")])
        XCTAssertEqual(translator.translate(["hook_event_name": "UserPromptSubmit", "permission_mode": "plan", "prompt": "b"]),
                       [.permissionModeChanged("plan"), .promptSubmitted(text: "b")])
    }

    func testLegacyTodoWriteReplacesTheList() {
        var translator = HookTranslator()
        let events = translator.translate([
            "hook_event_name": "PostToolUse", "tool_name": "TodoWrite", "tool_use_id": "t1",
            "tool_input": ["todos": [
                ["content": "Read", "status": "completed", "activeForm": "Reading"],
                ["content": "Fix", "status": "in_progress", "activeForm": "Fixing"],
                ["content": "Ship", "status": "pending", "activeForm": "Shipping"],
            ]],
        ])
        XCTAssertEqual(events, [
            .todosChanged([TodoItem(id: "1", subject: "Read", status: .completed),
                           TodoItem(id: "2", subject: "Fix", status: .inProgress),
                           TodoItem(id: "3", subject: "Ship", status: .pending)]),
            .toolFinished(toolUseId: "t1", outcome: .success, durationMs: nil),
        ])
    }

    func testTaskUpdateDeleteSubjectAndUnknownIds() {
        var translator = HookTranslator()
        _ = translator.translate(["hook_event_name": "PostToolUse", "tool_name": "TaskCreate", "tool_use_id": "t1",
                                  "tool_response": ["task": ["id": 1, "subject": "A"]]])
        XCTAssertEqual(translator.translate(["hook_event_name": "PostToolUse", "tool_name": "TaskUpdate", "tool_use_id": "t2",
                                             "tool_input": ["taskId": "1", "subject": "A2"]]).first,
                       .todosChanged([TodoItem(id: "1", subject: "A2", status: .pending)]))
        XCTAssertEqual(translator.translate(["hook_event_name": "PostToolUse", "tool_name": "TaskUpdate", "tool_use_id": "t3",
                                             "tool_input": ["taskId": "7", "status": "in_progress"]]).first,
                       .todosChanged([TodoItem(id: "1", subject: "A2", status: .pending),
                                      TodoItem(id: "7", subject: "Task 7", status: .inProgress)]))
        XCTAssertEqual(translator.translate(["hook_event_name": "PostToolUse", "tool_name": "TaskUpdate", "tool_use_id": "t4",
                                             "tool_input": ["taskId": "1", "status": "deleted"]]).first,
                       .todosChanged([TodoItem(id: "7", subject: "Task 7", status: .inProgress)]))
    }

    func testNonIdleNotificationNeedsAttention() {
        var translator = HookTranslator()
        XCTAssertEqual(translator.translate(["hook_event_name": "Notification", "notification_type": "permission_prompt",
                                             "message": "Claude needs your permission to use Bash"]),
                       [.needsAttention(message: "Claude needs your permission to use Bash")])
        XCTAssertEqual(translator.translate(["hook_event_name": "Notification", "notification_type": "idle_prompt",
                                             "message": "Claude is waiting for your input"]), [])
    }

    func testUnknownEventsAndMalformedPayloadsAreIgnored() {
        var translator = HookTranslator()
        XCTAssertEqual(translator.translate(["hook_event_name": "PreCompact"]), [])
        XCTAssertEqual(translator.translate(["no_event": true]), [])
        XCTAssertEqual(translator.translate("garbage"), [])
        XCTAssertEqual(translator.translate(["hook_event_name": "PreToolUse", "tool_name": "Bash"]), [],
                       "no tool_use_id → nothing to track")
    }

    func testToolClassifier() {
        XCTAssertEqual(ToolClassifier.kind(name: "Read", input: ["file_path": "/a/b.swift"]), .read(path: "/a/b.swift"))
        XCTAssertEqual(ToolClassifier.kind(name: "Grep", input: ["pattern": "TODO"]), .search(pattern: "TODO"))
        XCTAssertEqual(ToolClassifier.kind(name: "Glob", input: ["pattern": "**/*.py"]), .search(pattern: "**/*.py"))
        XCTAssertEqual(ToolClassifier.kind(name: "Edit", input: ["file_path": "/a"]), .edit(path: "/a"))
        XCTAssertEqual(ToolClassifier.kind(name: "MultiEdit", input: ["file_path": "/a"]), .edit(path: "/a"))
        XCTAssertEqual(ToolClassifier.kind(name: "NotebookEdit", input: ["notebook_path": "/n.ipynb"]), .edit(path: "/n.ipynb"))
        XCTAssertEqual(ToolClassifier.kind(name: "Write", input: ["file_path": "/a"]), .write(path: "/a"))
        XCTAssertEqual(ToolClassifier.kind(name: "Bash", input: ["command": "ls"]), .shell(command: "ls", description: nil))
        XCTAssertEqual(ToolClassifier.kind(name: "WebFetch", input: ["url": "https://x.dev"]), .web(target: "https://x.dev"))
        XCTAssertEqual(ToolClassifier.kind(name: "WebSearch", input: ["query": "swift"]), .web(target: "swift"))
        XCTAssertEqual(ToolClassifier.kind(name: "Task", input: ["description": "Review"]), .agent(description: "Review"))
        XCTAssertEqual(ToolClassifier.kind(name: "mcp__x__y", input: nil), .other(name: "mcp__x__y"))
    }
}
