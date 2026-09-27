# 侧边栏分组 + 审查面板收纳 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 侧边栏分组一眼可辨、会话以首条提问或自定义名为标题；右侧面板默认收成徽标细栏，USAGE 挪到页头。

**Architecture:**
- 纯逻辑单独做成可测试的函数：
  - Core 层：`SessionState.firstPrompt`
  - Bridge 层：`OpenSessionRecord.title`
  - UI 层：`SessionTitle`、`PanelSummary`、`HeaderUsage`
- 视图代码取自已经过用户目测认可的示例分支 `worktree-sidebar-panel-demo`（提交 bbe1fec），用 `git checkout bbe1fec -- <file>` 取出。
- 示例和 spec 有一处不一致：示例里面板默认展开，spec 要求默认收起。在 Task 3 里修正。

**Tech Stack:** Swift 5.10、SwiftPM、SwiftUI（macOS 14）、XCTest。

**Spec:** `docs/superpowers/specs/2026-09-27-sidebar-and-panel-design.md`（ADR 0006、0007）

## Global Constraints

- **依赖方向：** UI → Core ← Bridge；UI 不 import Bridge。不新增第三方依赖。
- **标题优先级：** 自定义名（trim 后非空）→ 首条提问 → `New session`。
  - 首条提问取第一个非空行。
  - 跳过空白和以 `/` 开头的输入。
  - 新的 claude session id 会重置首条提问；同一个 id 不会。
- **字体：**
  - `MuseFont.groupTitle` 用 15pt bold，非等宽，是整个界面唯一的非等宽字体。
  - `rowTitle` 用 15pt，等宽。
  - `rowSubtitle` 用 12pt，等宽。
- **面板收起状态：** UserDefaults 键 `panelCollapsed`，**默认 true**。切换方式：⌥⌘0（View 菜单）或页头按钮。
- **页头右侧：** `模型 · 模式 · ctx N% · $X.XX`，缺哪项就省略哪项。
  - `bypassPermissions` 显示为 `bypass`。
  - ctx ≥ 80 用 warning 色。
  - 悬停时显示 `↑in ↓out`。
- **恢复记录：** `OpenSessionRecord.title` 为可选字段；旧 JSON 没有这个键也必须能解码。
- **提交署名：** 每次提交以 `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>` 结尾。

## Review Focus

- **旧的 `open-sessions.json` 没有 `title`：** 必须能正常解码，不能导致恢复失败。→ Task 2 `testLegacyRecordWithoutTitleDecodes`
- **首条提问是 `/clear` 或 `/model`，或多行文本以空行开头：** 标题不能是斜杠命令，也不能为空。→ Task 1 `testFirstPromptSkipsBlankAndSlashCommandsAndKeepsTheFirst`
- **改名时输入全是空格：** 应恢复成默认标题，不能显示空白行。→ Task 3 `testSessionTitlePrefersCustomNameThenFirstPrompt`（覆盖显示规则），另有 `AppModel.rename` 的 trim 规则。
- **收起状态的默认值：** `MainWindow` 和 `AgentMasterApp` 里各有一个 `@AppStorage`，两者的默认值必须一致。否则第一次启动时，菜单文字和实际状态会相反。→ Task 3 用同一个常量 `InspectorSettings.collapsedByDefault`，并在手工验证里检查第一次启动。
- **只有 `main` 这一行的 AGENTS：** 必须算作空。→ Task 3 `testPanelSummaryCountsAndEmptiness`

---

### Task 1: SessionState.firstPrompt

**Files:**
- Modify: `Sources/AgentMasterCore/SessionState.swift`，从 bbe1fec 取出。
- Test: `Tests/AgentMasterCoreTests/SessionStateTests.swift`，在类末尾追加。

**Interfaces:**
- Produces: `SessionState.firstPrompt: String?`，以及 `static func titleLine(_:) -> String?`（internal）。

