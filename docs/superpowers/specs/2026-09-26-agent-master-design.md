# AgentMaster 设计文档

- 日期：2026-09-26
- 状态：待审阅
- 调研资料：`docs/research/muse-replica-brief.md`、`docs/research/fact-check.md`

## 1. 背景与目标

复刻 Meta Muse Code 的交互与视觉体验，但**不重写 coding agent**：底层直接运行原版 Claude Code TUI，AgentMaster 作为 macOS 原生外壳负责呈现与交互接管。

### 1.1 用户与场景

- 自己/团队内部使用；复用本机 Claude Code 登录，不做对外分发、品牌合规、API key 认证。
- 完全兼容现有 Claude Code 生态：CLAUDE.md、skills、MCP、hooks、插件（如 superpowers）照常生效。

### 1.2 核心价值（全部纳入 MVP）

1. Muse 式原生面板：todo、子 agent 树、diff 预览、状态/用量。
2. 原生审批与澄清问题浮层：不必盯着终端。
3. 多会话 / 多项目管理。
4. 统一的 Muse 暗色视觉语言。

### 1.3 成功标准

- 在 AgentMaster 中使用 Claude Code 的一切能力与在终端中无差异（功能零损失）。
- 审批与提问可完全在原生浮层完成；AgentMaster 异常时 Claude Code 自动回退到原生行为，永不卡死。
- 右侧面板实时反映会话状态（事件到界面延迟 < 300ms）。

### 1.4 非目标（YAGNI）

- 不在原生界面重新渲染对话 transcript（对话只在终端里看）。
- 第一期无亮色主题、无 mobile 端、无自动更新/公证。
- 不实现 Claude Code 没有的 Muse 功能（goal、rewind 等）。
- 不 fork / 修改 Claude Code 本身（闭源 Mach-O 二进制）。

## 2. 技术验证结论（2026-09-26，Claude Code 2.1.283）

一次性验证脚本位于 `/tmp/ccspike`（不纳入项目）。

| 验证项 | 结论 |
|---|---|
| `claude --settings <file>` 按会话注入 hooks | ✅ 不改全局配置；事件含 `session_id`、`tool_use_id`、`transcript_path`、`cwd`、`permission_mode` |
| `PermissionRequest` hook | ✅ **仅在 Claude Code 本会弹审批框时触发**（被 allow 规则放行的调用不触发）；返回 `decision.behavior = allow/deny` 生效；携带 `permission_suggestions` |
| hook 阻塞等待 | ✅ hook 阻塞 8s，Claude Code 正常等待；hook `timeout` 可配置（设 600s） |
| `PreToolUse` 截获 `AskUserQuestion` | ✅ 返回 `permissionDecision: allow` + `updatedInput.answers = {问题文本: 选项label}`，模型正确收到答案 |
| todo 事件 | ✅ 新版为 `TaskCreate` / `TaskUpdate`（旧版为 `TodoWrite`），需兼容两者 |
| 子 agent 事件 | ✅ `Agent` 工具（可异步，`tool_response` 含 `agentId`）+ `SubagentStop` |
| 可用 hook 事件 | 二进制中存在：`PreToolUse`、`PostToolUse`、`PostToolUseFailure`、`PermissionRequest`、`Notification`、`UserPromptSubmit`、`Stop`、`SubagentStart`、`SubagentStop`、`PreCompact`、`SessionStart`、`SessionEnd` 等 |
| `-p` 模式 | ⚠️ 无 `AskUserQuestion` / Task 工具 → AgentMaster 必须运行**交互式** TUI |
| 环境变量 | ⚠️ 继承 `CLAUDE_CODE_CHILD_SESSION` 会导致 transcript 不保存 → 启动子进程前必须清理 |

## 3. 整体架构

```
┌──────────────── AgentMaster（SwiftUI）──────────────────┐
│ ① 会话侧边栏 │ ② 终端区（SwiftTerm）     │ ③ 原生面板      │
│             │   PTY 运行原版 claude TUI  │ TODO / AGENTS  │
│             │                          │ CHANGES / USAGE │
│ ④ 原生审批 / 提问浮层（覆盖终端区底部）                     │
└────────────────────────────────────────────────────────┘
                 ↑ SessionEvent（App 内部统一事件模型）
┌──────────────── Bridge 层 ──────────────────────────────┐
│ SessionManager  每会话一个 PTY；清理环境变量；生成 --settings │
│ HookServer      Unix socket 服务                          │
│ HookShim        随 App 打包的极小 CLI，被 Claude Code 当 hook 调用 │
│ Translator      Claude Code 工具/事件 → SessionEvent（唯一映射点）│
│ TranscriptReader 读取会话 JSONL，用于历史/恢复             │
└────────────────────────────────────────────────────────┘
```

