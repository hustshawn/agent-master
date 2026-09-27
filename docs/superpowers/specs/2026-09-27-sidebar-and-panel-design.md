# 侧边栏分组 + 右侧面板收纳 设计文档

- 日期：2026-09-27
- 状态：待审阅
- 决策记录：`docs/adr/0006-sidebar-groups-and-session-titles.md`、`docs/adr/0007-collapsible-inspector-and-header-usage.md`
- 前置：主 spec `2026-09-26-agent-master-design.md` §4.5；`2026-09-26-agent-abstraction-design.md` §8（会话恢复）
- 路线图：这是面板和侧边栏改造的第 1 步，后面依次是子 agent 详情、基于 git 的 CHANGES、待处理收件箱（M3）

## 1. 背景与目标

用户反馈了两个问题：
1. **侧边栏里不同项目区分度低。** 分组标题和会话行颜色一样、字号更小，分组之间没有边界；会话标题全是 claude 设置的终端标题 `✳ Claude Code`，同一个项目里的几个会话分不出来。
2. **右侧面板大多数时候是空的，又不能操作。** TODO 和 CHANGES 经常为空，USAGE 占了一整块，面板下面大半是空白，却固定占着大约四分之一的窗口宽度。

目标：
- 让项目分组和会话一眼就能分清。
- 面板只在有内容时占地方，并且可以整体收起。
- USAGE 挪到页头。

### 1.1 范围

做：
- 侧边栏的分组标题、分隔线、分组折叠、缩进。
- 会话标题：自定义名称 → 第一条提问 → `New session`；支持改名，恢复后保留。
- 面板里空的区块折成一行；整个面板可以收起成带徽标的细栏（⌘⌥0），收起状态重启后保留。
- 页头显示会话标题和用量。

不做：
- 面板根据内容自动收起。用户选了手动切换，因为自动收起会让终端宽度跳动。
- 拖动改变面板宽度（现在已经支持）。
- 子 agent 详情、基于 git 的 CHANGES、收件箱。这些属于路线图的后续步骤。
- 分组折叠状态跨重启保留。

### 1.2 成功标准

- 截图里不同项目的分组一眼可辨，同一项目下的会话按第一条提问区分。
- 改名后的标题在退出、重开之后仍然保留。
- 面板收起后终端变宽，细栏上的徽标反映当前会话的状态；重启后收起状态不变。
- 页头能看到 ctx 和费用；面板里不再有 USAGE 区块。

## 2. 侧边栏（ADR 0006）

### 2.1 分组标题

```
▾ 📁 am-demo2            1  ＋
      ◇ 修复音效
        idle · Opus 5.5
──────────────────────────────
▾ 📁 am-demo             2  ＋
      ◇ say hi
        idle · Opus 5.5
```

- **标题行**：
  - `▾`/`▸`，然后是 SF Symbol `folder`，然后是项目名。
  - 项目名用新增的字体 token `MuseFont.groupTitle`（13pt、semibold、等宽），颜色是 `Palette.text`。
  - 右侧依次是会话数（`MuseFont.small`、`Palette.muted`）和 `＋`。
  - 鼠标悬停显示完整路径（`.help`）。
- **折叠**：点击标题行（`＋` 除外）切换折叠，折叠后隐藏这个分组的会话行。
  - 状态存在 `SessionSidebar` 的 `@State collapsed: Set<String>` 里，键是项目路径，不跨重启保留。
  - 如果选中的会话在一个已折叠的分组里，这个分组仍然折叠，选中状态不变。
- **分组之间**：用 `HairLine()` 分隔，上下各 8pt 间距。第一个分组上方不画分隔线。
- **会话行**：左侧缩进 18pt，让它和标题行明显错开。

### 2.2 会话标题

- **显示规则**：纯函数 `SessionTitle.text(customName:firstPrompt:) -> String`（放在 AgentMasterUI）。
  - 自定义名称，去掉首尾空白后非空，就用它。
  - 否则用第一条提问的第一行，去掉首尾空白。
  - 都没有时显示 `New session`。
  - 显示时单行截断（`lineLimit(1)`），不在函数里截字符。