- [ ] **Step 1：写失败的测试。** 在 `SessionStateTests` 类最后一个 `}` 之前追加：

```swift
    func testFirstPromptSkipsBlankAndSlashCommandsAndKeepsTheFirst() {
        var state = SessionState()
        state.apply(.promptSubmitted(text: "   "))
        state.apply(.promptSubmitted(text: "/model"))
        XCTAssertNil(state.firstPrompt)
        state.apply(.promptSubmitted(text: "\n  fix the bug\nin add()"))
        XCTAssertEqual(state.firstPrompt, "fix the bug")
        state.apply(.promptSubmitted(text: "second prompt"))
        XCTAssertEqual(state.firstPrompt, "fix the bug")
    }

    func testFirstPromptResetsOnANewConversationOnly() {
        var state = SessionState()
        state.apply(.sessionStarted(claudeSessionId: "a", cwd: "/p", transcriptPath: nil))
        state.apply(.promptSubmitted(text: "hello"))
        state.apply(.sessionStarted(claudeSessionId: "a", cwd: "/p", transcriptPath: nil))
        XCTAssertEqual(state.firstPrompt, "hello")
        state.apply(.sessionStarted(claudeSessionId: "b", cwd: "/p", transcriptPath: nil))
        XCTAssertNil(state.firstPrompt)
    }
```

- [ ] **Step 2：确认测试失败。** 运行 `swift test --filter SessionStateTests`。预期：编译失败，报 `value of type 'SessionState' has no member 'firstPrompt'`。

- [ ] **Step 3：取出实现。** 运行 `git checkout bbe1fec -- Sources/AgentMasterCore/SessionState.swift`。这份文件相比当前分支只改了三处：
  - 新增 `firstPrompt` 属性；
  - 在新 id 的重置块里加上 `firstPrompt = nil`；
  - `.promptSubmitted(let text)` 分支在 `firstPrompt` 为 nil 时写入 `Self.titleLine(text)`。

  另外新增了 `titleLine`。用 `git diff --cached Sources/AgentMasterCore/SessionState.swift` 确认没有别的改动。

- [ ] **Step 4：确认测试通过。** 运行 `swift test --filter SessionStateTests`，预期 0 failures。

- [ ] **Step 5：提交。**

```bash
git add Sources/AgentMasterCore/SessionState.swift Tests/AgentMasterCoreTests/SessionStateTests.swift
git commit -m "feat(core): remember each conversation's first prompt for session titles

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: 恢复记录携带 title

**Files:**
- Modify: `Sources/AgentMasterCore/OpenSessionRecord.swift` 和 `Sources/AgentMasterBridge/SessionRestore.swift`，都从 bbe1fec 取出。
- Test: `Tests/AgentMasterBridgeTests/SessionRestoreTests.swift`，在类末尾追加。

**Interfaces:**
- Produces:
  - `OpenSessionRecord(..., selected:, title: String? = nil)`，以及属性 `.title`。
  - `OpenSessionSnapshot(..., fallbackResumeId:, title: String? = nil)`。
  - `RestorePlan.records` 会把 title 原样带上。

- [ ] **Step 1：写失败的测试。** 在 `SessionRestoreTests` 类最后一个 `}` 之前追加：

```swift
    // MARK: titles

    func testRecordsCarryTheTitle() {
        let snapshot = OpenSessionSnapshot(agentId: "claude", projectPath: "/p", createdAt: Date(timeIntervalSince1970: 0),
                                           state: state(.idle, claudeId: "a"), selected: false,
                                           fallbackResumeId: nil, title: "fix the bug")
        XCTAssertEqual(RestorePlan.records(from: [snapshot], agents: agents).map(\.title), ["fix the bug"])
    }

    func testTitleRoundTripsThroughTheJournal() {
        let journal = OpenSessionJournal(fileURL: journalURL)
        let titled = OpenSessionRecord(agentId: "claude", projectPath: "/p", createdAt: Date(timeIntervalSince1970: 60),
                                       resumeId: "a", selected: true, title: "fix the bug")
        journal.save([titled, record(resumeId: "b")])
        XCTAssertEqual(OpenSessionJournal(fileURL: journalURL).load().map(\.title), ["fix the bug", nil])
    }

    func testLegacyRecordWithoutTitleDecodes() throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = #"[{"agentId":"claude","projectPath":"/p","createdAt":0,"resumeId":"a","selected":false}]"#
        try Data(legacy.utf8).write(to: journalURL)
        let records = OpenSessionJournal(fileURL: journalURL).load()
        XCTAssertEqual(records.map(\.resumeId), ["a"])
        XCTAssertNil(records[0].title)
    }
