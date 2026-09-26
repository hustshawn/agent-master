import XCTest
import AgentMasterCore
@testable import AgentMasterWire

final class WireCodecTests: XCTestCase {
    func testMessageRoundTripsAsASingleLine() throws {
        let message = WireMessage(id: "m1", sessionId: "S1", kind: .request,
                                  payload: ["hook_event_name": "PreToolUse", "prompt": "line1\nline2"])
        let line = try WireCodec.encodeLine(message)
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1)
        XCTAssertEqual(try WireCodec.decode(WireMessage.self, line: line.dropLast()), message)
    }

    func testReplyWithoutOutputRoundTrips() throws {
        let reply = WireReply(id: "m1", output: nil)
        let line = try WireCodec.encodeLine(reply)
        XCTAssertEqual(String(decoding: line, as: UTF8.self), "{\"id\":\"m1\"}\n")
        XCTAssertEqual(try WireCodec.decode(WireReply.self, line: line.dropLast()), reply)
        XCTAssertEqual(try WireCodec.decode(WireReply.self, line: Data(#"{"id":"m2","output":"{}"}"#.utf8)),
                       WireReply(id: "m2", output: "{}"))
    }

    func testLineBufferSplitsAcrossChunksAndSkipsBlankLines() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("ab".utf8)), [])
        XCTAssertEqual(buffer.append(Data("c\n\nde\nf".utf8)), [Data("abc".utf8), Data("de".utf8)])
        XCTAssertEqual(buffer.append(Data("g\n".utf8)), [Data("fg".utf8)])
    }
}
