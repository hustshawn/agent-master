# Agent 抽象 + 默认模型 + 启动时恢复会话 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 Claude 专用的启动逻辑收进 `AgentKind` 抽象，并按 agent 在 Settings 里设置默认模型、默认权限模式和 bypass 开关。另外，启动时自动恢复上次还开着的会话。

**Architecture:**
- Core 定义纯数据类型：`AgentOption`、`AgentChoice`、`AgentPreferences`、`OpenSessionRecord`。
- Bridge 定义 `AgentKind` 协议和唯一实现 `ClaudeCodeAgent`，另外包括按 agent 存储偏好的 `AgentPreferenceStore`，以及用于恢复会话的 `OpenSessionJournal` 和 `RestorePlan`。
- UI 提供通用的 `AgentOptionsView`，它不接触存储，由调用方通过闭包回写。
- App 层的 `AppModel` 不再依赖任何 Claude 专用类型。

**Tech Stack:** Swift 5.10、SwiftPM、SwiftUI（macOS 14）、XCTest、UserDefaults；另有 JSON 文件存在 `~/Library/Application Support/AgentMaster/`。

**Spec:** `docs/superpowers/specs/2026-09-26-agent-abstraction-design.md`（决策记录：`docs/adr/0004`、`docs/adr/0005`）

## Global Constraints

- 最低 macOS 14；Swift tools 5.9；唯一的第三方依赖是 SwiftTerm exact 1.18.0，不新增依赖。
- 依赖方向：UI → Core ← Bridge；UI 不 import Bridge，也不接触 Claude Code 格式。
- 偏好设置的 UserDefaults 键格式：`agents.<agentId>.<optionId>`；Claude 的 agentId 是 `claude`，一经发布不再修改。
- Claude 的设置项 id 和顺序：`model`、`permissionMode`、`allowBypass`。
- 模型别名：`opus`、`sonnet`、`haiku`、`fable`。每个别名的 detail 取自 `ANTHROPIC_DEFAULT_<别名大写>_MODEL`。
- 权限模式的可选值：`manual`（标签为 "manual (default)"）、`acceptEdits`、`plan`、`auto`、`dontAsk`、`bypassPermissions`。
- 参数顺序固定：
  ```
  --settings <path>
  [--model <v>]
  [--permission-mode <v>]
  [--allow-dangerously-skip-permissions]
  [--resume <id>]
  ```
- `allowBypass` 默认为 true；`permissionMode == bypassPermissions` 时也隐含 allowBypass，但只加一次参数。
- 恢复开关的键是 `restoreSessionsOnLaunch`，默认 true；恢复记录文件为 `~/Library/Application Support/AgentMaster/open-sessions.json`。
- 文案：
  - Settings 底部："Applies to new sessions. Running sessions keep their settings."
  - General 开关："Restore sessions on launch"
  - 跟随项："Follow <displayName> settings"
- 旧的 UserDefaults 键 `defaultPermissionMode`、`allowBypassPermissions` 不迁移，也不读取。
- 每次提交都以这一行结尾：`Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`

## Review Focus

- ⌘Q 时 SIGTERM 会把每个会话都标成 ✓，之后触发的保存不能覆盖恢复记录。→ Task 6 `testFreezeIgnoresLaterSaves`，Task 7 手工验证。
- 会话刚恢复、还没收到 `SessionStart` 就退出时，记录里要保留旧的 resumeId，否则第二次启动就丢了这个会话。→ Task 6 `testRecordsFallBackToTheRestoredResumeId`。
- 自定义模型被清空或只剩空白时，应当跟随 Claude 的设置，绝不能传出 `--model ""`。→ Task 2 `testSetEmptyOrNilRemovesTheKey`，Task 3 `testBlankModelFollowsClaude`。
- 存了 claude 不认识的权限模式（例如老版本的 `default`）时，要忽略它，不能让 claude 因参数非法而启动失败。→ Task 3 `testUnknownPermissionModeIsIgnored`。
- `open-sessions.json` 损坏或只写了一半时，启动不报错、不恢复，下一次保存会覆盖它。→ Task 6 `testCorruptFileLoadsAsEmpty`。

## 前置条件（在 Task 1 之前完成，不属于本计划的任务）

当前分支 `feat/m1-m2` 上还有未提交的改动：权限模式、新会话入口、关闭会话、两行会话行，以及 ADR 0001–0003。
等用户完成关闭会话的 GUI 验证后，由主会话提交；docs（ADR 0004/0005、本 spec、本计划）单独提交一次。开始 Task 1 时工作区必须是干净的：`git status --short` 输出为空。

## 文件结构

| 文件 | 职责 |
|---|---|
| `Sources/AgentMasterCore/AgentOption.swift`（新增） | `AgentOption`、`AgentChoice`、`AgentPreferences` |
| `Sources/AgentMasterCore/OpenSessionRecord.swift`（新增） | 恢复记录的一项（Codable） |
| `Sources/AgentMasterBridge/AgentKind.swift`（新增） | 协议、`AgentLaunchRequest`、`AgentLaunch`、`AgentLaunchError` |
| `Sources/AgentMasterBridge/AgentPreferenceStore.swift`（新增） | 按 agent 读写 UserDefaults |
| `Sources/AgentMasterBridge/ClaudeCodeAgent.swift`（新增） | Claude 的设置项声明、参数生成、launch；`AgentRegistry` |
| `Sources/AgentMasterBridge/SessionRestore.swift`（新增） | `GeneralSettings`、`OpenSessionSnapshot`、`RestorePlan`、`OpenSessionJournal` |
| `Sources/AgentMasterBridge/AppPaths.swift`（修改） | `openSessionsURL` |
| `Sources/AgentMasterUI/AgentOptionsView.swift`（新增） | 通用设置渲染，以及 `AgentChoiceSelection` |
| `Sources/AgentMaster/AppModel.swift`（修改） | 通过 agent 启动会话、`capturedEnvironment`、记录并恢复会话 |
| `Sources/AgentMaster/SessionController.swift`（修改） | `agentId`、`resumeHint`、`onStateChange` |
| `Sources/AgentMaster/SettingsView.swift`（重写） | 按 agent 分组的 Settings，加 General 分组 |
| `Sources/AgentMaster/AgentMasterApp.swift`（修改） | 把 model 传给 SettingsView |
| `Sources/AgentMasterBridge/LaunchPreferences.swift`、`Tests/AgentMasterBridgeTests/LaunchPreferencesTests.swift`（删除） | 被 `ClaudeCodeAgent` 取代 |

---

### Task 1: Core 设置项类型

**Files:**
- Create: `Sources/AgentMasterCore/AgentOption.swift`
- Test: `Tests/AgentMasterCoreTests/AgentOptionTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  - `AgentOption(id: String, title: String, kind: AgentOption.Kind)`，其中 `Kind` 是 `.choice([AgentChoice], allowsCustom: Bool)` 或 `.toggle(default: Bool)`。
  - `AgentChoice(value: String, label: String? = nil, detail: String? = nil)`：`label` 为 nil 时等于 `value`。
  - `AgentPreferences(values: [String: String] = [:])`，提供两个方法：
    - `string(_ id: String) -> String?`：去掉首尾空白，空值返回 nil。
    - `bool(_ id: String, default: Bool) -> Bool`：只认 "true" 和 "false"，其他情况返回默认值。

- [ ] **Step 1: 写失败的测试**

`Tests/AgentMasterCoreTests/AgentOptionTests.swift`:

```swift
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
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter AgentOptionTests`
Expected: 编译失败，报 `cannot find 'AgentChoice' in scope`

- [ ] **Step 3: 写实现**

`Sources/AgentMasterCore/AgentOption.swift`:

```swift
import Foundation

/// One setting an agent exposes in Settings, declared as data so one generic view renders every agent.
public struct AgentOption: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// "Follow the agent's own settings" (no stored value) is always offered first by the UI.
        case choice([AgentChoice], allowsCustom: Bool)
        case toggle(default: Bool)
    }

    public let id: String
    public let title: String
    public let kind: Kind

    public init(id: String, title: String, kind: Kind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}

public struct AgentChoice: Equatable, Sendable {
    public let value: String
    public let label: String
    /// Secondary text, e.g. the model id an alias resolves to.
    public let detail: String?

