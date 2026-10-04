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
