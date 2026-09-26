import XCTest
@testable import AgentMasterCore

final class JSONValueTests: XCTestCase {
    func testDecodesAllKindsAndKeepsBoolsDistinctFromNumbers() throws {
        let value = try JSONValue.parse(Data(#"{"a":1,"b":true,"c":"x","d":[null,2.5],"e":{"f":false}}"#.utf8))
        XCTAssertEqual(value, ["a": 1, "b": true, "c": "x", "d": [nil, 2.5], "e": ["f": false]])
    }

    func testAccessorsReturnNilOnKindMismatch() throws {
        let value: JSONValue = ["a": 1, "b": true, "c": "x", "d": [nil, 2.5]]
        XCTAssertEqual(value["a"]?.intValue, 1)
        XCTAssertEqual(value["b"]?.boolValue, true)
        XCTAssertNil(value["b"]?.intValue)
        XCTAssertEqual(value["c"]?.stringValue, "x")
        XCTAssertNil(value["c"]?["nested"])
        XCTAssertEqual(value["d"]?[1]?.doubleValue, 2.5)
        XCTAssertNil(value["d"]?[5])
        XCTAssertEqual(value["d"]?.arrayValue?.count, 2)
        XCTAssertEqual(value.objectValue?.count, 4)
        XCTAssertNil(value["missing"])
    }

    func testIntValueTruncatesButIsNilWhenOutOfRange() throws {
        XCTAssertEqual(JSONValue.number(3.9).intValue, 3)
        XCTAssertEqual(JSONValue.number(-3.9).intValue, -3)
        XCTAssertNil(try JSONValue.parse(Data(#"{"n":1e20}"#.utf8))["n"]?.intValue)
        XCTAssertNil(JSONValue.number(-1e20).intValue)
        XCTAssertNil(JSONValue.number(9_223_372_036_854_775_808).intValue)   // 2^63
        XCTAssertNil(JSONValue.number(.infinity).intValue)
        XCTAssertNil(JSONValue.number(.nan).intValue)
    }

    func testRoundTripsThroughEncoding() throws {
        let value: JSONValue = ["s": "a/b \"q\"\n", "n": 1674, "f": 0.03296375, "z": nil, "arr": [true, "x"]]
        XCTAssertEqual(try JSONValue.parse(value.encoded()), value)
    }
}