    public init(value: String, label: String? = nil, detail: String? = nil) {
        self.value = value
        self.label = label ?? value
        self.detail = detail
    }
}

/// Stored values for one agent, keyed by option id. A missing value means "follow" (or the toggle default).
public struct AgentPreferences: Equatable, Sendable {
    public var values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public func string(_ id: String) -> String? {
        guard let value = values[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    public func bool(_ id: String, default fallback: Bool) -> Bool {
        switch string(id) {
        case "true": return true
        case "false": return false
        default: return fallback
        }
    }
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter AgentOptionTests`
Expected: `Executed 3 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add Sources/AgentMasterCore/AgentOption.swift Tests/AgentMasterCoreTests/AgentOptionTests.swift
git commit -m "feat(core): add declarative agent options and preferences

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: AgentKind 协议和按 agent 存储的偏好设置

**Files:**
- Create: `Sources/AgentMasterBridge/AgentKind.swift`
- Create: `Sources/AgentMasterBridge/AgentPreferenceStore.swift`
- Test: `Tests/AgentMasterBridgeTests/AgentPreferenceStoreTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `AgentOption`、`AgentPreferences`；现有的 `AppPaths`；现有的 `SessionState`（Core）。
- Produces:
  - `protocol AgentKind: Sendable`，成员如下：
    - `id: String`
    - `displayName: String`
    - `supportsResume: Bool`，默认 false
    - `options(environment:) -> [AgentOption]`
    - `isForcedOn(optionId:preferences:) -> Bool`，默认 false
    - `resumeId(from: SessionState) -> String?`，默认 nil
    - `launch(_: AgentLaunchRequest) throws -> AgentLaunch`
  - `AgentLaunchRequest(sessionId:preferences:environment:paths:resumeId: = nil)`
  - `AgentLaunch(executable:args:environment:)`，Equatable
  - `enum AgentLaunchError: LocalizedError, Equatable { case claudeNotFound, hookHelperMissing }`
  - `AgentPreferenceStore(defaults:)`，成员如下：
    - `static key(agentId:optionId:) -> String`
    - `preferences(for:) -> AgentPreferences`
    - `set(_:agentId:optionId:)`：值为 nil 或只有空白时删除这个键。

- [ ] **Step 1: 写失败的测试**

`Tests/AgentMasterBridgeTests/AgentPreferenceStoreTests.swift`:

```swift
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
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter AgentPreferenceStoreTests`
Expected: 编译失败，报 `cannot find 'AgentPreferenceStore' in scope`

- [ ] **Step 3: 写协议和相关类型**

`Sources/AgentMasterBridge/AgentKind.swift`:

```swift
import Foundation
import AgentMasterCore

/// A coding agent AgentMaster can run in a terminal. Claude Code is the only one today; the protocol holds
/// just what Claude already needs, so it is not shaped around guesses about other agents.
public protocol AgentKind: Sendable {
    /// Part of the stored preference keys: never change it once shipped.
    var id: String { get }
    var displayName: String { get }
    var supportsResume: Bool { get }
    func options(environment: [String: String]) -> [AgentOption]
    /// A toggle the current preferences switch on regardless of its stored value (shown on and disabled).
    func isForcedOn(optionId: String, preferences: AgentPreferences) -> Bool
    /// The id `launch` needs to continue this session's conversation later.
    func resumeId(from state: SessionState) -> String?
    func launch(_ request: AgentLaunchRequest) throws -> AgentLaunch
}

extension AgentKind {
    public var supportsResume: Bool { false }
    public func isForcedOn(optionId: String, preferences: AgentPreferences) -> Bool { false }
    public func resumeId(from state: SessionState) -> String? { nil }
}

public struct AgentLaunchRequest {
    public let sessionId: String
    public let preferences: AgentPreferences
    /// The login shell's environment.
    public let environment: [String: String]
    public let paths: AppPaths
    public let resumeId: String?

    public init(sessionId: String, preferences: AgentPreferences, environment: [String: String],
                paths: AppPaths, resumeId: String? = nil) {
        self.sessionId = sessionId
        self.preferences = preferences
        self.environment = environment
        self.paths = paths
        self.resumeId = resumeId
    }
}

public struct AgentLaunch: Equatable {
    public let executable: String
    public let args: [String]
    public let environment: [String: String]

    public init(executable: String, args: [String], environment: [String: String]) {
        self.executable = executable
        self.args = args
        self.environment = environment
    }
}

public enum AgentLaunchError: LocalizedError, Equatable {
    case claudeNotFound
    case hookHelperMissing

    public var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "Claude Code not found. Install it (~/.local/bin/claude) or set AGENTMASTER_CLAUDE_PATH."
        case .hookHelperMissing:
            return "agentmaster-hook is missing. Build with scripts/bundle.sh, or `swift build` so it sits next to the app binary."
        }
    }
}
```

- [ ] **Step 4: 写存储**

`Sources/AgentMasterBridge/AgentPreferenceStore.swift`:

```swift
import Foundation
import AgentMasterCore

/// Per-agent settings in UserDefaults under `agents.<agentId>.<optionId>`.
public struct AgentPreferenceStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public static func key(agentId: String, optionId: String) -> String {
        "agents.\(agentId).\(optionId)"
    }

