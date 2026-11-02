import XCTest
import AgentMasterBridge
@testable import AgentMasterServerKit

final class ChatTests: XCTestCase {
    func testToolResultsJoinTheirCallsByIdEvenOutOfOrder() {
        let items = Chat.items([
            .user("Fix it"),
            .tool(name: "Read", input: #"{"file_path":"/a/Login.swift"}"#, id: "t1"),
            .tool(name: "Bash", input: #"{"command":"swift test"}"#, id: "t2"),
            .toolResult("2 passed", id: "t2"),
            .toolResult("struct Login {}", id: "t1"),
            .assistant("Fixed."),
        ])
        XCTAssertEqual(items, [
            ChatItemJSON(kind: "user", text: "Fix it"),
            ChatItemJSON(kind: "tool", name: "Read", title: "Read Login.swift", input: #"{"file_path":"/a/Login.swift"}"#,
                         output: "struct Login {}"),
            ChatItemJSON(kind: "tool", name: "Bash", title: "$ swift test", input: #"{"command":"swift test"}"#, output: "2 passed"),
            ChatItemJSON(kind: "assistant", text: "Fixed."),
        ])
    }

    /// Each agent keeps its own tool names in its transcript; the chat titles them the way the panels do.
    func testStepsAreTitledFromEachAgentsOwnToolNames() {
        func titles(_ agent: any AgentKind, _ entries: [TranscriptEntry]) -> [String?] {
            Chat.items(entries, toolKind: agent.toolKind).map(\.title)
        }
        // As codex 0.166 writes them: a command's arguments are JSON, a patch is plain text.
        XCTAssertEqual(titles(CodexAgent(), [
            .tool(name: "exec_command", input: #"{"cmd":"cat notes.txt","workdir":"/p","max_output_tokens":4000}"#),
            .tool(name: "exec_command", input: #"{"cmd":["bash","-lc","swift test"]}"#),
            .tool(name: "apply_patch", input: "*** Begin Patch\n*** Update File: Sources/Login.swift\n@@\n-a\n+b\n*** End Patch"),
            .tool(name: "apply_patch", input: "*** Begin Patch\n*** Add File: notes.txt\n+one\n*** End Patch"),
            .tool(name: "view_image", input: #"{"path":"/p/shot.png"}"#),
            .tool(name: "browser_navigate", input: #"{"url":"https://example.com"}"#),
        ]), ["$ cat notes.txt", "$ swift test", "Edit Login.swift", "Write notes.txt", "Read shot.png", "browser_navigate"])
        // Kiro's V2 names, then its V3 ones.
        XCTAssertEqual(titles(KiroAgent(), [
            .tool(name: "read", input: #"{"path":"/p/main.go"}"#),
            .tool(name: "shell", input: #"{"command":"go test","__tool_use_purpose":"Run the tests"}"#),
            .tool(name: "fs_write", input: #"{"path":"/p/notes.txt","text":"one"}"#),
            .tool(name: "execute_bash", input: #"{"command":"echo hi"}"#),
            .tool(name: "use_aws", input: #"{"service_name":"s3"}"#),
        ]), ["Read main.go", "$ go test", "Write notes.txt", "$ echo hi", "use_aws"])
        XCTAssertEqual(titles(ClaudeCodeAgent(), [.tool(name: "Read", input: #"{"file_path":"/a/Login.swift"}"#)]),
                       ["Read Login.swift"])
    }

    func testAResultWithoutAnIdGoesToTheEarliestWaitingCall() {
        let items = Chat.items([.tool(name: "a", input: ""), .tool(name: "b", input: ""), .toolResult("first")])
        XCTAssertEqual(items.map(\.output), ["first", nil])
    }

    func testLongToolTextIsCut() {
        let items = Chat.items([.tool(name: "Bash", input: "x", id: "t"), .toolResult(String(repeating: "y", count: 5_000), id: "t")])
        XCTAssertEqual(items[0].output?.count, Chat.outputLimit + " […]".count)
    }

    func testAPageRestartsAtACallThatWasStillWaiting() {
        let items = Chat.items([.user("go"), .tool(name: "Bash", input: "", id: "t"), .assistant("working")])
        XCTAssertEqual(Chat.page(items, after: 0), ChatJSON(start: 0, total: 3, items: items))
        XCTAssertEqual(Chat.page(items, after: 3).start, 1, "the tool row may have its result now")
        let done = Chat.items([.user("go"), .tool(name: "Bash", input: "", id: "t"), .toolResult("ok", id: "t")])
        XCTAssertEqual(Chat.page(done, after: 2), ChatJSON(start: 2, total: 2, items: []))
        XCTAssertEqual(Chat.page(done, after: 99).start, 2)
    }
}