### 3.1 关键决策

1. 终端内始终是原版 Claude Code；原生侧只做**呈现增强**与**交互接管**（审批、提问）。
2. 审批使用 `PermissionRequest` hook；提问使用 `PreToolUse`（matcher `AskUserQuestion`）。
3. HookShim 用 Swift 编写、打包在 `.app/Contents/Helpers/`，不依赖 python/bash。
4. Translator 是唯一理解 Claude Code 格式的模块；UI 只依赖 `SessionEvent`。
5. 每会话 = 一个 PTY + 一个 AgentMaster 会话 ID；Claude Code 的 `session_id` 在 `SessionStart` 事件中与之绑定。

## 4. 组件设计

### 4.1 SessionManager（Bridge）

- 启动：`claude --settings <生成的会话 settings.json> [--resume <id>]`，cwd = 项目目录。
- 环境：继承用户登录 shell 环境（保证 PATH、登录态一致），**移除** `CLAUDE_CODE_CHILD_SESSION` 及其他 `CLAUDE_CODE_*` 会话标记变量；注入 `AGENTMASTER_SESSION_ID`、`AGENTMASTER_SOCKET`。
- 定位 claude 可执行文件：优先用户设置路径，其次登录 shell 中 `which claude`。
- 会话 settings.json（写入 `~/Library/Application Support/AgentMaster/sessions/<id>/settings.json`）包含：
  - 所有需要的 hook 事件 → HookShim；`PermissionRequest` 与 `PreToolUse(AskUserQuestion)` 的 `timeout` 设为 600；
  - statusLine → HookShim 的 `statusline` 子命令（既输出 Muse 式底栏，又把用量推送给 App）；
  - spinnerVerbs（Muse 文案）。
- `--settings` 与用户自身 settings 叠加，不覆盖用户的 hooks / 插件（实现时需验证合并语义，见 §8）。

### 4.2 HookShim

- 子命令：`hook`（默认）、`statusline`。
- `hook` 流程：读 stdin JSON → 附加 `AGENTMASTER_SESSION_ID` → 连 socket 发送。
  - 通知类事件：发送后立即退出，stdout 为空。
  - 决策类事件（PermissionRequest、PreToolUse/AskUserQuestion）：阻塞等待 App 回复，把回复原样写到 stdout 后退出。
- 回退规则（永不卡死）：
  - socket 连不上 / App 未运行 → 立即退出，stdout 为空（Claude Code 走原生流程）。
  - 等待超过 590s → 退出，stdout 为空。
  - App 回复 `handleInTerminal` → 退出，stdout 为空。
- 协议：socket 上每条消息为一行 JSON（NDJSON）：`{id, sessionId, kind: "event"|"request", payload}`；回复 `{id, response}`。

### 4.3 HookServer + Translator

- HookServer：监听 `~/Library/Application Support/AgentMaster/agentmaster.sock`（权限 0600），按 `sessionId` 分发到对应 SessionStore。
- Translator 输出 `SessionEvent`：

```swift
enum SessionEvent {
  case sessionStarted(claudeSessionId: String, cwd: String, transcriptPath: String)
  case promptSubmitted(text: String)
  case toolStarted(ToolCall)
  case toolFinished(ToolCall, ToolResult)          // success / failure, durationMs
  case todosChanged([TodoItem])                   // 由 TaskCreate/TaskUpdate/TodoWrite 合成
  case subagentStarted(agentId: String, description: String)
  case subagentFinished(agentId: String)
  case approvalRequested(ApprovalRequest)          // 需要回复
  case questionAsked(QuestionRequest)              // 需要回复
  case usageUpdated(Usage)                         // 来自 statusline
  case needsAttention(message: String)             // Notification
  case turnFinished(lastMessage: String?)          // Stop
  case sessionEnded
}
enum ToolKind { case read, search, edit(path: String, diff: Diff), write(path: String),
                shell(command: String, description: String?), web, agent, other(name: String) }
```

- 映射表（集中一处，Claude Code 改名只改这里）：
  - `Read`、`Grep`、`Glob` → read / search
  - `Edit`、`MultiEdit` → edit（diff 由 old_string/new_string 计算）；`Write` → write（与写入前文件内容对比计算 diff，前内容在 PreToolUse 时读取）
  - `Bash` → shell
  - `TaskCreate`、`TaskUpdate`、`TodoWrite` → todosChanged（Translator 维护每会话 todo 状态）
  - `Agent` / `Task` → subagentStarted（`agentId` 取自 PostToolUse 的 `tool_response`）；`SubagentStop` → subagentFinished
  - 未知工具 → `other(name)`；未知事件/字段 → 记录日志并忽略