    public func preferences(for agentId: String) -> AgentPreferences {
        let prefix = "agents.\(agentId)."
        var values: [String: String] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            if let text = value as? String { values[String(key.dropFirst(prefix.count))] = text }
        }
        return AgentPreferences(values: values)
    }

    /// nil or blank removes the value, which means "follow the agent's own settings".
    public func set(_ value: String?, agentId: String, optionId: String) {
        let key = Self.key(agentId: agentId, optionId: optionId)
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
```

- [ ] **Step 5: 运行测试，确认通过**

Run: `swift test --filter AgentPreferenceStoreTests`
Expected: `Executed 4 tests, with 0 failures`

- [ ] **Step 6: 提交**

```bash
git add Sources/AgentMasterBridge/AgentKind.swift Sources/AgentMasterBridge/AgentPreferenceStore.swift Tests/AgentMasterBridgeTests/AgentPreferenceStoreTests.swift
git commit -m "feat(bridge): add AgentKind protocol and per-agent preference store

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: ClaudeCodeAgent 和 AgentRegistry

**Files:**
- Create: `Sources/AgentMasterBridge/ClaudeCodeAgent.swift`
- Test: `Tests/AgentMasterBridgeTests/ClaudeCodeAgentTests.swift`

**Interfaces:**
- Consumes:
  - Task 2 的 `AgentKind`、`AgentLaunchRequest`、`AgentLaunch`、`AgentLaunchError`。
  - 现有的 `ClaudeLocator.locate(environment:)`、`AppPaths.hookExecutable()`、`AppPaths.writeSettings(_:sessionId:) -> URL`。
  - 现有的 `SessionSettingsBuilder(hookExecutable:).data()`（在 AgentMasterWire 里；Bridge 已经依赖 Wire）。
  - 现有的 `LaunchEnvironment.sessionEnvironment(base:sessionId:socketPath:)`。
- Produces:
  - `ClaudeCodeAgent(locate: @escaping @Sendable ([String: String]) -> String? = { ClaudeLocator.locate(environment: $0) })`
  - 静态常量：
    - `ClaudeCodeAgent.modelOption = "model"`
    - `.permissionModeOption = "permissionMode"`
    - `.allowBypassOption = "allowBypass"`
    - `.modelAliases`
    - `.permissionModes`
  - `static func arguments(settingsPath: String, preferences: AgentPreferences, resumeId: String? = nil) -> [String]`
  - `enum AgentRegistry`：`static let all: [any AgentKind]`、`static var defaultAgent: any AgentKind`、`static func agent(id: String) -> (any AgentKind)?`

- [ ] **Step 1: 写失败的测试**

`Tests/AgentMasterBridgeTests/ClaudeCodeAgentTests.swift`:

```swift
import XCTest
import AgentMasterCore
@testable import AgentMasterBridge

final class ClaudeCodeAgentTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("am-claude-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func args(_ values: [String: String], resumeId: String? = nil) -> [String] {
        ClaudeCodeAgent.arguments(settingsPath: "/s.json", preferences: AgentPreferences(values: values), resumeId: resumeId)
    }

    private let noBypass = ["allowBypass": "false"]

    // MARK: arguments

    func testFollowClaudeWithoutBypassPassesOnlySettings() {
        XCTAssertEqual(args(noBypass), ["--settings", "/s.json"])
    }

    func testAllowBypassDefaultsOn() {
        XCTAssertEqual(args([:]), ["--settings", "/s.json", "--allow-dangerously-skip-permissions"])
    }

    func testModelAliasAndCustomIdArePassedAsIs() {
        XCTAssertEqual(args(noBypass.merging(["model": "opus"]) { $1 }), ["--settings", "/s.json", "--model", "opus"])
        XCTAssertEqual(args(noBypass.merging(["model": " us.anthropic.claude-opus-5-5[1m] "]) { $1 }),
                       ["--settings", "/s.json", "--model", "us.anthropic.claude-opus-5-5[1m]"])
    }

    func testBlankModelFollowsClaude() {
        XCTAssertEqual(args(noBypass.merging(["model": "   "]) { $1 }), ["--settings", "/s.json"])
    }

    func testEveryKnownPermissionModeIsPassed() {
        for mode in ["manual", "acceptEdits", "plan", "auto", "dontAsk"] {
            XCTAssertEqual(args(noBypass.merging(["permissionMode": mode]) { $1 }),
                           ["--settings", "/s.json", "--permission-mode", mode], mode)
        }
    }

    func testUnknownPermissionModeIsIgnored() {
        XCTAssertEqual(args(noBypass.merging(["permissionMode": "default"]) { $1 }), ["--settings", "/s.json"])
        XCTAssertEqual(args(noBypass.merging(["permissionMode": "yolo"]) { $1 }), ["--settings", "/s.json"])
    }

    func testBypassModeImpliesAllowBypassOnce() {
        for allow in ["true", "false"] {
            XCTAssertEqual(args(["permissionMode": "bypassPermissions", "allowBypass": allow]),
                           ["--settings", "/s.json", "--permission-mode", "bypassPermissions",
                            "--allow-dangerously-skip-permissions"], allow)
        }
    }

    func testArgumentOrderIsFixed() {
        XCTAssertEqual(args(["model": "sonnet", "permissionMode": "plan", "allowBypass": "true"], resumeId: "abc-123"),
                       ["--settings", "/s.json", "--model", "sonnet", "--permission-mode", "plan",
                        "--allow-dangerously-skip-permissions", "--resume", "abc-123"])
    }

    // MARK: options

    func testOptionsDeclareModelModeAndBypassInOrder() {
        let options = ClaudeCodeAgent().options(environment: [:])
        XCTAssertEqual(options.map(\.id), ["model", "permissionMode", "allowBypass"])
        guard case let .choice(models, allowsCustom) = options[0].kind else { return XCTFail("model is a choice") }
        XCTAssertEqual(models.map(\.value), ["opus", "sonnet", "haiku", "fable"])
        XCTAssertTrue(allowsCustom)
        guard case let .choice(modes, modesCustom) = options[1].kind else { return XCTFail("mode is a choice") }
        XCTAssertEqual(modes.map(\.value), ["manual", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions"])
        XCTAssertEqual(modes[0].label, "manual (default)")
        XCTAssertFalse(modesCustom)
        XCTAssertEqual(options[2].kind, .toggle(default: true))
    }

    func testModelDetailComesFromTheAliasEnvironmentVariable() {
        let options = ClaudeCodeAgent().options(environment: ["ANTHROPIC_DEFAULT_OPUS_MODEL": "us.anthropic.claude-opus-5-5[1m]"])
        guard case let .choice(models, _) = options[0].kind else { return XCTFail("model is a choice") }
        XCTAssertEqual(models[0].detail, "us.anthropic.claude-opus-5-5[1m]")
        XCTAssertNil(models[1].detail)
    }

    func testBypassModeForcesTheBypassToggle() {
        let agent = ClaudeCodeAgent()
        XCTAssertTrue(agent.isForcedOn(optionId: "allowBypass",
                                       preferences: AgentPreferences(values: ["permissionMode": "bypassPermissions"])))
        XCTAssertFalse(agent.isForcedOn(optionId: "allowBypass", preferences: AgentPreferences(values: ["permissionMode": "plan"])))
        XCTAssertFalse(agent.isForcedOn(optionId: "model",
                                        preferences: AgentPreferences(values: ["permissionMode": "bypassPermissions"])))
    }

    func testResumeIdIsTheClaudeSessionId() {
        var state = SessionState()
        XCTAssertNil(ClaudeCodeAgent().resumeId(from: state))
        state.claudeSessionId = "abc"
        XCTAssertEqual(ClaudeCodeAgent().resumeId(from: state), "abc")
        XCTAssertTrue(ClaudeCodeAgent().supportsResume)
    }

    // MARK: launch

    /// Each variant gets its own bundle so one call's hook helper cannot leak into another's.
    private func paths(withHook: Bool) throws -> AppPaths {
        let bundle = root.appendingPathComponent(withHook ? "AM.app" : "NoHook.app")
        if withHook {
            let helpers = bundle.appendingPathComponent("Contents/Helpers")
            try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
            let hook = helpers.appendingPathComponent("agentmaster-hook")
            try Data("#!/bin/sh\n".utf8).write(to: hook)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        }
        return AppPaths(supportDirectory: root.appendingPathComponent("Support"), bundleURL: bundle,
                        executableURL: bundle.appendingPathComponent("Contents/MacOS/AgentMaster"))
    }

    func testLaunchWritesHookSettingsAndCleansTheEnvironment() throws {
        let paths = try paths(withHook: true)
        let agent = ClaudeCodeAgent(locate: { _ in "/fake/claude" })
        let launch = try agent.launch(AgentLaunchRequest(
            sessionId: "S1", preferences: AgentPreferences(values: ["model": "opus", "allowBypass": "false"]),
            environment: ["PATH": "/usr/bin", "CMUX_SOCKET_PATH": "/tmp/cmux"], paths: paths, resumeId: "abc"))
        let settings = root.appendingPathComponent("Support/sessions/S1/settings.json").path
        XCTAssertEqual(launch.executable, "/fake/claude")
        XCTAssertEqual(launch.args, ["--settings", settings, "--model", "opus", "--resume", "abc"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings))
        XCTAssertEqual(launch.environment["AGENTMASTER_SESSION_ID"], "S1")
        XCTAssertEqual(launch.environment["AGENTMASTER_SOCKET"], paths.socketPath)
        XCTAssertNil(launch.environment["CMUX_SOCKET_PATH"])
    }

    func testLaunchFailsWithoutClaudeOrHook() throws {
        let request = { (paths: AppPaths) in
            AgentLaunchRequest(sessionId: "S1", preferences: AgentPreferences(), environment: [:], paths: paths)
        }
        XCTAssertThrowsError(try ClaudeCodeAgent(locate: { _ in nil }).launch(request(try paths(withHook: true)))) {
            XCTAssertEqual($0 as? AgentLaunchError, .claudeNotFound)
        }
        XCTAssertThrowsError(try ClaudeCodeAgent(locate: { _ in "/fake/claude" }).launch(request(try paths(withHook: false)))) {
            XCTAssertEqual($0 as? AgentLaunchError, .hookHelperMissing)
        }
    }

    // MARK: registry

    func testRegistryHasClaudeAsTheDefault() {
        XCTAssertEqual(AgentRegistry.all.map(\.id), ["claude"])
        XCTAssertEqual(AgentRegistry.defaultAgent.id, "claude")
        XCTAssertEqual(AgentRegistry.agent(id: "claude")?.displayName, "Claude Code")
        XCTAssertNil(AgentRegistry.agent(id: "codex"))
    }
}
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter ClaudeCodeAgentTests`
Expected: 编译失败，报 `cannot find 'ClaudeCodeAgent' in scope`

- [ ] **Step 3: 写实现**

`Sources/AgentMasterBridge/ClaudeCodeAgent.swift`:

```swift
import Foundation
import AgentMasterCore
import AgentMasterWire

/// Claude Code: hooks injected with `--settings`, so its panels light up through HookTranslator.
public struct ClaudeCodeAgent: AgentKind {
    public static let modelOption = "model"
    public static let permissionModeOption = "permissionMode"
    public static let allowBypassOption = "allowBypass"
    public static let modelAliases = ["opus", "sonnet", "haiku", "fable"]
    /// The values `claude --permission-mode` accepts.
    public static let permissionModes = ["manual", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions"]

    public let id = "claude"
    public let displayName = "Claude Code"
    public var supportsResume: Bool { true }

    private let locate: @Sendable ([String: String]) -> String?

    public init(locate: @escaping @Sendable ([String: String]) -> String? = { ClaudeLocator.locate(environment: $0) }) {
        self.locate = locate
    }

    public func options(environment: [String: String]) -> [AgentOption] {
        [
            AgentOption(id: Self.modelOption, title: "Default model", kind: .choice(
                Self.modelAliases.map { AgentChoice(value: $0, detail: environment["ANTHROPIC_DEFAULT_\($0.uppercased())_MODEL"]) },
                allowsCustom: true)),
            AgentOption(id: Self.permissionModeOption, title: "Default permission mode", kind: .choice(
                Self.permissionModes.map { AgentChoice(value: $0, label: $0 == "manual" ? "manual (default)" : nil) },
                allowsCustom: false)),
            AgentOption(id: Self.allowBypassOption, title: "Allow switching to bypass permissions in a session",
                        kind: .toggle(default: true)),
        ]
    }

    public func isForcedOn(optionId: String, preferences: AgentPreferences) -> Bool {
        optionId == Self.allowBypassOption && preferences.string(Self.permissionModeOption) == "bypassPermissions"
    }

    public func resumeId(from state: SessionState) -> String? {
        state.claudeSessionId
    }

    public static func arguments(settingsPath: String, preferences: AgentPreferences, resumeId: String? = nil) -> [String] {
        var args = ["--settings", settingsPath]
        if let model = preferences.string(modelOption) { args += ["--model", model] }
        // An unknown mode would make claude refuse to start; follow its own settings instead.
        let mode = preferences.string(permissionModeOption).flatMap { permissionModes.contains($0) ? $0 : nil }
        if let mode { args += ["--permission-mode", mode] }
        if preferences.bool(allowBypassOption, default: true) || mode == "bypassPermissions" {
            args.append("--allow-dangerously-skip-permissions")
        }
        if let resumeId { args += ["--resume", resumeId] }
        return args
    }

    public func launch(_ request: AgentLaunchRequest) throws -> AgentLaunch {
        guard let claude = locate(request.environment) else { throw AgentLaunchError.claudeNotFound }
        guard let hook = request.paths.hookExecutable() else { throw AgentLaunchError.hookHelperMissing }
        let settings = try request.paths.writeSettings(SessionSettingsBuilder(hookExecutable: hook).data(),
                                                       sessionId: request.sessionId)
        return AgentLaunch(
            executable: claude,
            args: Self.arguments(settingsPath: settings.path, preferences: request.preferences, resumeId: request.resumeId),
            environment: LaunchEnvironment.sessionEnvironment(base: request.environment, sessionId: request.sessionId,
                                                             socketPath: request.paths.socketPath))
    }
}

public enum AgentRegistry {
    public static let all: [any AgentKind] = [ClaudeCodeAgent()]
    public static var defaultAgent: any AgentKind { all[0] }

    public static func agent(id: String) -> (any AgentKind)? {
        all.first { $0.id == id }
    }
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter ClaudeCodeAgentTests`
Expected: `Executed 15 tests, with 0 failures`

- [ ] **Step 5: 提交**

```bash
git add Sources/AgentMasterBridge/ClaudeCodeAgent.swift Tests/AgentMasterBridgeTests/ClaudeCodeAgentTests.swift
git commit -m "feat(bridge): add ClaudeCodeAgent with model, permission mode and resume arguments

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: 通用设置视图 AgentOptionsView

**Files:**
- Create: `Sources/AgentMasterUI/AgentOptionsView.swift`
- Test: `Tests/AgentMasterUITests/AgentMasterUITests.swift`（在末尾追加测试方法）
- Modify: `docs/superpowers/specs/2026-09-26-agent-abstraction-design.md` 第 3 节（同步签名的变化）

**Interfaces:**
- Consumes: Task 1 的 `AgentOption`、`AgentChoice`、`AgentPreferences`。UI **不**依赖 Bridge。
- Produces:
  - `enum AgentChoiceSelection`：
    - `static let followTag = ""`
    - `static let customTag = "\u{0}custom"`
    - `static func tag(for value: String?, choices: [AgentChoice], allowsCustom: Bool, customActive: Bool) -> String`
  - `AgentOptionsView(title: String, options: [AgentOption], preferences: AgentPreferences, isForcedOn: @escaping (String) -> Bool, onSet: @escaping (String, String?) -> Void)`

- [ ] **Step 1: 写失败的测试**

在 `Tests/AgentMasterUITests/AgentMasterUITests.swift` 的类里、最后一个 `}` 之前追加：

```swift
    func testChoiceSelectionMapsStoredValuesToPickerTags() {
        let choices = [AgentChoice(value: "opus"), AgentChoice(value: "sonnet")]
        func tag(_ value: String?, custom: Bool = true, active: Bool = false) -> String {
            AgentChoiceSelection.tag(for: value, choices: choices, allowsCustom: custom, customActive: active)
        }
        XCTAssertEqual(tag(nil), AgentChoiceSelection.followTag)
        XCTAssertEqual(tag("opus"), "opus")
        XCTAssertEqual(tag("us.anthropic.claude-opus-5-5[1m]"), AgentChoiceSelection.customTag, "unknown value shows as custom")
        XCTAssertEqual(tag(nil, active: true), AgentChoiceSelection.customTag, "custom picked but nothing typed yet")
        XCTAssertEqual(tag("yolo", custom: false), AgentChoiceSelection.followTag, "no custom row: unknown value follows")
        XCTAssertNotEqual(AgentChoiceSelection.customTag, "custom", "cannot collide with a real value")
    }
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter AgentMasterUITests`
Expected: 编译失败，报 `cannot find 'AgentChoiceSelection' in scope`

- [ ] **Step 3: 写实现**

`Sources/AgentMasterUI/AgentOptionsView.swift`:

```swift
import SwiftUI
import AgentMasterCore