- **第一条提问**：`SessionState` 新增 `public var firstPrompt: String?`。
  - 收到 `.promptSubmitted(text)` 时，如果 `firstPrompt` 为 nil，并且 text 去掉空白后非空、不以 `/` 开头，就记下来。
  - 收到新 claude session id 的 `sessionStarted`（也就是 `/clear`）时，和其他面板一起重置为 nil。
- **不再使用终端标题**：删掉 `SessionController.title` 和 `onTitle` 的赋值。`TerminalSession.onTitle` 这个接口保留，但 App 不再订阅。
- **改名**：
  - 入口：右键菜单里的 `Rename…`，或者双击标题。
  - 标题原地变成一个 TextField，初始值是当前显示的标题。回车提交，Esc 取消，失去焦点也算提交。
  - 提交后调用 `onRename(id, text)`。在 App 层，text 去掉空白后为空，就清除自定义名称，否则设为自定义名称。
  - 状态放在 `SessionSidebar` 的 `@State editingId: String?` 和 `@State draft: String`。
- **自定义名称存在哪里**：`SessionController.customName: String?`，可观察。`AppModel.rename(_ id: String, to name: String)` 负责设置它，并触发一次保存恢复记录。

### 2.3 标题在恢复后保留

- `OpenSessionRecord` 新增 `public let title: String?`。它是可选字段，旧格式的 JSON 没有这个字段也能正常解码。
- `OpenSessionSnapshot` 新增 `title: String?`。AppModel 传入 `customName ?? state.firstPrompt`，`RestorePlan.records` 原样写进记录。
- 恢复时，`startSession(in:agent:resumeId:title:)` 把 `record.title` 设为新会话的 `customName`。
  - 恢复出来的会话里 `firstPrompt` 为空，因为 `--resume` 不会重放 UserPromptSubmit，所以必须靠 `customName` 保留标题。
  - 代价：恢复以后，"第一条提问"和"用户改过的名字"没法再区分，但显示效果一样，可以接受。

## 3. 右侧面板（ADR 0007）

### 3.1 空区块折成一行

- `PanelSection` 新增参数 `isEmpty: Bool`。
  - 为 true 时只渲染一行：左边是标题，右边是 `—`（`Palette.faint`），不显示折叠箭头和内容。
  - 为 false 时和现在一样。
- `SidePanel` 只剩三个区块：TODO、AGENTS、CHANGES。**删除 USAGE 区块**，`UsagePanel.swift` 一并删除。
- 判断区块是否为空，用纯函数 `PanelSummary(state:)`（放在 AgentMasterUI）：
  - `todoEmpty = todos.isEmpty`
  - `agentsEmpty = subagents.isEmpty`。只有 `main` 这一行不算有内容。
  - `changesEmpty = changes.isEmpty`

### 3.2 收起成细栏

- 收起状态存在 UserDefaults 的 `panelCollapsed` 键里（Bool，默认 false），App 层用 `@AppStorage` 读写。
- 切换有两个入口：
  - 菜单 View ▸ `Toggle Inspector`，快捷键 ⌘⌥0。
  - 页头最右侧的按钮，SF Symbol `sidebar.right`。
- **收起后**：
  - 面板位置显示一条 28pt 宽的细栏 `InspectorRail`，背景是 `Palette.bg`，左边有一条 `HairLine`。
  - 细栏里竖向排列徽标，数量为 0 的不显示：
    - `◆ n`：TODO 里没完成的项数，颜色 `Palette.teal`。
    - `└ n`：正在运行的子 agent 数，颜色 `Palette.teal`；没有运行中的、但有已结束的，显示 `✓ n`，颜色 `Palette.success`。
    - `± n`：CHANGES 里的文件数，颜色 `Palette.muted`。
  - 点击细栏任意位置就展开面板。
- 徽标的计数也放在 `PanelSummary` 里：`openTodos`、`runningAgents`、`finishedAgents`、`changedFiles`。
- 没有选中会话时既不显示面板，也不显示细栏，和现在一样。

### 3.3 页头

```
AgentMaster ▸ am-demo ▸ say hi              Opus 5.5 · bypass · ctx 5% · $6.54   ▯
```