```

- [ ] **Step 2：确认测试失败。** 运行 `swift test --filter SessionRestoreTests`。预期：编译失败，报 `extra argument 'title' in call`。

- [ ] **Step 3：取出实现。**

```bash
git checkout bbe1fec -- Sources/AgentMasterCore/OpenSessionRecord.swift Sources/AgentMasterBridge/SessionRestore.swift
```

用 `git diff --cached` 确认改动仅限于 title 字段、init 参数和 `records` 里的 `title: snapshot.title`。

- [ ] **Step 4：确认测试通过。** 运行 `swift test --filter SessionRestoreTests`，预期 0 failures。

- [ ] **Step 5：提交。**

```bash
git add Sources/AgentMasterCore/OpenSessionRecord.swift Sources/AgentMasterBridge/SessionRestore.swift Tests/AgentMasterBridgeTests/SessionRestoreTests.swift
git commit -m "feat(restore): journal each session's title so restored rows keep their names

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: 侧边栏、面板、页头和 App 接线

UI 的纯函数、视图和 App 层要一起改，因为 `SessionSidebar` 和 `SessionHeader` 的签名变了，App target 必须同时跟着改才能编译。

**Files:**
- Modify（从 bbe1fec 取出）：
  - `Sources/AgentMasterUI/SessionSidebar.swift`
  - `Sources/AgentMasterUI/PanelSection.swift`
  - `Sources/AgentMasterUI/SidePanel.swift`
  - `Sources/AgentMasterUI/SessionHeader.swift`
  - `Sources/AgentMasterUI/Style.swift`
  - `Sources/AgentMaster/SessionController.swift`
  - `Sources/AgentMaster/AppModel.swift`
  - `Sources/AgentMaster/MainWindow.swift`
  - `Sources/AgentMaster/AgentMasterApp.swift`
- Delete: `Sources/AgentMasterUI/UsagePanel.swift`
- Test: `Tests/AgentMasterUITests/AgentMasterUITests.swift`，在类末尾追加。

**Interfaces:**
- Consumes：Task 1 的 `firstPrompt`；Task 2 的 `OpenSessionSnapshot(title:)` 和 `record.title`。
- Produces：
  - `SessionTitle.text(customName:firstPrompt:)`
  - `PanelSummary(state:)`，字段有 `openTodos`、`runningAgents`、`finishedAgents`、`changedFiles`、`todoEmpty`、`agentsEmpty`、`changesEmpty`
  - `HeaderUsage.parts(usage:mode:) -> [Part]`，以及 `HeaderUsage.tokens(_:)`
  - `InspectorRail`
  - `InspectorSettings.collapsedKey`，以及本任务新增的 `collapsedByDefault`
  - `AppModel.rename(_:to:)`

- [ ] **Step 1：写失败的测试。** 在 `AgentMasterUITests` 类最后一个 `}` 之前追加：