/// Which picker row a stored value selects.
public enum AgentChoiceSelection {
    public static let followTag = ""
    /// Starts with NUL so it can never equal a real option value.
    public static let customTag = "\u{0}custom"

    public static func tag(for value: String?, choices: [AgentChoice], allowsCustom: Bool, customActive: Bool) -> String {
        if let value, choices.contains(where: { $0.value == value }) { return value }
        if allowsCustom && (value != nil || customActive) { return customTag }
        return followTag
    }
}

/// Renders one agent's declared options as a Form section. Storage stays with the caller:
/// `onSet(optionId, nil)` clears a value, which means "follow the agent's own settings".
public struct AgentOptionsView: View {
    let title: String
    let options: [AgentOption]
    let preferences: AgentPreferences
    let isForcedOn: (String) -> Bool
    let onSet: (String, String?) -> Void
    /// Options whose Custom… row is picked while the text field is still empty.
    @State private var customActive: Set<String> = []

    public init(title: String, options: [AgentOption], preferences: AgentPreferences,
                isForcedOn: @escaping (String) -> Bool, onSet: @escaping (String, String?) -> Void) {
        self.title = title
        self.options = options
        self.preferences = preferences
        self.isForcedOn = isForcedOn
        self.onSet = onSet
    }

    public var body: some View {
        Section(title) {
            ForEach(options, id: \.id) { option in
                switch option.kind {
                case let .choice(choices, allowsCustom):
                    choiceRow(option, choices: choices, allowsCustom: allowsCustom)
                case let .toggle(fallback):
                    toggleRow(option, fallback: fallback)
                }
            }
        }
    }

