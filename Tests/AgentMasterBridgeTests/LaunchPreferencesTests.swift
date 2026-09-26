import XCTest
@testable import AgentMasterBridge

final class LaunchPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "am-prefs-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testFollowClaudePassesOnlySettings() {
        let prefs = LaunchPreferences(mode: nil, allowBypass: false)
        XCTAssertEqual(prefs.claudeArguments(settingsPath: "/s.json"), ["--settings", "/s.json"])
    }

    func testModeIsPassedExplicitly() {
        let prefs = LaunchPreferences(mode: .plan, allowBypass: false)
        XCTAssertEqual(prefs.claudeArguments(settingsPath: "/s.json"),
                       ["--settings", "/s.json", "--permission-mode", "plan"])
    }

    func testAllowBypassAddsTheOptInFlag() {
        let prefs = LaunchPreferences(mode: nil, allowBypass: true)
        XCTAssertEqual(prefs.claudeArguments(settingsPath: "/s.json"),
                       ["--settings", "/s.json", "--allow-dangerously-skip-permissions"])
    }

    func testBypassModeImpliesAllowBypassWithoutDuplicatingFlags() {
        for allow in [false, true] {
            let prefs = LaunchPreferences(mode: .bypassPermissions, allowBypass: allow)
            XCTAssertTrue(prefs.bypassAllowed)
            XCTAssertEqual(prefs.claudeArguments(settingsPath: "/s.json"),
                           ["--settings", "/s.json", "--permission-mode", "bypassPermissions",
                            "--allow-dangerously-skip-permissions"])
        }
    }

    func testFreshDefaultsFollowClaudeAndAllowBypass() {
        let prefs = LaunchPreferences(defaults: defaults)
        XCTAssertNil(prefs.mode)
        XCTAssertTrue(prefs.allowBypass)
    }

    func testReadsStoredValuesAndIgnoresUnknownModes() {
        defaults.set("acceptEdits", forKey: LaunchPreferences.modeKey)
        defaults.set(false, forKey: LaunchPreferences.allowBypassKey)
        XCTAssertEqual(LaunchPreferences(defaults: defaults), LaunchPreferences(mode: .acceptEdits, allowBypass: false))

        defaults.set("yolo", forKey: LaunchPreferences.modeKey)
        XCTAssertNil(LaunchPreferences(defaults: defaults).mode)
    }
}