```swift
    func testSessionTitlePrefersCustomNameThenFirstPrompt() {
        XCTAssertEqual(SessionTitle.text(customName: "Fix audio", firstPrompt: "say hi"), "Fix audio")
        XCTAssertEqual(SessionTitle.text(customName: "   ", firstPrompt: "say hi"), "say hi")
        XCTAssertEqual(SessionTitle.text(customName: nil, firstPrompt: nil), "New session")
    }

    func testPanelSummaryCountsAndEmptiness() {
        var state = SessionState()
        let empty = PanelSummary(state: state)
        XCTAssertTrue(empty.todoEmpty && empty.agentsEmpty && empty.changesEmpty, "main alone is not content")

        state.todos = [TodoItem(id: "1", subject: "a", status: .completed),
                       TodoItem(id: "2", subject: "b", status: .inProgress),
                       TodoItem(id: "3", subject: "c", status: .pending)]
        state.subagents = [SubagentInfo(id: "s1", type: "t", startedAt: Date()),
                           SubagentInfo(id: "s2", type: "t", startedAt: Date(), finishedAt: Date()),
                           SubagentInfo(id: "s3", type: "t", startedAt: Date(), finishedAt: Date())]
        state.changes = [FileChange(path: "a.swift", hunks: [])]
        let summary = PanelSummary(state: state)
        XCTAssertEqual(summary.openTodos, 2)
        XCTAssertEqual(summary.runningAgents, 1)
        XCTAssertEqual(summary.finishedAgents, 2)
        XCTAssertEqual(summary.changedFiles, 1)
        XCTAssertFalse(summary.todoEmpty || summary.agentsEmpty || summary.changesEmpty)
    }

    func testHeaderUsagePartsOmitMissingFieldsAndFlagHighContext() {
        XCTAssertEqual(HeaderUsage.parts(usage: nil, mode: nil), [])
        XCTAssertEqual(HeaderUsage.parts(usage: nil, mode: "bypassPermissions").map(\.text), ["bypass"])
        XCTAssertEqual(HeaderUsage.parts(usage: nil, mode: "plan").map(\.text), ["plan"])

        let usage = { (percent: Int?) in
            Usage(modelName: "Opus 5.5", contextUsedPercent: percent, inputTokens: 45_800, outputTokens: 1_500, costUSD: 6.5)
        }
        XCTAssertEqual(HeaderUsage.parts(usage: usage(79), mode: "default").map(\.text),
                       ["Opus 5.5", "default", "ctx 79%", "$6.50"])
        XCTAssertEqual(HeaderUsage.parts(usage: usage(79), mode: nil).map(\.warning), [false, false, false])
        XCTAssertEqual(HeaderUsage.parts(usage: usage(80), mode: nil)[1], HeaderUsage.Part(text: "ctx 80%", warning: true))
        XCTAssertEqual(HeaderUsage.parts(usage: usage(nil), mode: nil).map(\.text), ["Opus 5.5", "$6.50"])
        XCTAssertEqual(HeaderUsage.tokens(usage(1)), "↑45.8k ↓1.5k")
        XCTAssertNil(HeaderUsage.tokens(nil))
    }
```

- [ ] **Step 2：确认测试失败。** 运行 `swift test --filter AgentMasterUITests`。预期：编译失败，报 `cannot find 'SessionTitle' in scope`。

- [ ] **Step 3：取出示例代码。**

```bash
git checkout bbe1fec -- Sources/AgentMasterUI/SessionSidebar.swift Sources/AgentMasterUI/PanelSection.swift \
  Sources/AgentMasterUI/SidePanel.swift Sources/AgentMasterUI/SessionHeader.swift Sources/AgentMasterUI/Style.swift \
  Sources/AgentMaster/SessionController.swift Sources/AgentMaster/AppModel.swift Sources/AgentMaster/MainWindow.swift \
  Sources/AgentMaster/AgentMasterApp.swift
git rm -q Sources/AgentMasterUI/UsagePanel.swift
```

- [ ] **Step 4：按 spec 修正默认收起。**

在 `Sources/AgentMasterUI/SidePanel.swift` 里，把