    @ViewBuilder
    private func choiceRow(_ option: AgentOption, choices: [AgentChoice], allowsCustom: Bool) -> some View {
        let selection = Binding<String>(
            get: {
                AgentChoiceSelection.tag(for: preferences.string(option.id), choices: choices,
                                         allowsCustom: allowsCustom, customActive: customActive.contains(option.id))
            },
            set: { tag in
                if tag == AgentChoiceSelection.customTag {
                    customActive.insert(option.id)
                } else {
                    customActive.remove(option.id)
                    onSet(option.id, tag.isEmpty ? nil : tag)
                }
            })
        Picker(option.title, selection: selection) {
            Text("Follow \(title) settings").tag(AgentChoiceSelection.followTag)
            Divider()
            ForEach(choices, id: \.value) { choice in
                // macOS menu items are plain text, so the detail rides along after a dash.
                Text(choice.detail.map { "\(choice.label) — \($0)" } ?? choice.label).tag(choice.value)
            }
            if allowsCustom {
                Divider()
                Text("Custom…").tag(AgentChoiceSelection.customTag)
            }
        }
        if selection.wrappedValue == AgentChoiceSelection.customTag {
            TextField("Custom \(option.title.lowercased())", text: Binding(
                get: { preferences.values[option.id] ?? "" },
                set: { onSet(option.id, $0) }))
        }
    }

    private func toggleRow(_ option: AgentOption, fallback: Bool) -> some View {
        let forced = isForcedOn(option.id)
        return Toggle(option.title, isOn: Binding(
            get: { forced || preferences.bool(option.id, default: fallback) },
            set: { onSet(option.id, $0 ? "true" : "false") }))
            .disabled(forced)
    }
}
```

- [ ] **Step 4: 运行测试，确认通过**

Run: `swift test --filter AgentMasterUITests`
Expected: 所有 AgentMasterUITests 通过，0 failures

- [ ] **Step 5: 同步 spec 第 3 节**

在 `docs/superpowers/specs/2026-09-26-agent-abstraction-design.md` 第 3 节，把这一句：

```
Section 里的控件由通用视图 `AgentOptionsView(agent:options:store:)` 按 `AgentOption` 渲染：
```

替换为：

```
Section 里的控件由通用视图 `AgentOptionsView(title:options:preferences:isForcedOn:onSet:)` 按 `AgentOption` 渲染。
这个视图放在 AgentMasterUI，而 UI 不能依赖 Bridge，所以存储交给调用方（App 层的 SettingsView），用 `onSet` 闭包回写：
```

再把 "有 `detail` 时在后面用 secondary 样式显示 detail" 替换为：

```
有 `detail` 时显示为 `label — detail`（macOS 的菜单项只能显示纯文本，没法做 secondary 样式）
```

- [ ] **Step 6: 提交**

```bash
git add Sources/AgentMasterUI/AgentOptionsView.swift Tests/AgentMasterUITests/AgentMasterUITests.swift docs/superpowers/specs/2026-09-26-agent-abstraction-design.md
git commit -m "feat(ui): add generic AgentOptionsView for declared agent settings

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: App 层改为通过 agent 启动，Settings 按 agent 渲染

**Files:**
- Modify: `Sources/AgentMaster/AppModel.swift`
- Modify: `Sources/AgentMaster/SessionController.swift`
- Rewrite: `Sources/AgentMaster/SettingsView.swift`
- Modify: `Sources/AgentMaster/AgentMasterApp.swift`（只改 `Settings { … }` 这一段）
- Delete: `Sources/AgentMasterBridge/LaunchPreferences.swift`、`Tests/AgentMasterBridgeTests/LaunchPreferencesTests.swift`

**Interfaces:**
- Consumes：
  - Task 2 的 `AgentPreferenceStore`、`AgentLaunchRequest`、`AgentLaunchError`。
  - Task 3 的 `AgentRegistry`、`ClaudeCodeAgent`。
  - Task 4 的 `AgentOptionsView`。
- Produces（Task 7 会用到）：
  - `AppModel.capturedEnvironment: [String: String]?`：可观察，只读。
  - `AppModel.startSession(in: String, agent: any AgentKind = AgentRegistry.defaultAgent, resumeId: String? = nil) async -> String?`：返回新会话的 id，失败时返回 nil。这个方法标了 `@discardableResult`。
  - `SessionController(id:agentId:projectPath:launch:)`，以及 `agentId` 属性。

App target 没有测试 target；这个任务靠全量 `swift test`（确认没有回归）、编译，以及手工验证来检查。

- [ ] **Step 1: 删除 LaunchPreferences**

```bash
git rm Sources/AgentMasterBridge/LaunchPreferences.swift Tests/AgentMasterBridgeTests/LaunchPreferencesTests.swift
```

- [ ] **Step 2: SessionController 增加 agentId**

在 `Sources/AgentMaster/SessionController.swift` 中，把

```swift
    let id: String
    let projectPath: String
```

替换为

```swift
    let id: String
    let agentId: String
    let projectPath: String
```

再把

```swift
    init(id: String, projectPath: String, launch: TerminalLaunch) {
        self.id = id
        self.projectPath = projectPath
```

替换为

```swift
    init(id: String, agentId: String, projectPath: String, launch: TerminalLaunch) {
        self.id = id
        self.agentId = agentId
        self.projectPath = projectPath
```

- [ ] **Step 3: AppModel 改为通过 agent 启动**

在 `Sources/AgentMaster/AppModel.swift` 中做以下修改：

(a) 删除整个 `enum AppError: LocalizedError { … }` 块（从 `enum AppError` 到它的右花括号）。

(b) 把

```swift
    @ObservationIgnored private let recents = RecentProjects(defaults: .standard)
    @ObservationIgnored private var server: HookServer?
    @ObservationIgnored private var baseEnvironment: [String: String]?
```

替换为

```swift
    /// The login shell's environment once captured; Settings resolves model aliases against it.
    private(set) var capturedEnvironment: [String: String]?

    @ObservationIgnored private let recents = RecentProjects(defaults: .standard)
    @ObservationIgnored private let preferenceStore = AgentPreferenceStore(defaults: .standard)
    @ObservationIgnored private var server: HookServer?
```

(c) 在 `init()` 末尾（`do { … } catch { … }` 之后、`init` 的右花括号之前）加上：

```swift
        Task { _ = await environment() }
```

(d) 把整个 `func startSession(in projectPath: String) async { … }` 替换为：

```swift
    @discardableResult
    func startSession(in projectPath: String, agent: any AgentKind = AgentRegistry.defaultAgent,
                      resumeId: String? = nil) async -> String? {
        do {
            let base = await environment()
            let id = UUID().uuidString
            let launch = try agent.launch(AgentLaunchRequest(
                sessionId: id, preferences: preferenceStore.preferences(for: agent.id),
                environment: base, paths: paths, resumeId: resumeId))
            let session = SessionController(
                id: id, agentId: agent.id, projectPath: projectPath,
                launch: TerminalLaunch(executable: launch.executable, args: launch.args,
                                       environment: launch.environment, currentDirectory: projectPath))
            sessions.append(session)
            selectedId = id
            recents.record(projectPath)
            recentProjects = recents.paths
            return id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
```

(e) 把整个 `private func environment() async -> [String: String] { … }` 替换为：

```swift
    private func environment() async -> [String: String] {
        if let capturedEnvironment { return capturedEnvironment }
        let captured = await environmentTask?.value ?? ProcessInfo.processInfo.environment
        capturedEnvironment = captured
        return captured
    }
```

- [ ] **Step 4: 重写 SettingsView**

`Sources/AgentMaster/SettingsView.swift`（整个文件替换）：

```swift
import SwiftUI
import AgentMasterCore
import AgentMasterBridge
import AgentMasterUI

/// Defaults for new sessions, one section per agent. Values live in UserDefaults via AgentPreferenceStore.
struct SettingsView: View {
    let model: AppModel
    @State private var preferences: [String: AgentPreferences] = [:]
    private let store = AgentPreferenceStore(defaults: .standard)

    var body: some View {
        Form {
            ForEach(AgentRegistry.all, id: \.id) { agent in
                let prefs = preferences[agent.id] ?? store.preferences(for: agent.id)
                AgentOptionsView(
                    title: agent.displayName,
                    options: agent.options(environment: model.capturedEnvironment ?? [:]),
                    preferences: prefs,
                    isForcedOn: { agent.isForcedOn(optionId: $0, preferences: prefs) },
                    onSet: { optionId, value in
                        store.set(value, agentId: agent.id, optionId: optionId)
                        preferences[agent.id] = store.preferences(for: agent.id)
                    })
            }
            Section {
                Text("Applies to new sessions. Running sessions keep their settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}
```

