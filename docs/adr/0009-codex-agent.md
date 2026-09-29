# 0009 接入 Codex CLI 作为第二个 agent

- 日期：2026-09-29
- 状态：已接受（2026-09-29）
- 前置：ADR 0004（agent 抽象）、0005（启动时恢复会话）

## 背景

用户希望在 AgentMaster 里也能跑 OpenAI Codex CLI。ADR 0004 预留了 `AgentKind`，接新 agent 只需要新增一个实现。
在 codex-cli 0.154 上实测：

- codex 的 hooks 已是 stable，stdin 收到的 JSON 与 Claude Code 同形：`session_id`、`transcript_path`、`cwd`、`hook_event_name`、
  `permission_mode`、`prompt`、`tool_name`、`tool_input`、`tool_use_id`、`last_assistant_message`。shell 工具叫 `Bash`。
- hooks 可以用 `-c 'hooks.<Event>=[…]'` 按会话注入，不用改 `~/.codex/config.toml`。不认识的事件名会被忽略。
- 但 codex 只运行用户在它自己的界面里信任过的 hook。信任状态存在 `config.toml` 的 `hooks.state.<key>.trusted_hash`，
  key 和 hash 都是 codex 内部格式，也没有命令行能批准某个 hook。不加 `--dangerously-bypass-hook-trust` 时，注入的 hook 一个都不会触发。
- 改文件走 `Bash`，命令是 `apply_patch <<'PATCH' *** Begin Patch …`，只有 PreToolUse，没有 PostToolUse。
- 交互式 TUI 要等第一条消息才发 SessionStart。
- `codex resume <session_id> [选项]` 能接上原来的对话，写回同一个 rollout 文件。

## 决策

- **新增 `CodexAgent`**，id 为 `codex`，排在 `AgentRegistry.all` 的 Claude 之后，默认 agent 仍是 Claude。
  找 codex 的顺序：`AGENTMASTER_CODEX_PATH`、`~/.local/bin/codex`、`/opt/homebrew/bin/codex`、`/usr/local/bin/codex`、`PATH`。
- **设置项**：Default model（只有"跟随"和自定义，不猜模型名）、Default sandbox（`--sandbox`）、
  Default approval policy（`--ask-for-approval`，只列 0.154 接受的 `on-request`、`never`），以及开关
  「Show session activity in panels (bypasses Codex hook trust)」，默认打开。
- **开关打开时**加 `--dangerously-bypass-hook-trust`，并为 `SessionSettingsBuilder.hookEvents` 里的每个事件注入一条 `-c`，
  命令与 Claude 相同（`agentmaster-hook hook`），matcher 和超时规则也相同。事件继续走 HookServer 和 HookTranslator。
  用户知情的代价：在 AgentMaster 里开的 codex 会话，项目里没审过的 hook 也会不经确认直接运行。关掉开关就不注入，面板为空，也不能恢复。
- **文件改动**：HookTranslator 在 `Bash` 的 PreToolUse 里识别 `apply_patch`，由 `PatchParser.changes(fromApplyPatch:cwd:)` 解析。
  补丁没有行号，起始行记为 0，CHANGES 里只显示 `@@`；相对路径按 `cwd` 补全。
- **恢复**：`supportsResume` 为真，规则与 Claude 相同（有 session id 且 transcript 还在），启动参数最前面是 `resume <id>`。
- **新建入口**：点任何一个 ＋（项目行的和侧边栏底部的）都打开一个悬浮窗口，居中在主窗口上，可以拖动。
  - 用卡片选 agent，卡片上是手画的轮廓图标（Claude 的星芒、Codex 的 `>_`，不是官方图标）和它当前的默认模型，默认选中 Claude。
  - 模型默认是这个 agent 在 Settings 里的默认模型，也可以换成预设或自定义，只对这次启动有效；以后恢复这个会话时仍按当时 Settings 里的默认模型启动。
  - 底部的 ＋ 没有项目，窗口里多一行项目选择（最近项目或 Choose…）。
  - 快捷键不弹窗：⌘N 开 Claude，⌥⌘N（菜单 New Codex Session）开 Codex；⇧⌘N 已被 New Session in Folder… 占用。
  - 非默认 agent 的会话在侧边栏副标题前加 agent 名，比如 `Codex · idle`。

## 后果

- codex 会话有状态、标题、正在运行的工具、CHANGES、恢复。页头没有 USAGE，因为 codex 没有 statusline。
- `apply_patch` 没有 PostToolUse，补丁失败时 CHANGES 里仍会出现这次改动；Stop 会清掉一直"在运行"的这次调用。
- 新开的 codex 会话在第一条消息之前显示 `starting`。
- codex 自己的首次弹窗（版本更新、信任目录）照常出现在终端里，由用户处理。
