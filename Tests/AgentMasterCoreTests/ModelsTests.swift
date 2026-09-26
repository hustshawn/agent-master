import XCTest
@testable import AgentMasterCore

final class ModelsTests: XCTestCase {
    func testToolTitles() {
        XCTAssertEqual(ToolKind.read(path: "/p/app.py").title, "Read app.py")
        XCTAssertEqual(ToolKind.search(pattern: "TODO").title, "Search TODO")
        XCTAssertEqual(ToolKind.edit(path: "/p/app.py").title, "Edit app.py")
        XCTAssertEqual(ToolKind.write(path: "/p/notes.txt").title, "Write notes.txt")
        XCTAssertEqual(ToolKind.shell(command: "echo hi", description: nil).title, "$ echo hi")
        XCTAssertEqual(ToolKind.web(target: "https://x.dev").title, "Fetch https://x.dev")
        XCTAssertEqual(ToolKind.agent(description: "Review").title, "Agent Review")
        XCTAssertEqual(ToolKind.other(name: "ToolSearch").title, "ToolSearch")
        XCTAssertEqual(ToolKind.read(path: "").title, "Read")
    }

    func testFileChangeCountsAddedAndRemovedAcrossHunks() {
        let change = FileChange(path: "a", hunks: [
            DiffHunk(oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, lines: [
                DiffLine(kind: .context, text: "x"), DiffLine(kind: .removed, text: "y"), DiffLine(kind: .added, text: "z"),
            ]),
            DiffHunk(oldStart: 9, oldLines: 0, newStart: 9, newLines: 1, lines: [DiffLine(kind: .added, text: "w")]),
        ])
        XCTAssertEqual(change.added, 2)
        XCTAssertEqual(change.removed, 1)
        XCTAssertEqual(change.id, "a")
    }

    func testTokenFormat() {
        XCTAssertEqual(TokenFormat.short(753), "753")
        XCTAssertEqual(TokenFormat.short(1000), "1k")
        XCTAssertEqual(TokenFormat.short(1600), "1.6k")
        XCTAssertEqual(TokenFormat.short(23361), "23.4k")
        XCTAssertEqual(TokenFormat.short(1_250_000), "1.2M")
    }

    func testDurationFormat() {
        XCTAssertEqual(DurationFormat.short(3.7), "3s")
        XCTAssertEqual(DurationFormat.short(65), "1m 5s")
        XCTAssertEqual(DurationFormat.short(3720), "1h 2m")
    }

    func testSubagentElapsedStopsAtFinish() {
        let start = Date(timeIntervalSince1970: 100)
        var agent = SubagentInfo(id: "a", type: "general-purpose", startedAt: start)
        XCTAssertEqual(agent.elapsed(at: start.addingTimeInterval(4)), 4)
        XCTAssertFalse(agent.finished)
        agent.finishedAt = start.addingTimeInterval(2)
        XCTAssertTrue(agent.finished)
        XCTAssertEqual(agent.elapsed(at: start.addingTimeInterval(60)), 2)
    }

    func testThemeHexParsingAndPalette() {
        let accent = Theme.rgb(Theme.accent)
        XCTAssertEqual(accent?.r, 90)
        XCTAssertEqual(accent?.g, 160)
        XCTAssertEqual(accent?.b, 255)
        XCTAssertNil(Theme.rgb("#12345"))
        XCTAssertNil(Theme.rgb("zzzzzz"))
        XCTAssertEqual(Theme.ansi.count, 16)
        XCTAssertTrue(Theme.ansi.allSatisfy { Theme.rgb($0) != nil })
    }
}