- [ ] **Step 5: 把 model 传给 SettingsView**

在 `Sources/AgentMaster/AgentMasterApp.swift` 中，把

```swift
        Settings {
            SettingsView()
```

替换为

```swift
        Settings {
            SettingsView(model: delegate.model)
```

- [ ] **Step 6: 编译并跑全量测试**

Run: `swift build 2>&1 | grep -E "error|warning: .*(AppModel|Settings|SessionController)"; swift test 2>&1 | grep -E "error:|Executed .* tests" | tail -2`
Expected: 没有 error；`Executed N tests, with 0 failures`。N 等于 Task 4 结束时的测试数减去被删掉的 6 个 LaunchPreferencesTests。

- [ ] **Step 7: 确认 AppModel 里没有 Claude 专用类型**

Run: `grep -nE "ClaudeLocator|SessionSettingsBuilder|LaunchEnvironment\.sessionEnvironment|LaunchPreferences|AppError" Sources/AgentMaster/*.swift`
Expected: 没有任何输出。`AppModel.init` 里的 `LaunchEnvironment.captureLoginShell()` 抓的是登录 shell 的环境，跟具体 agent 无关，所以保留；上面的 grep 模式本来就不会匹配到它。

- [ ] **Step 8: 手工验证**

```bash
./scripts/bundle.sh
osascript -e 'quit app "AgentMaster"'; sleep 2; open build/AgentMaster.app
```

1. 按 ⌘, 打开 Settings。应该能看到 **Claude Code** 分组，里面依次是：Default model、Default permission mode、Allow switching…。
2. 打开 Default model 下拉框：
   - 第一项是 "Follow Claude Code settings"。
   - 在这台机器上，opus 那一行显示为 `opus — us.anthropic.claude-opus-5-5[1m]`。
   - 最后一项是 "Custom…"。
3. 选 opus，新开一个会话。然后运行 `ps -axo args | grep "bin/claude --settings" | grep -v grep`，参数里应该有 `--model opus`；页头和 USAGE 里的模型应该显示 Opus 5.5。
4. 选 Custom…，输入 `sonnet`。这时下拉框应该自动切到 sonnet，输入框消失。
5. 权限模式选 bypassPermissions，Allow switching 开关应该显示为打开且不可操作。
6. 选回 "Follow Claude Code settings"，再新开一个会话，参数里不应该有 `--model`。

- [ ] **Step 9: 提交**

```bash
git add -A Sources/AgentMaster Sources/AgentMasterBridge Tests/AgentMasterBridgeTests
git commit -m "refactor(app): launch sessions through AgentKind; per-agent Settings with default model

Replaces LaunchPreferences. AppModel no longer knows Claude-specific types.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: 恢复记录、恢复计划和 General 设置（Bridge）

**Files:**
- Create: `Sources/AgentMasterCore/OpenSessionRecord.swift`
- Create: `Sources/AgentMasterBridge/SessionRestore.swift`
- Modify: `Sources/AgentMasterBridge/AppPaths.swift`（增加 `openSessionsURL`）
- Test: `Tests/AgentMasterBridgeTests/SessionRestoreTests.swift`
- Test: `Tests/AgentMasterBridgeTests/AppPathsTests.swift`（追加一个测试）

**Interfaces:**
- Consumes：Task 2 的 `AgentKind`，Task 3 的 `ClaudeCodeAgent`，现有的 `SessionState` 和 `SessionStatus`。
- Produces（Task 7 会用到）：
  - `OpenSessionRecord(agentId:projectPath:createdAt:resumeId:selected:)`，Codable、Equatable。
  - `OpenSessionSnapshot(agentId:projectPath:createdAt:state:selected:fallbackResumeId:)`
  - `RestorePlan`：
    - `static records(from: [OpenSessionSnapshot], agents: [any AgentKind]) -> [OpenSessionRecord]`
    - `static make(records: [OpenSessionRecord], agents: [any AgentKind], directoryExists: (String) -> Bool) -> [OpenSessionRecord]`
  - `OpenSessionJournal(fileURL:)`：`load() -> [OpenSessionRecord]`、`save(_:)`、`freeze()`。
  - `GeneralSettings`：
    - `static let restoreSessionsOnLaunchKey = "restoreSessionsOnLaunch"`
    - `static func restoreSessionsOnLaunch(_ defaults: UserDefaults) -> Bool`
  - `AppPaths.openSessionsURL: URL`

- [ ] **Step 1: 写失败的测试**

`Tests/AgentMasterBridgeTests/SessionRestoreTests.swift`:

```swift
import XCTest
import AgentMasterCore
@testable import AgentMasterBridge

/// An agent that cannot resume, to prove such sessions are never recorded or restored.
private struct NoResumeAgent: AgentKind {
    let id = "noresume"
    let displayName = "No Resume"
    func options(environment: [String: String]) -> [AgentOption] { [] }
    func launch(_ request: AgentLaunchRequest) throws -> AgentLaunch { throw AgentLaunchError.claudeNotFound }
}

final class SessionRestoreTests: XCTestCase {
    private var root: URL!
    private let agents: [any AgentKind] = [ClaudeCodeAgent(locate: { _ in nil }), NoResumeAgent()]

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("am-restore-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func state(_ status: SessionStatus, claudeId: String?) -> SessionState {
        var state = SessionState()
        state.status = status
        state.claudeSessionId = claudeId
        return state
    }

    private func snapshot(_ agent: String = "claude", _ path: String = "/p", minute: Double = 0, status: SessionStatus = .idle,
                          claudeId: String? = "c1", selected: Bool = false, fallback: String? = nil) -> OpenSessionSnapshot {
        OpenSessionSnapshot(agentId: agent, projectPath: path, createdAt: Date(timeIntervalSince1970: minute * 60),
                            state: state(status, claudeId: claudeId), selected: selected, fallbackResumeId: fallback)
    }

    private func record(_ agent: String = "claude", _ path: String = "/p", minute: Double = 0, resumeId: String = "c1",
                        selected: Bool = false) -> OpenSessionRecord {
        OpenSessionRecord(agentId: agent, projectPath: path, createdAt: Date(timeIntervalSince1970: minute * 60),
                          resumeId: resumeId, selected: selected)
    }

    // MARK: records(from:)

    func testRecordsKeepLiveResumableSessions() {
        let records = RestorePlan.records(from: [
            snapshot(status: .idle, claudeId: "a", selected: true),
            snapshot(status: .running, claudeId: "b"),
            snapshot(status: .needsAttention, claudeId: "c"),
            snapshot(status: .ended, claudeId: "d"),
            snapshot(status: .starting, claudeId: nil),
            snapshot("noresume", claudeId: "e"),
            snapshot("unknown", claudeId: "f"),
        ], agents: agents)
        XCTAssertEqual(records.map(\.resumeId), ["a", "b", "c"])
        XCTAssertEqual(records.map(\.selected), [true, false, false])
    }

    func testRecordsFallBackToTheRestoredResumeId() {
        let records = RestorePlan.records(from: [snapshot(status: .starting, claudeId: nil, fallback: "old")], agents: agents)
        XCTAssertEqual(records.map(\.resumeId), ["old"])
        let newer = RestorePlan.records(from: [snapshot(claudeId: "new", fallback: "old")], agents: agents)
        XCTAssertEqual(newer.map(\.resumeId), ["new"], "a live id (e.g. after /clear) wins over the restored one")
    }

    // MARK: make(records:)

    func testPlanSkipsMissingDirectoriesAndNonResumableAgentsAndSortsOldestFirst() {
        let plan = RestorePlan.make(records: [
            record(path: "/b", minute: 2, resumeId: "b"),
            record(path: "/gone", minute: 1, resumeId: "gone"),
            record("noresume", path: "/a", minute: 0, resumeId: "x"),
            record("unknown", path: "/a", minute: 0, resumeId: "y"),
            record(path: "/a", minute: 0, resumeId: ""),
            record(path: "/a", minute: 1, resumeId: "a"),
        ], agents: agents, directoryExists: { $0 != "/gone" })
        XCTAssertEqual(plan.map(\.resumeId), ["a", "b"])
    }

