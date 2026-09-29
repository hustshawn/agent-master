import Foundation
import AgentMasterCore

public enum PreviewData {
    public static var state: SessionState {
        let start = Date().addingTimeInterval(-42)
        var state = SessionState()
        let events: [SessionEvent] = [
            .sessionStarted(agentSessionId: "preview", cwd: "/Users/me/my-proj", transcriptPath: nil),
            .permissionModeChanged("default"),
            .promptSubmitted(text: "Fix add()"),
            .todosChanged([
                TodoItem(id: "1", subject: "Read app.py", status: .completed),
                TodoItem(id: "2", subject: "Fix add()", status: .inProgress),
                TodoItem(id: "3", subject: "Run script", status: .pending),
            ]),
            .subagentStarted(agentId: "a1", agentType: "general-purpose"),
            .subagentDescribed(agentId: "a1", description: "reviewer", agentType: nil),
            .fileChanged(FileChange(path: "/Users/me/my-proj/app.py", hunks: [
                DiffHunk(oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, lines: [
                    DiffLine(kind: .context, text: "def add(a, b):"),
                    DiffLine(kind: .removed, text: "    return a - b"),
                    DiffLine(kind: .added, text: "    return a + b"),
                ]),
            ])),
            .usageUpdated(Usage(modelName: "Opus 5.5", contextUsedPercent: 34, inputTokens: 48_200,
                                outputTokens: 1_600, costUSD: 0.12)),
        ]
        events.forEach { state.apply($0, at: start) }
        return state
    }
}