```swift
public enum InspectorSettings {
    /// UserDefaults key: whether the right panel is collapsed to the rail. Survives relaunch.
    public static let collapsedKey = "panelCollapsed"
}
```

替换为

```swift
public enum InspectorSettings {
    /// UserDefaults key: whether the right panel is collapsed to the rail. Survives relaunch.
    public static let collapsedKey = "panelCollapsed"
    /// The inspector is an on-demand review panel, so a fresh install starts collapsed (ADR 0007).
    public static let collapsedByDefault = true
}
```

然后在 `Sources/AgentMaster/MainWindow.swift` 和 `Sources/AgentMaster/AgentMasterApp.swift` 两处，把

```swift
    @AppStorage(InspectorSettings.collapsedKey) private var inspectorCollapsed = false
```

替换为

```swift
    @AppStorage(InspectorSettings.collapsedKey) private var inspectorCollapsed = InspectorSettings.collapsedByDefault
```

- [ ] **Step 5：确认测试通过，全量回归。**
  - `swift test --filter AgentMasterUITests`：预期 0 failures。
  - `swift build 2>&1 | grep -E "error|warning: "`：预期没有输出。
  - `swift test 2>&1 | grep -E "error:|Executed .* tests" | tail -1`：预期 0 failures。

- [ ] **Step 6：检查 App 层的 diff。** 运行 `git diff --cached --stat`，并逐个过一遍这些文件：
  - `SessionController`：删掉了 `title`/`onTitle`，新增 `customName` 和 `displayTitle`。
  - `AppModel`：新增 `rename`；`startSession(title:)` 会设置 `customName`；snapshot 传入 `title: customName ?? state.firstPrompt`；恢复时传入 `record.title`。
  - `MainWindow`：新增 `onRename`；页头使用新参数；收起时显示 `InspectorRail`。
  - `AgentMasterApp`：`import AgentMasterUI`，新增 View 菜单项 `Hide/Show Inspector`，快捷键 ⌥⌘0。

  如果发现示例里有 spec 没要求的改动，删掉。

- [ ] **Step 7：提交。**

```bash
git add -A Sources Tests
git commit -m "feat(ui): bold project groups with rename and first-prompt titles; collapsible review inspector; usage in the header

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: 打包，与用户一起做 GUI 验证，清理示例

- [ ] **Step 1：打包并启动正式版。**

```bash
./scripts/bundle.sh
osascript -e 'quit app "AgentMaster"'; sleep 3; open build/AgentMaster.app
```

- [ ] **Step 2：和用户一起跑一遍清单。** 截图核对每一项。
  1. **首次启动。** 先执行 `defaults delete com.agentmaster.app panelCollapsed`，然后退出并重开。面板应当是收起的；View 菜单里应显示 "Show Inspector"。
  2. **分组。** 两个项目、三个会话时，项目名是粗体非等宽字体，分组之间有分隔线，点击分组可以折叠。
  3. **标题。** 新会话发一句话后，标题变成这句话。双击或 `Rename…` 可以改名；输入全是空格时恢复成默认标题。
  4. **恢复。** 改名后退出再重开，名字还在。
  5. **面板。** ⌥⌘0 或页头按钮可以切换。细栏上的徽标在这两种场景下都显示正确：
     - Write 工具写文件时，显示 `± n`；
     - 子 agent 运行时显示 `└ 1`，结束后变成 `✓ 1`。
  6. **页头。** 显示 `模型 · bypass · ctx · $`，鼠标悬停时显示 token。

- [ ] **Step 3：删除示例 worktree 和分支。** 只有在用户确认之后才执行：

```bash
git worktree remove .claude/worktrees/sidebar-panel-demo
git branch -D worktree-sidebar-panel-demo
```

- [ ] **Step 4：最终审查。** 用最强的模型审查整个分支（`git merge-base main HEAD..HEAD`），然后走 finishing-a-development-branch 流程。