    // MARK: journal

    private var journalURL: URL { root.appendingPathComponent("Support/open-sessions.json") }

    func testMissingFileLoadsAsEmptyAndSaveRoundTrips() {
        let journal = OpenSessionJournal(fileURL: journalURL)
        XCTAssertEqual(journal.load(), [])
        let records = [record(minute: 1.5, resumeId: "a", selected: true), record(path: "/q", resumeId: "b")]
        journal.save(records)
        XCTAssertEqual(OpenSessionJournal(fileURL: journalURL).load(), records)
    }

    func testCorruptFileLoadsAsEmpty() throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[{\"agentId\":".utf8).write(to: journalURL)
        let journal = OpenSessionJournal(fileURL: journalURL)
        XCTAssertEqual(journal.load(), [])
        journal.save([record(resumeId: "a")])
        XCTAssertEqual(journal.load().map(\.resumeId), ["a"])
    }

    func testFreezeIgnoresLaterSaves() {
        let journal = OpenSessionJournal(fileURL: journalURL)
        journal.save([record(resumeId: "a"), record(resumeId: "b")])
        journal.freeze()
        journal.save([])   // what shutdown's SIGTERM → ended would otherwise write
        XCTAssertEqual(OpenSessionJournal(fileURL: journalURL).load().map(\.resumeId), ["a", "b"])
    }

    // MARK: general settings

    func testRestoreOnLaunchDefaultsOn() {
        let suite = "am-general-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(GeneralSettings.restoreSessionsOnLaunch(defaults))
        defaults.set(false, forKey: GeneralSettings.restoreSessionsOnLaunchKey)
        XCTAssertFalse(GeneralSettings.restoreSessionsOnLaunch(defaults))
    }
}
```

在 `Tests/AgentMasterBridgeTests/AppPathsTests.swift` 的 `func testStandardSocketPathFitsInSunPath()` 之前插入：

```swift
    func testOpenSessionsFileLivesInTheSupportDirectory() {
        XCTAssertEqual(paths().openSessionsURL.path, root.appendingPathComponent("Support Dir/open-sessions.json").path)
    }

```

- [ ] **Step 2: 运行测试，确认失败**

Run: `swift test --filter "SessionRestoreTests|AppPathsTests"`
Expected: 编译失败，报 `cannot find 'OpenSessionRecord' in scope`

- [ ] **Step 3: 写 Core 记录类型**

`Sources/AgentMasterCore/OpenSessionRecord.swift`:

```swift
import Foundation

/// One session to reopen on the next launch.
public struct OpenSessionRecord: Codable, Equatable, Sendable {
    public let agentId: String
    public let projectPath: String
    public let createdAt: Date
    public let resumeId: String
    public let selected: Bool

    public init(agentId: String, projectPath: String, createdAt: Date, resumeId: String, selected: Bool) {
        self.agentId = agentId
        self.projectPath = projectPath
        self.createdAt = createdAt
        self.resumeId = resumeId
        self.selected = selected
    }
}
```

- [ ] **Step 4: 写恢复逻辑**

`Sources/AgentMasterBridge/SessionRestore.swift`:

```swift
import Foundation
import AgentMasterCore

public enum GeneralSettings {
    public static let restoreSessionsOnLaunchKey = "restoreSessionsOnLaunch"

    public static func restoreSessionsOnLaunch(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: restoreSessionsOnLaunchKey) as? Bool ?? true
    }
}

/// What the app knows about one open session when it writes the journal.
public struct OpenSessionSnapshot {
    public let agentId: String
    public let projectPath: String
    public let createdAt: Date
    public let state: SessionState
    public let selected: Bool
    /// The id a restored session was launched with, until its own SessionStart reports one.
    public let fallbackResumeId: String?

    public init(agentId: String, projectPath: String, createdAt: Date, state: SessionState, selected: Bool,
                fallbackResumeId: String?) {
        self.agentId = agentId
        self.projectPath = projectPath
        self.createdAt = createdAt
        self.state = state
        self.selected = selected
        self.fallbackResumeId = fallbackResumeId
    }
}

public enum RestorePlan {
    /// Sessions worth reopening: not ended, of an agent that can resume, with an id to resume.
    public static func records(from snapshots: [OpenSessionSnapshot], agents: [any AgentKind]) -> [OpenSessionRecord] {
        snapshots.compactMap { snapshot in
            guard snapshot.state.status != .ended,
                  let agent = agents.first(where: { $0.id == snapshot.agentId }), agent.supportsResume,
                  let resumeId = agent.resumeId(from: snapshot.state) ?? snapshot.fallbackResumeId
            else { return nil }
            return OpenSessionRecord(agentId: snapshot.agentId, projectPath: snapshot.projectPath,
                                     createdAt: snapshot.createdAt, resumeId: resumeId, selected: snapshot.selected)
        }
    }

    /// The records to relaunch, oldest first so the sidebar keeps its order.
    public static func make(records: [OpenSessionRecord], agents: [any AgentKind],
                            directoryExists: (String) -> Bool) -> [OpenSessionRecord] {
        records
            .filter { record in
                !record.resumeId.isEmpty
                    && agents.contains { $0.id == record.agentId && $0.supportsResume }
                    && directoryExists(record.projectPath)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }
}

/// `open-sessions.json`, rewritten whenever the open sessions change so a crash still restores.
public final class OpenSessionJournal {
    private let fileURL: URL
    private var frozen = false
    private var lastSaved: [OpenSessionRecord]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// A missing or unreadable file means nothing to restore.
    public func load() -> [OpenSessionRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([OpenSessionRecord].self, from: data) else { return [] }
        return records
    }

    public func save(_ records: [OpenSessionRecord]) {
        guard !frozen, records != lastSaved, let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: fileURL, options: .atomic)) != nil { lastSaved = records }
    }

    /// Called as quitting starts: terminating the sessions marks them ended, which must not reach the file.
    public func freeze() {
        frozen = true
    }
}
```

- [ ] **Step 5: AppPaths 增加 openSessionsURL**

在 `Sources/AgentMasterBridge/AppPaths.swift` 中，在 `public var socketPath: String { … }` 之后加上：

```swift

    public var openSessionsURL: URL {
        supportDirectory.appendingPathComponent("open-sessions.json")
    }
```

- [ ] **Step 6: 运行测试，确认通过**

Run: `swift test --filter "SessionRestoreTests|AppPathsTests"`
Expected: 0 failures；SessionRestoreTests 共 7 个测试。

- [ ] **Step 7: 提交**

```bash
git add Sources/AgentMasterCore/OpenSessionRecord.swift Sources/AgentMasterBridge/SessionRestore.swift Sources/AgentMasterBridge/AppPaths.swift Tests/AgentMasterBridgeTests/SessionRestoreTests.swift Tests/AgentMasterBridgeTests/AppPathsTests.swift
git commit -m "feat(bridge): add open-session journal and restore plan

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: App 层接入会话恢复和 General 开关

**Files:**
- Modify: `Sources/AgentMaster/SessionController.swift`
- Modify: `Sources/AgentMaster/AppModel.swift`
- Modify: `Sources/AgentMaster/SettingsView.swift`
- Modify: `docs/adr/README.md`、`/Users/shawn/.claude/projects/-Users-shawn-Documents-workdir/memory/agentmaster-m3-carryovers.md`（只在 Step 7 更新状态）

**Interfaces:**
- Consumes：
  - Task 5 的 `AppModel.startSession(in:agent:resumeId:) -> String?`、`SessionController.agentId`。
  - Task 6 的 `OpenSessionJournal`、`OpenSessionSnapshot`、`RestorePlan`、`GeneralSettings`、`AppPaths.openSessionsURL`。
- Produces：
  - `SessionController.resumeHint: String?`
  - `SessionController.onStateChange: (() -> Void)?`

- [ ] **Step 1: SessionController 增加 resumeHint 和 onStateChange**

在 `Sources/AgentMaster/SessionController.swift` 中做以下修改：

(a) 把

```swift
    let agentId: String
    let projectPath: String
```

替换为

