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
            .tool(name: "Read", input: #"{"file_path":"app/main.py"}"#, id: "t1"),
            .toolResult("from fastapi import FastAPI", id: "t1"),
            .tool(name: "Bash", input: #"{"command":"pytest"}"#, id: "t2"),
            .toolResult("1 passed", id: "t2"),
            .assistant("Added the endpoint."),
        ])
    }

    func testCodexSkipsInjectedInstructionsAndReasoning() throws {
        XCTAssertEqual(TranscriptParser.codex(try fixture("codex-transcript")), [
            .user("Fix formatPrice"),
            .tool(name: "exec_command", input: #"{"cmd":"cat src/format.ts"}"#, id: "c1"),
            .toolResult("export function formatPrice", id: "c1"),
            .tool(name: "apply_patch", input: "*** Begin Patch", id: "c2"),
            .toolResult("Success", id: "c2"),
            .assistant("Fixed it."),
        ])
    }

    func testKiroKeepsTextOfPromptsAndDropsImagesAndEmptyText() throws {
        XCTAssertEqual(TranscriptParser.kiro(try fixture("kiro-transcript")), [
            .user("Sort the rows"),
            .assistant("Let me look."),
            .tool(name: "read", input: #"{"path":"main.go"}"#, id: "u1"),
            .toolResult("package main", id: "u1"),
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

    /// Recorded from kiro-cli 2.37 on the V3 engine, without its system prompt and context snapshots.
    func testKiroV3KeepsPromptsRepliesAndToolsButNotReasoning() throws {
        let entries = TranscriptParser.kiroV3(try fixture("kiro-v3-transcript"))
        guard case let .user(prompt) = entries.first else { return XCTFail("\(entries)") }
        XCTAssertTrue(prompt.hasPrefix("Do exactly these steps"))
        XCTAssertEqual(entries.last, .assistant("FINISHED"))
        XCTAssertFalse(entries.contains(.assistant("...")), "reasoning is not a reply")
        let tools = entries.compactMap { entry -> String? in
            if case let .tool(name, _, _) = entry { return name } else { return nil }
        }
        XCTAssertEqual(tools, ["fs_write", "str_replace", "fs_append", "execute_bash", "grep_search", "file_search", "delete_file"])
        guard case let .tool(_, input, id) = entries[1], case let .toolResult(result, resultId) = entries[2] else {
            return XCTFail("\(entries)")
        }
        XCTAssertTrue(input.contains("notes.txt"), input)
        XCTAssertEqual(result, "Created the /private/tmp/kiro-lab-v3/proj/notes.txt file.")
        XCTAssertEqual(resultId, id)
    }

    func testKiroReadsAV3ConversationAtTheReportedPath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiro-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try fixture("kiro-v3-transcript").write(to: dir.appendingPathComponent("messages.jsonl"))
        XCTAssertEqual(KiroAgent().transcript(at: dir.appendingPathComponent("messages.jsonl").path).last, .assistant("FINISHED"))
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