### 4.4 TranscriptReader

- 按需读取 `transcript_path` 的 JSONL：冷启动重建会话列表、App 重启后补齐面板状态、历史查看。
- 恢复会话：在新 PTY 中运行 `claude --resume <id>`。
- 只读，不写 Claude Code 的任何文件。

### 4.5 UI

**窗口**：默认 1440×900；三栏可拖动，侧栏、右栏可折叠；透明沉浸式标题栏显示 `AgentMaster ▸ <项目> · <会话名>` 与 `模型 · effort · 权限档位`。

```
┌──────────┬──────────────────────────────┬──────────────────────┐
│ 项目      │                              │ TODO                 │
│ ▾ my-proj │                              │  ✓ Read app.py       │
│   ◆ 修bug │   SwiftTerm：原版 claude TUI   │  ◆ Fix add()         │
│   ◇ 重构  │   （Muse 终端配色）            │  ◇ Run script        │
│ ▸ other   │                              │ AGENTS               │
│           │                              │  main                │
│           │                              │  └ • reviewer 3s·1.6k │
│           │                              │ CHANGES              │
│           │                              │  app.py  +1 −1   ›   │
│ ＋ 新会话  │                              │ USAGE ctx 34% · $0.12 │
└──────────┴──────────────────────────────┴──────────────────────┘
```

1. **会话侧边栏**：按项目目录分组；状态字形 `◈` 运行中（动画）/ `◆`(accent) 等待你处理 / `◇` 空闲 / `✓` 已结束。等待处理时发系统通知并显示 Dock 角标。
2. **终端区**：SwiftTerm，ANSI 16 色与 truecolor 映射到 Muse 配色；顶部 1px 分隔线在等待处理时变 accent。
3. **右侧面板**：四个可折叠区块，区块标题大写粗体 muted。
   - TODO：`✓`(success)+muted 文本 / `◆`(teal)+text / `◇` muted。
   - AGENTS：Muse 树形，`main` 粗体 accent，子 agent 行右对齐耗时与 token，完成显示 `✓`。
   - CHANGES：本会话改动文件 `+N −N`，点击在右栏展开内联 unified diff（语法高亮 Catppuccin Mocha）。
   - USAGE：上下文占比、token、费用、模型、effort（来自 statusline）。
4. **审批浮层**：从终端区底部滑出。

```
Would you like to run the following command?
  $ rm -rf build/
› 1. Yes, proceed               (y)
  2. Always allow `rm:*` here   (a)   ← 仅当存在 permission_suggestions
  3. No, tell Claude why…       (n)
  4. Handle in terminal         (t)
```
   方向键 / 数字 / 字母快捷键；Esc = 拒绝。App 不在前台时发可操作系统通知（允许 / 拒绝）。

5. **提问浮层**：同位置；`1 of N` 分页；单选 `›`、多选 `[x]/[ ]`；自动追加 "None of the above"（选中时要求填写备注，备注作为答案文本返回）；Tab 添加备注；提交前 Review 页。
6. **命令面板（⌘K）**：新建会话、切换会话、恢复历史会话、打开设置。

### 4.6 视觉规范（Theme）

| Token | Hex | 用途 |
|---|---|---|
| bg | #1e1e22（暂定，实现时微调） | 窗口与终端背景 |
| text | #ccd3db | 正文 |
| muted | #8a9098 | 次要信息、工具行 |
| faint | #676c74 | 分隔线、提示、树线 |
| accent | #5aa0ff | 选中、链接、主操作 |
| selection | #263854 | 选中会话底色 |
| teal | #8abeb7 | 进行中、代码 |
| success / error / warning | #a6e3a1 / #f38ba8 / #ffe14a | 状态 |
| diffDelBg / diffDelFg | #4a221d / #cc6666 | diff 删除 |
| diffAddBg / diffAddFg | #213a2b / #b5bd68 | diff 新增 |
| shimmer | #676c74 → #767b83 → #9aa0a8 → #bdc4cc → #ccd3db | spinner 文字扫光 |

- 字体：全局等宽，默认 SF Mono，可设置；字号 13 / 11 两级。
- 层级靠字重、颜色、字号，不用色块和阴影；圆角 6；线条 1px faint。
- 字形：`◆ ◈ ◇ ✓ ✗ ⎿ └ • ❯ ›`；spinner `◆◈◇` 约 1 帧/秒 + 5 级扫光。

