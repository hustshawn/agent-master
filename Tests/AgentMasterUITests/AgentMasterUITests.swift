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

    func testPreviewStateExercisesEveryPanel() {
        let state = PreviewData.state
        XCTAssertFalse(state.todos.isEmpty)
        XCTAssertFalse(state.subagents.isEmpty)
        XCTAssertFalse(state.changes.isEmpty)
        XCTAssertNotNil(state.usage)
    }
}
