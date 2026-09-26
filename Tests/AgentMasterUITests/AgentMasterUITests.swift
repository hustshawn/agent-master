import XCTest
import AgentMasterCore
@testable import AgentMasterUI

final class AgentMasterUITests: XCTestCase {
    func testSessionGlyphs() {
        XCTAssertEqual(StatusGlyph.symbol(for: SessionStatus.running), "◈")
        XCTAssertEqual(StatusGlyph.symbol(for: SessionStatus.starting), "◈")
        XCTAssertEqual(StatusGlyph.symbol(for: SessionStatus.needsAttention), "◆")
        XCTAssertEqual(StatusGlyph.symbol(for: SessionStatus.idle), "◇")
        XCTAssertEqual(StatusGlyph.symbol(for: SessionStatus.ended), "✓")
        XCTAssertEqual(StatusGlyph.colorHex(for: SessionStatus.needsAttention), Theme.accent)
        XCTAssertEqual(StatusGlyph.colorHex(for: SessionStatus.running), Theme.teal)
        XCTAssertEqual(StatusGlyph.colorHex(for: SessionStatus.idle), Theme.muted)
        XCTAssertEqual(StatusGlyph.colorHex(for: SessionStatus.ended), Theme.success)
    }

    func testTodoGlyphs() {
        XCTAssertEqual(StatusGlyph.symbol(for: TodoStatus.completed), "✓")
        XCTAssertEqual(StatusGlyph.symbol(for: TodoStatus.inProgress), "◆")
        XCTAssertEqual(StatusGlyph.symbol(for: TodoStatus.pending), "◇")
        XCTAssertEqual(StatusGlyph.colorHex(for: TodoStatus.completed), Theme.success)
        XCTAssertEqual(StatusGlyph.colorHex(for: TodoStatus.inProgress), Theme.teal)
        XCTAssertEqual(StatusGlyph.colorHex(for: TodoStatus.pending), Theme.muted)
    }

    func testGroupingOrdersProjectsAndRowsNewestFirst() {
        func row(_ id: String, _ project: String, _ minute: Double) -> SessionRowModel {
            SessionRowModel(id: id, projectPath: project, title: id, status: .idle,
                            createdAt: Date(timeIntervalSince1970: minute * 60))
        }
        let groups = SessionGrouping.group([
            row("a1", "/w/alpha", 1), row("b1", "/w/beta", 2), row("a2", "/w/alpha", 3), row("c1", "/x/alpha", 0),
        ])
        XCTAssertEqual(groups.map(\.id), ["/w/alpha", "/w/beta", "/x/alpha"])
        XCTAssertEqual(groups.map(\.name), ["alpha", "beta", "alpha"])
        XCTAssertEqual(groups[0].rows.map(\.id), ["a2", "a1"])
        XCTAssertEqual(SessionGrouping.group([]), [])
    }

    func testSelectionAfterClosingPrefersTheSameProject() {
        func row(_ id: String, _ project: String, _ minute: Double) -> SessionRowModel {
            SessionRowModel(id: id, projectPath: project, title: id, status: .idle,
                            createdAt: Date(timeIntervalSince1970: minute * 60))
        }
        // Display order: alpha [a3, a2, a1], beta [b1].
        let rows = [row("a1", "/w/alpha", 1), row("b1", "/w/beta", 2), row("a2", "/w/alpha", 3), row("a3", "/w/alpha", 4)]
        XCTAssertEqual(SessionGrouping.selectionAfterClosing("a2", in: rows), "a1", "next in the group")
        XCTAssertEqual(SessionGrouping.selectionAfterClosing("a1", in: rows), "a2", "previous when it was last")
        XCTAssertEqual(SessionGrouping.selectionAfterClosing("b1", in: rows), "a3", "first row when the group empties")
        XCTAssertNil(SessionGrouping.selectionAfterClosing("b1", in: [row("b1", "/w/beta", 2)]))
        XCTAssertEqual(SessionGrouping.selectionAfterClosing("zz", in: rows), "a3", "unknown id falls back to the first row")
    }

    func testSessionSubtitleSummarisesStatus() {
        var state = SessionState()
        XCTAssertEqual(SessionSubtitle.text(for: state), "starting")

        state.status = .running
        XCTAssertEqual(SessionSubtitle.text(for: state), "running")
        state.runningTools = [ToolCall(id: "t1", name: "Read", kind: .read(path: "a")),
                              ToolCall(id: "t2", name: "Bash", kind: .shell(command: "ls", description: nil))]
        XCTAssertEqual(SessionSubtitle.text(for: state), "running · Bash")

        state.status = .needsAttention
        state.attentionMessage = "Claude needs your permission to use Bash"
        XCTAssertEqual(SessionSubtitle.text(for: state), "needs you · Claude needs your permission to use Bash")

        state.status = .idle
        XCTAssertEqual(SessionSubtitle.text(for: state), "idle")
        state.usage = Usage(modelName: "Opus 5.5", contextUsedPercent: 2, inputTokens: 1, outputTokens: 1, costUSD: 0)
        XCTAssertEqual(SessionSubtitle.text(for: state), "idle · Opus 5.5")

        state.status = .ended
        XCTAssertEqual(SessionSubtitle.text(for: state), "ended")
    }

    func testPreviewStateExercisesEveryPanel() {
        let state = PreviewData.state
        XCTAssertFalse(state.todos.isEmpty)
        XCTAssertFalse(state.subagents.isEmpty)
        XCTAssertFalse(state.changes.isEmpty)
        XCTAssertNotNil(state.usage)
    }

    func testChoiceSelectionMapsStoredValuesToPickerTags() {
        let choices = [AgentChoice(value: "opus"), AgentChoice(value: "sonnet")]
        func tag(_ value: String?, custom: Bool = true, active: Bool = false) -> String {
            AgentChoiceSelection.tag(for: value, choices: choices, allowsCustom: custom, customActive: active)
        }
        XCTAssertEqual(tag(nil), AgentChoiceSelection.followTag)
        XCTAssertEqual(tag("opus"), "opus")
        XCTAssertEqual(tag("us.anthropic.claude-opus-5-5[1m]"), AgentChoiceSelection.customTag, "unknown value shows as custom")
        XCTAssertEqual(tag(nil, active: true), AgentChoiceSelection.customTag, "custom picked but nothing typed yet")
        XCTAssertEqual(tag("opus", active: true), AgentChoiceSelection.customTag, "known value while custom is active → customTag")
        XCTAssertEqual(tag("yolo", custom: false), AgentChoiceSelection.followTag, "no custom row: unknown value follows")
        XCTAssertNotEqual(AgentChoiceSelection.customTag, "custom", "cannot collide with a real value")
    }
}