```swift
    let agentId: String
    let projectPath: String
    /// The id this session was resumed with; kept in the journal until SessionStart reports the live one.
    let resumeHint: String?
    @ObservationIgnored var onStateChange: (() -> Void)?
```

(b) 把

```swift
    init(id: String, agentId: String, projectPath: String, launch: TerminalLaunch) {
        self.id = id
        self.agentId = agentId
        self.projectPath = projectPath
```

替换为

```swift
    init(id: String, agentId: String, projectPath: String, resumeHint: String? = nil, launch: TerminalLaunch) {
        self.id = id
        self.agentId = agentId
        self.projectPath = projectPath
        self.resumeHint = resumeHint
```

(c) 把

```swift
    private func apply(_ events: [SessionEvent]) {
        let now = Date()
        for event in events { state.apply(event, at: now) }
    }
```

替换为

```swift
    private func apply(_ events: [SessionEvent]) {
        let now = Date()
        for event in events { state.apply(event, at: now) }
        if !events.isEmpty { onStateChange?() }
    }
```

- [ ] **Step 2: AppModel 记录打开的会话**

在 `Sources/AgentMaster/AppModel.swift` 中做以下修改：

(a) 把

```swift
    private(set) var sessions: [SessionController] = []
    var selectedId: String?
```

替换为

```swift
    private(set) var sessions: [SessionController] = [] {
        didSet { persistOpenSessions() }
    }
    var selectedId: String? {
        didSet { persistOpenSessions() }
    }
```

备选方案：Swift 5.10 的 `@Observable` 支持在存储属性上写 `didSet`。如果编译器报错不允许，就去掉这两个 `didSet`，改成在下面这些地方显式调用 `persistOpenSessions()`：
- `sessions.append(session)` 之后
- `close(_:)` 的 `sessions.removeAll` 之后
- `selectedId` 被赋值的每一处（`startSession`、`close`、`restoreOpenSessions`）

另外，在 `MainWindow` 里给侧边栏传入一个自定义的 `Binding(get: { model.selectedId }, set: { model.selectedId = $0; model.persistOpenSessions() })`，这时要把 `persistOpenSessions` 改成 internal。

(b) 在 `@ObservationIgnored private let preferenceStore = …` 这一行之后加上：

```swift
    @ObservationIgnored private let journal = OpenSessionJournal(fileURL: AppPaths.standard.openSessionsURL)
    /// While relaunching the journal's sessions, do not overwrite it with the partial list.
    @ObservationIgnored private var restoring = false
```

(c) 把 `init()` 末尾在 Task 5 加上的

```swift
        Task { _ = await environment() }
```

替换为

```swift
        Task {
            _ = await environment()
            await restoreOpenSessions()
        }
```

(d) 在 `startSession` 里，把

```swift
            let session = SessionController(
                id: id, agentId: agent.id, projectPath: projectPath,
                launch: TerminalLaunch(executable: launch.executable, args: launch.args,
                                       environment: launch.environment, currentDirectory: projectPath))
            sessions.append(session)
```

替换为

```swift
            let session = SessionController(
                id: id, agentId: agent.id, projectPath: projectPath, resumeHint: resumeId,
                launch: TerminalLaunch(executable: launch.executable, args: launch.args,
                                       environment: launch.environment, currentDirectory: projectPath))
            session.onStateChange = { [weak self] in self?.persistOpenSessions() }
            sessions.append(session)
```

(e) 把 `func shutdown() {` 的第一行改为冻结记录，也就是把

```swift
    func shutdown() {
        server?.stop()
```

替换为

```swift
    func shutdown() {
        // Terminating below marks every session ended; the journal must keep what was open.
        journal.freeze()
        server?.stop()
```

(f) 在 `private func environment()` 之前加上这两个方法：

```swift
    private func persistOpenSessions() {
        guard !restoring else { return }
        journal.save(RestorePlan.records(from: sessions.map {
            OpenSessionSnapshot(agentId: $0.agentId, projectPath: $0.projectPath, createdAt: $0.createdAt,
                                state: $0.state, selected: $0.id == selectedId, fallbackResumeId: $0.resumeHint)
        }, agents: AgentRegistry.all))
    }

    private func restoreOpenSessions() async {
        guard GeneralSettings.restoreSessionsOnLaunch(.standard) else { return }
        let plan = RestorePlan.make(records: journal.load(), agents: AgentRegistry.all) { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard !plan.isEmpty else { return }
        restoring = true
        var selected: String?
        for record in plan {
            guard let agent = AgentRegistry.agent(id: record.agentId),
                  let id = await startSession(in: record.projectPath, agent: agent, resumeId: record.resumeId)
            else { continue }
            if record.selected { selected = id }
        }
        if let selected { selectedId = selected }
        restoring = false
        persistOpenSessions()
    }
```

- [ ] **Step 3: SettingsView 增加 General 分组**

在 `Sources/AgentMaster/SettingsView.swift` 中做以下修改：

(a) 把

```swift
    @State private var preferences: [String: AgentPreferences] = [:]
```

替换为

```swift
    @State private var preferences: [String: AgentPreferences] = [:]
    @AppStorage(GeneralSettings.restoreSessionsOnLaunchKey) private var restoreSessions = true
```

(b) 把

```swift
            Section {
                Text("Applies to new sessions. Running sessions keep their settings.")
```

替换为

```swift
            Section("General") {
                Toggle("Restore sessions on launch", isOn: $restoreSessions)
            }
            Section {
                Text("Applies to new sessions. Running sessions keep their settings.")
```

- [ ] **Step 4: 编译并跑全量测试**

Run: `swift build 2>&1 | grep -E "error"; swift test 2>&1 | grep -E "error:|Executed .* tests" | tail -2`
Expected: 没有 error；0 failures。

- [ ] **Step 5: 手工验证**

```bash
./scripts/bundle.sh
osascript -e 'quit app "AgentMaster"'; sleep 2; open build/AgentMaster.app
```

1. 分别在 `/tmp/am-demo` 和 `/tmp/am-demo2` 开会话，每个发一句 `say hi`，然后选中 am-demo2。
2. 运行 `cat ~/Library/Application\ Support/AgentMaster/open-sessions.json`：应该有两条记录，`resumeId` 分别是两个会话的 claude session id，am-demo2 那条的 `selected` 为 true。
3. 按 ⌘Q 退出，再次运行 `cat` 同一个文件：内容没变。也就是说，冻结记录生效，退出没有把记录清空。
4. 运行 `open build/AgentMaster.app`：两个会话都恢复了，终端里能看到之前的 `say hi` 对话，选中的是 am-demo2。
5. 立刻再按 ⌘Q，然后重新打开：两个会话仍然恢复。这验证的是在 SessionStart 到达之前退出时，会用 resumeHint 兜底。
6. 在一个会话里输入 `/exit`，或者用 ⌘W 关掉它，然后按 ⌘Q 再重新打开：只恢复另一个会话。
7. 在 Settings 里关掉 "Restore sessions on launch"，按 ⌘Q 再重新打开：一个会话都不恢复。然后把开关打开回来。
8. 运行 `ps -axo args | grep "bin/claude --settings" | grep -v grep`：恢复出来的会话参数末尾是 `--resume <id>`。

- [ ] **Step 6: 提交**

```bash
git add Sources/AgentMaster/SessionController.swift Sources/AgentMaster/AppModel.swift Sources/AgentMaster/SettingsView.swift
git commit -m "feat(app): restore open sessions on launch

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 7: 更新记录**

1. 在 `docs/adr/README.md` 中，把 0001 那一行的状态由 `已接受；实现将被 0004 重构` 改为 `已接受；实现已由 0004 重构（LaunchPreferences → ClaudeCodeAgent）`。
2. 在 memory 文件 `agentmaster-m3-carryovers.md` 中：
   - 把 "Feature the user asked for … choose the permission mode when creating a session" 那一条改为："Default permission mode and model are now per-agent in Settings (ADR 0001, 0004). Choosing them per session at creation is still open."
   - 在 M4 下加一条："Restore on launch is done (ADR 0005). Browsing history (TranscriptReader, ⌘K) is still open."

```bash
git add docs/adr/README.md
git commit -m "docs(adr): note 0001 implementation now lives in ClaudeCodeAgent

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```
