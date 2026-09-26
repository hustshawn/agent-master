import XCTest
import AgentMasterCore
@testable import AgentMasterBridge

final class PatchParserTests: XCTestCase {
    func testParsesStructuredPatchHunks() {
        let response: JSONValue = [
            "filePath": "/p/app.py",
            "structuredPatch": [
                ["oldStart": 1, "oldLines": 2, "newStart": 1, "newLines": 2,
                 "lines": [" def add(a, b):", "-    return a - b", "+    return a + b", "\\ No newline at end of file"]],
                ["oldStart": 10, "oldLines": 0, "newStart": 10, "newLines": 1, "lines": ["+x"]],
            ],
        ]
        XCTAssertEqual(PatchParser.change(fromToolResponse: response), FileChange(path: "/p/app.py", hunks: [
            DiffHunk(oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, lines: [
                DiffLine(kind: .context, text: "def add(a, b):"),
                DiffLine(kind: .removed, text: "    return a - b"),
                DiffLine(kind: .added, text: "    return a + b"),
            ]),
            DiffHunk(oldStart: 10, oldLines: 0, newStart: 10, newLines: 1, lines: [DiffLine(kind: .added, text: "x")]),
        ]))
    }

    func testNewFileBecomesOneAddedHunk() {
        let response: JSONValue = ["type": "create", "filePath": "/p/n.txt", "content": "a\nb\n", "structuredPatch": []]
        XCTAssertEqual(PatchParser.change(fromToolResponse: response), FileChange(path: "/p/n.txt", hunks: [
            DiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 2,
                     lines: [DiffLine(kind: .added, text: "a"), DiffLine(kind: .added, text: "b")]),
        ]))
        let empty: JSONValue = ["type": "create", "filePath": "/p/e.txt", "content": "", "structuredPatch": []]
        XCTAssertEqual(PatchParser.change(fromToolResponse: empty), FileChange(path: "/p/e.txt", hunks: []))
    }

    func testNoPathOrNoOpEditYieldsNothing() {
        XCTAssertNil(PatchParser.change(fromToolResponse: ["structuredPatch": []]))
        XCTAssertNil(PatchParser.change(fromToolResponse: ["type": "update", "filePath": "/p/x", "structuredPatch": []]))
        XCTAssertNil(PatchParser.change(fromToolResponse: "Error: file not found"))
    }
}
