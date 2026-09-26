import XCTest
@testable import AgentMasterCore

final class SessionStateTests: XCTestCase {
    private let bash = ToolCall(id: "t1", name: "Bash", kind: .shell(command: "echo hi", description: nil))
    private let t0 = Date(timeIntervalSince1970: 1000)

    func testTurnLifecycle() {
        var state = SessionState()
        XCTAssertEqual(state.status, .starting)
        state.apply(.sessionStarted(claudeSessionId: "s1", cwd: "/p", transcriptPath: "/t.jsonl"))
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.claudeSessionId, "s1")
        XCTAssertEqual(state.transcriptPath, "/t.jsonl")
        state.apply(.promptSubmitted(text: "hi"))
        XCTAssertEqual(state.status, .running)
        state.apply(.toolStarted(bash))
        XCTAssertEqual(state.runningTools, [bash])
        XCTAssertEqual(state.lastTool, bash)
        state.apply(.toolFinished(toolUseId: "t1", outcome: .success, durationMs: 5))
        XCTAssertEqual(state.runningTools, [])
        state.apply(.turnFinished(lastMessage: "done"))
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.lastMessage, "done")
    }

    func testTurnFinishedClearsToolsThatNeverFinished() {
        var state = SessionState()
        state.apply(.toolStarted(bash))
        state.apply(.turnFinished(lastMessage: nil))
        XCTAssertEqual(state.runningTools, [])
        state.apply(.turnFinished(lastMessage: nil))
        XCTAssertEqual(state.status, .idle)
    }

    func testAttentionIsSetAndClearedByProgress() {
        var state = SessionState()
        state.apply(.toolStarted(bash))
        state.apply(.needsAttention(message: "Permission needed: $ echo hi"))
        XCTAssertEqual(state.status, .needsAttention)
        XCTAssertEqual(state.attentionMessage, "Permission needed: $ echo hi")
        state.apply(.toolFinished(toolUseId: "t1", outcome: .success, durationMs: nil))
        XCTAssertEqual(state.status, .running)
        XCTAssertNil(state.attentionMessage)
        state.apply(.needsAttention(message: "again"))
        state.apply(.promptSubmitted(text: "go"))
        XCTAssertEqual(state.status, .running)
        XCTAssertNil(state.attentionMessage)
    }

    func testFileChangesMergePerPathInFirstSeenOrder() {
        var state = SessionState()
        let hunkA = DiffHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: [DiffLine(kind: .added, text: "a")])
        let hunkB = DiffHunk(oldStart: 5, oldLines: 1, newStart: 5, newLines: 0, lines: [DiffLine(kind: .removed, text: "b")])
        state.apply(.fileChanged(FileChange(path: "/p/x", hunks: [hunkA])))
        state.apply(.fileChanged(FileChange(path: "/p/y", hunks: [hunkA])))
        state.apply(.fileChanged(FileChange(path: "/p/x", hunks: [hunkB])))
        XCTAssertEqual(state.changes.map(\.path), ["/p/x", "/p/y"])
        XCTAssertEqual(state.changes[0].hunks, [hunkA, hunkB])
    }

    func testSubagentLifecycleInAnyOrder() {
        var state = SessionState()
        state.apply(.subagentStarted(agentId: "a1", agentType: "general-purpose"), at: t0)
        state.apply(.subagentDescribed(agentId: "a1", description: "Review", agentType: nil), at: t0.addingTimeInterval(1))
        state.apply(.subagentFinished(agentId: "a1"), at: t0.addingTimeInterval(3))
        state.apply(.subagentFinished(agentId: "a1"), at: t0.addingTimeInterval(9))
        XCTAssertEqual(state.subagents, [SubagentInfo(id: "a1", type: "general-purpose", description: "Review",
                                                      startedAt: t0, finishedAt: t0.addingTimeInterval(3))])

        state.apply(.subagentDescribed(agentId: "a2", description: "Late", agentType: "Explore"), at: t0)
        state.apply(.subagentFinished(agentId: "a3"), at: t0)
        XCTAssertEqual(state.subagents[1], SubagentInfo(id: "a2", type: "Explore", description: "Late", startedAt: t0))
        XCTAssertEqual(state.subagents[2], SubagentInfo(id: "a3", type: "agent", startedAt: t0, finishedAt: t0))
    }

    func testNewClaudeSessionIdResetsPanelsButSameIdDoesNot() {
        var state = SessionState()
        state.apply(.sessionStarted(claudeSessionId: "s1", cwd: "/p", transcriptPath: nil))
        state.apply(.todosChanged([TodoItem(id: "1", subject: "x", status: .pending)]))
        state.apply(.sessionStarted(claudeSessionId: "s1", cwd: "/p", transcriptPath: nil))
        XCTAssertEqual(state.todos.count, 1)
        state.apply(.subagentStarted(agentId: "a", agentType: "t"))
        state.apply(.fileChanged(FileChange(path: "f", hunks: [])))
        state.apply(.sessionStarted(claudeSessionId: "s2", cwd: "/p", transcriptPath: nil))
        XCTAssertEqual(state.todos, [])
        XCTAssertEqual(state.subagents, [])
        XCTAssertEqual(state.changes, [])
        XCTAssertEqual(state.claudeSessionId, "s2")
        XCTAssertEqual(state.status, .idle)
    }

    func testEndedIsStickyUntilSessionStarts() {
        var state = SessionState()
        state.apply(.toolStarted(bash))
        state.apply(.sessionEnded(reason: "prompt_input_exit"))
        XCTAssertEqual(state.status, .ended)
        XCTAssertEqual(state.endReason, "prompt_input_exit")
        XCTAssertEqual(state.runningTools, [])
        state.apply(.turnFinished(lastMessage: nil))
        state.apply(.needsAttention(message: "x"))
        XCTAssertEqual(state.status, .ended)
        state.apply(.sessionStarted(claudeSessionId: "s9", cwd: "/p", transcriptPath: nil))
        XCTAssertEqual(state.status, .idle)
        XCTAssertNil(state.endReason)
    }

    func testUsageAndPermissionMode() {
        var state = SessionState()
        let usage = Usage(modelName: "Haiku 4.5", contextUsedPercent: 12, inputTokens: 1, outputTokens: 2, costUSD: 0.5)
        state.apply(.usageUpdated(usage))
        state.apply(.permissionModeChanged("plan"))
        XCTAssertEqual(state.usage, usage)
        XCTAssertEqual(state.permissionMode, "plan")
    }
}
