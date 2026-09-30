# 0012 接入 Kiro CLI 作为第三个 agent

- 日期：2026-09-29
- 状态：已接受（2026-09-29）
- 前置：ADR 0009（Codex）、0010（agent 适配层）

## 背景

用户希望在 AgentMaster 里也能跑 Kiro CLI。ADR 0010 在 2.24.1 上调研过它和 Claude、Codex 的差异。
这次在 kiro-cli 2.25.0 上实测：

- hook 只能写在 agent 配置（JSON）的 `hooks` 里。配置只从三个地方读：`<项目>/.kiro/agents/`、`~/.kiro/agents/`，
  或者环境变量 `KIRO_AGENT_CONFIG_DIR` 指定的目录。`--agent` 只接受名字，不接受文件路径。
- `KIRO_AGENT_CONFIG_DIR` 在默认的 v2 引擎里生效，但它**替换** `~/.kiro/agents`，不是追加：设了它，全局 agent
  （比如 `kirocrew-lite`）就加载失败。v3 引擎（`--v3`）完全不认这个变量。
- 在这个目录里放一个名为 `kiro_default` 的配置，就能盖掉内置的默认 agent，不用传 `--agent`，状态栏里的名字也不变。
  只写 `"tools": ["*"]`、不写 resources 的配置，`/context show` 里加载的东西和内置默认 agent 一样
  （AGENTS.md、README.md、`~/.kiro/skills`、14 个内置工具），读文件不问、跑 shell 要确认的权限行为也一样。
  区别是内置默认 agent 自带一段介绍 Kiro 功能的系统提示词，盖掉后就没有了。
- 事件是 `agentSpawn`、`userPromptSubmit`、`preToolUse`、`postToolUse`、`stop`，交互式 TUI 下都会触发；没有会话结束和子 agent 事件。
  payload 是下划线命名的 JSON，有 `session_id`、`cwd`、`prompt`、`tool_name`、`tool_input`、`tool_response`、`assistant_response`，
  但没有 `tool_use_id` 和 `transcript_path`。
- 工具：`shell`（`command`）、`read`（`operations[].path`）、`grep`、`glob`、`write`。`write` 用 `command` 区分
  `create`（`path`、`content`）、`strReplace`（`oldStr`、`newStr`）、`insert`（`content`、`insertLine`），返回里没有 patch。
- 会话存在 `~/.kiro/sessions/cli/<session_id>.json`，`kiro-cli chat --resume-id <id>` 能接上。
- `--trust-all-tools` 每次启动都会弹一个警告要用户确认，默认选项是退出。

## 决策

- **新增 `KiroAgent`**，id 为 `kiro`，排在 Codex 之后。可执行文件是 `kiro-cli`，覆盖变量 `AGENTMASTER_KIRO_PATH`。
  启动命令是 `kiro-cli chat`。
- **hook 注入**：每个会话在自己的会话目录下建 `kiro-agents/kiro_default.json`，内容是 `"tools": ["*"]` 加上每个 Kiro 事件一条
  `agentmaster-hook hook`（工具事件带 `matcher: "*"`），然后用 `KIRO_AGENT_CONFIG_DIR` 指向这个目录。不碰项目目录和 `~/.kiro`，
  会话关闭时随会话目录一起删掉。为此 `AgentKind` 增加 `hookEnvironment(for:)`（默认为空），`HookPlan` 增加按子目录写文件的方法。
  用户知情的代价写在开关的说明里：这个会话里用不了 `~/.kiro/agents` 下的全局 agent；v3 引擎下 hook 不生效。
- **`KiroHookDialect`** 把 payload 改写成 Claude 的形状，HookTranslator 不用改：
  - 事件名首字母大写，`assistant_response` 改名为 `last_assistant_message`。
  - SessionStart 补上 `transcript_path = ~/.kiro/sessions/cli/<id>.json`，共用的恢复规则（id 和 transcript 都在）直接可用。
  - 按工具名加输入（键排序后的 JSON）算 FNV-1a 作为 `tool_use_id`：同一次调用的 Pre 和 Post 输入相同，id 就相同。
  - 工具映射为 Bash、Read、Grep、Glob、Write、Edit；`create`、`strReplace`、`insert` 按 Claude 的样子补一个 `tool_response`
    （create 带内容，另外两个带 `structuredPatch`，没有行号，起始行记为 0）。其他工具保留原名。
- **设置项**：Default model（只有"跟随"和自定义，说明里提示用 `--list-models` 查 id）、Trust all tools（`--trust-all-tools`，默认关）、
  Show session activity in panels（hook 开关，默认开）。
- **图标和快捷键**：紫色圆角方块加白色幽灵（`AgentGlyphStyle.ghost`），幽灵轮廓是照 Kiro 的 App 图标描出来的一组点，Mac 和 Web 用同样的平滑曲线画；⌃⌘N 直接开 Kiro 会话，
  `AgentShortcut` 为此增加 `control`。

## 后果

- Kiro 会话有状态、标题（第一句 prompt）、正在运行的工具、CHANGES、恢复。没有 USAGE，因为 Kiro 没有 statusline。
- 没有 SessionEnd，退出 Kiro 时靠进程退出来结束会话，和其他 agent 一样。
- 相同输入的两次调用算出的 id 相同，但 Pre 和 Post 总是成对到达，面板上不会串。
- 用户如果平时用 `kiro-cli agent set-default` 设了别的默认 agent，AgentMaster 里的会话仍然用盖掉后的 `kiro_default`。
  需要用自己的 agent 时，关掉 hook 开关即可，此时 Kiro 完全保持原样，只是面板为空。
- 打开 Trust all tools 后，每次新建或恢复 Kiro 会话，都要在终端里确认一次 Kiro 的警告。