## 5. 数据流

1. **通知事件**：claude → HookShim → socket → HookServer → Translator → SessionStore（`@Observable`）→ SwiftUI。
2. **审批**：PermissionRequest → HookShim 阻塞 → App 浮层 → 用户选择 → 回复：
   - 允许：`{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
   - 始终允许：allow，并按 `permission_suggestions` 写入规则（写入语义实现时验证）
   - 拒绝：`behavior: "deny"`，`message` 为用户填写的原因
   - 在终端处理：空输出
3. **提问**：PreToolUse(AskUserQuestion) → 浮层 → 回复 `permissionDecision: "allow"` + `updatedInput`（原 `tool_input` + `answers`）。
4. **用量**：statusline 子命令收到 Claude Code 的 statusLine JSON → 推送 usageUpdated → 同时向 stdout 输出 Muse 式底栏文本。

## 6. 错误处理

| 情况 | 处理 |
|---|---|
| App 未运行 / socket 不可用 | HookShim 立即空输出退出 → Claude Code 原生行为 |
| 决策等待超时（590s） | HookShim 空输出退出；浮层显示"已转回终端处理" |
| 用户退出 App 时有挂起请求 | HookServer 关闭前对所有挂起请求回复空输出 |
| 未知工具 / 事件 / 字段 | 记录日志；UI 以 `other` 通用样式降级展示 |
| claude 进程退出 | 侧边栏标记已结束，保留面板快照，可一键 `--resume` |
| 找不到 claude 可执行文件 | 首次启动引导设置路径 |

## 7. 工程结构

```
agent-master/
├─ App/                  SwiftUI App 入口、窗口、命令面板、设置
├─ Packages/
│  ├─ Core/              SessionEvent、领域模型、Theme token（纯 Swift）
│  ├─ Bridge/            SessionManager、HookServer、Translator、TranscriptReader
│  ├─ HookShim/          可执行 target，打包至 .app/Contents/Helpers
│  ├─ UI/                侧边栏、右侧面板、浮层、DiffView
│  └─ TerminalKit/       SwiftTerm 封装（TerminalView 协议，可替换为 libghostty）
├─ Tests/Fixtures/       真实会话录制的 hook 事件 JSON
└─ docs/
```

- 依赖方向：UI → Core ← Bridge；UI 不接触 Claude Code 格式。
- 第三方：SwiftTerm；diff 使用自实现 Myers 算法（无依赖）；语法高亮在 M2 选型（候选 Splash、tree-sitter 绑定）。
- 最低 macOS 14；本地签名，内部分发。

## 8. 待实现时验证的点

1. `--settings` 与用户全局/项目 settings 的合并语义（hooks 是否叠加而非覆盖）。
2. PermissionRequest 挂起期间终端内是否仍显示原生审批框；"始终允许"的规则写入方式。
3. `customTheme` 能否用于让 Claude Code TUI 本身使用 Muse 配色（字符串存在于二进制中，未验证用法）。
4. statusLine JSON 中可用的用量字段。

## 9. 测试策略

- **Translator / Core 单元测试**：fixture 回放（真实 hook JSON → 期望 SessionEvent），覆盖 TaskCreate 与 TodoWrite 两个版本。
- **HookShim + HookServer 集成测试**：正常请求/响应、App 未运行立即放行、超时放行、App 退出时挂起请求被释放。
- **端到端冒烟脚本**：驱动真实交互式 claude（haiku），触发审批、提问、todo、子 agent 各一次，校验事件序列。消耗 token，仅手动/发布前运行。
- **UI**：SwiftUI Preview + fixture 状态；不做自动化 UI 测试。

## 10. 里程碑

| # | 里程碑 | 完成标准 |
|---|---|---|
| M1 | 单会话壳 | App 内运行 claude，Muse 终端配色，环境变量清理，transcript 正常保存 |
| M2 | 桥接打通 | HookShim ↔ socket ↔ Translator，TODO / AGENTS / CHANGES / USAGE 实时更新 |
| M3 | 原生审批与提问 | 两个浮层 + 系统通知，§6 回退场景全部测试通过 |
| M4 | 多会话与历史 | 侧边栏、状态字形、恢复会话、⌘K |
| M5 | 打磨 | spinner/扫光动效、statusline 底栏与 spinnerVerbs、customTheme 调研、设置页 |

M1–M3 构成可用 MVP。Mobile 端在 M5 稳定后另立项目，届时将 Bridge 事件以 WebSocket 暴露。
