import XCTest
@testable import AgentMasterBridge

final class TranscriptTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testClaudeKeepsPromptsRepliesAndToolsButNotCommandsOrMeta() throws {
        XCTAssertEqual(TranscriptParser.claude(try fixture("claude-transcript")), [
            .user("Add a POST /orders endpoint"),
            .tool(name: "Read", input: #"{"file_path":"app/main.py"}"#),
            .toolResult("from fastapi import FastAPI"),
            .tool(name: "Bash", input: #"{"command":"pytest"}"#),
            .toolResult("1 passed"),
            .assistant("Added the endpoint."),
        ])
    }

    func testCodexSkipsInjectedInstructionsAndReasoning() throws {
        XCTAssertEqual(TranscriptParser.codex(try fixture("codex-transcript")), [
            .user("Fix formatPrice"),
            .tool(name: "exec_command", input: #"{"cmd":"cat src/format.ts"}"#),
            .toolResult("export function formatPrice"),
            .tool(name: "apply_patch", input: "*** Begin Patch"),
            .toolResult("Success"),
            .assistant("Fixed it."),
        ])
    }

    func testKiroKeepsTextOfPromptsAndDropsImagesAndEmptyText() throws {
        XCTAssertEqual(TranscriptParser.kiro(try fixture("kiro-transcript")), [
            .user("Sort the rows"),
            .assistant("Let me look."),
            .tool(name: "read", input: #"{"path":"main.go"}"#),
            .toolResult("package main"),
            .assistant("Sorted."),
        ])
    }

    func testKiroReadsTheConversationBesideTheReportedMetadataFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiro-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"session_id":"s"}"#.utf8).write(to: dir.appendingPathComponent("s.json"))
        try fixture("kiro-transcript").write(to: dir.appendingPathComponent("s.jsonl"))
        XCTAssertEqual(KiroAgent().transcript(at: dir.appendingPathComponent("s.json").path).first, .user("Sort the rows"))
    }

    func testConversationLabelsEachEntryAndCutsLongParts() {
        let text = SessionSummary.conversation([
            .user("hi"), .tool(name: "Bash", input: "ls"),
            .toolResult(String(repeating: "x", count: SessionSummary.toolResultLimit + 50)), .assistant("done"),
        ])
        XCTAssertEqual(text, "USER: hi\n\nTOOL Bash: ls\n\nRESULT: "
                       + String(repeating: "x", count: SessionSummary.toolResultLimit) + " […]\n\nAGENT: done")
    }

    func testLongConversationKeepsItsStartAndEnd() {
        let entries = (0..<200).map { TranscriptEntry.assistant("\($0) " + String(repeating: "y", count: 3_000)) }
        let text = SessionSummary.conversation([.user("the task")] + entries)
        XCTAssertTrue(text.hasPrefix("USER: the task"))
        XCTAssertTrue(text.hasSuffix(String(repeating: "y", count: 100)))
        XCTAssertTrue(text.contains("characters omitted"))
        XCTAssertLessThan(text.count, SessionSummary.conversationLimit + 100)
    }
}
