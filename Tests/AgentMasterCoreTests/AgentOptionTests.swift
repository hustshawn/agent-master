import XCTest
@testable import AgentMasterCore

final class AgentOptionTests: XCTestCase {
    func testChoiceLabelDefaultsToValue() {
        XCTAssertEqual(AgentChoice(value: "opus").label, "opus")
        XCTAssertEqual(AgentChoice(value: "manual", label: "manual (default)").label, "manual (default)")
        XCTAssertNil(AgentChoice(value: "opus").detail)
    }

    func testStringTrimsAndTreatsBlankAsMissing() {
        let prefs = AgentPreferences(values: ["model": "  opus \n", "blank": "   ", "empty": ""])
        XCTAssertEqual(prefs.string("model"), "opus")
        XCTAssertNil(prefs.string("blank"))
        XCTAssertNil(prefs.string("empty"))
        XCTAssertNil(prefs.string("missing"))
    }

    func testBoolParsesTrueFalseAndFallsBack() {
        let prefs = AgentPreferences(values: ["on": "true", "off": "false", "junk": "yes"])
        XCTAssertTrue(prefs.bool("on", default: false))
        XCTAssertFalse(prefs.bool("off", default: true))
        XCTAssertTrue(prefs.bool("junk", default: true))
        XCTAssertFalse(prefs.bool("missing", default: false))
    }
}
