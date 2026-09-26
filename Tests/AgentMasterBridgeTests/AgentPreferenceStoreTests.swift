import XCTest
@testable import AgentMasterBridge

final class AgentPreferenceStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "am-agent-prefs-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testKeyFormat() {
        XCTAssertEqual(AgentPreferenceStore.key(agentId: "claude", optionId: "model"), "agents.claude.model")
    }

    func testValuesAreStoredPerAgent() {
        let store = AgentPreferenceStore(defaults: defaults)
        store.set("opus", agentId: "claude", optionId: "model")
        store.set("gpt-5", agentId: "codex", optionId: "model")
        XCTAssertEqual(store.preferences(for: "claude").values, ["model": "opus"])
        XCTAssertEqual(store.preferences(for: "codex").values, ["model": "gpt-5"])
        XCTAssertEqual(store.preferences(for: "kiro").values, [:])
        XCTAssertEqual(defaults.string(forKey: "agents.claude.model"), "opus")
    }

    func testSetEmptyOrNilRemovesTheKey() {
        let store = AgentPreferenceStore(defaults: defaults)
        store.set("opus", agentId: "claude", optionId: "model")
        store.set("   ", agentId: "claude", optionId: "model")
        XCTAssertNil(defaults.object(forKey: "agents.claude.model"))
        store.set("opus", agentId: "claude", optionId: "model")
        store.set(nil, agentId: "claude", optionId: "model")
        XCTAssertEqual(store.preferences(for: "claude").values, [:])
    }

    func testReadingTrimsThroughPreferences() {
        let store = AgentPreferenceStore(defaults: defaults)
        store.set(" us.anthropic.claude-opus-5-5[1m] ", agentId: "claude", optionId: "model")
        XCTAssertEqual(store.preferences(for: "claude").string("model"), "us.anthropic.claude-opus-5-5[1m]")
    }
}