- **左侧**：`AgentMaster ▸ <项目> ▸ <会话标题>`。会话标题用 `Palette.text`，单行截断。这样也补上了 M5 待办里"页头缺少会话名"这一项。
- **右侧**：`模型 · 模式 · ctx N% · $X.XX`，缺哪一项就不显示哪一项。
  - 模式显示名：`bypassPermissions` 显示为 `bypass`，其他照原样显示。
  - 当 ctx ≥ 80% 时，`ctx N%` 使用 `Palette.warning`。
  - 悬停整段文字时显示 `↑<输入 token> ↓<输出 token>`，用 `TokenFormat.short` 格式化。
- 最右侧是面板切换按钮。
- 文本拼接用纯函数 `HeaderUsage.parts(usage:mode:) -> [HeaderUsage.Part]`，其中 `Part` 为 `(text: String, warning: Bool)`，方便测试。

## 4. 代码改动

| 文件 | 改动 |
|---|---|
| `AgentMasterCore/SessionState.swift` | `firstPrompt` 字段及其规则 |
| `AgentMasterCore/OpenSessionRecord.swift` | 增加 `title: String?` |
| `AgentMasterBridge/SessionRestore.swift` | `OpenSessionSnapshot.title`；`records` 把它带上 |
| `AgentMasterUI/Style.swift` | 增加 `MuseFont.groupTitle` |
| `AgentMasterUI/SessionSidebar.swift` | 分组标题、分隔线、折叠、缩进、改名、`SessionTitle`；`SessionRowModel` 的 title 改由调用方传入 `SessionTitle` 的结果 |
| `AgentMasterUI/PanelSection.swift` | `isEmpty` 参数 |
| `AgentMasterUI/SidePanel.swift` | 三个区块；增加 `PanelSummary` |
| `AgentMasterUI/InspectorRail.swift`（新增） | 细栏 |
| `AgentMasterUI/SessionHeader.swift` | 会话标题、用量、切换按钮；增加 `HeaderUsage` |
| `AgentMasterUI/UsagePanel.swift` | 删除 |
| `AgentMaster/SessionController.swift` | 删除 `title`；增加 `customName`；`row` 使用 `SessionTitle` |
| `AgentMaster/AppModel.swift` | `rename`；恢复时传入 title；snapshot 带上 title |
| `AgentMaster/MainWindow.swift` | 根据收起状态显示面板或细栏；把新参数传给页头 |
| `AgentMaster/AgentMasterApp.swift` | View 菜单增加 Toggle Inspector（⌘⌥0） |

## 5. 出错与边界

| 情况 | 处理 |
|---|---|
| 第一条提问是多行文本 | 只取第一行；如果第一行为空，就取第一个非空行 |
| 第一条提问是 `/model`、`/clear` 这类斜杠命令 | 跳过，等下一条 |
| 改名时输入的全是空格 | 清除自定义名称，恢复默认标题 |
| 旧版 `open-sessions.json` 里没有 title | 解码为 nil，恢复出的会话显示 `New session`，直到用户再次提问或改名。恢复出来的进程里 `firstPrompt` 为空，所以用户恢复后发的第一条提问就会成为新的 `firstPrompt` |
| 面板收起时切换会话 | 细栏的徽标跟着切到当前会话 |
| usage 还没到达（statusline 还没来） | 页头右侧只显示已有的模型和模式 |

## 6. 测试

- `SessionStateTests`：
  - `firstPrompt` 只记第一条。
  - 跳过空文本和 `/` 开头的命令。
  - 多行文本只取第一个非空行。
  - 新的 claude session id 会重置它，同一个 id 不会。
- `AgentMasterUITests`：
  - `SessionTitle`：优先级顺序；只有空白的自定义名称视为没有。
  - `PanelSummary`：各项计数；只有 main 这一行时 agentsEmpty 为 true。
  - `HeaderUsage`：
    - 字段缺失时对应部分不显示。
    - bypassPermissions 显示为 bypass。
    - ctx 为 80 时带 warning 标记，79 时不带。
- `SessionRestoreTests`：
  - `records` 会带上 title。
  - 没有 `title` 字段的旧 JSON 能解码，title 为 nil。
  - 带 title 的记录能写入后原样读回。
- 手工验证：
  1. 两个项目、三个会话时截图，检查分组的区分度，以及标题是否等于第一条提问。
  2. 改名后退出、重开，名字还在。
  3. ⌘⌥0 收起面板，细栏的徽标数量正确；重启后仍然是收起状态。
  4. 页头显示 ctx 和费用；ctx ≥ 80% 时变色（可以用长对话或 fixture 验证）。
