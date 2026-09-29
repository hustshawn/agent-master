# 0010 Agent 适配层：每个 agent 只描述自己的差异

- 日期：2026-09-29
- 状态：已接受（2026-09-29）
- 前置：ADR 0004（agent 抽象）、0009（接入 Codex）

## 背景

接入 Codex（ADR 0009）以后，Claude 和 Codex 的实现有一半是重复的：找可执行文件、找 hook helper、生成会话环境、
判断能不能恢复，都各写了一遍。另外有几处写死了 agent id：图标、⌥⌘N 菜单、模型选项名 `"model"`。
Codex 的 `apply_patch` 解析也写在通用的 HookTranslator 里。

用户以后还想接 Kiro CLI 等 agent，希望每接一个都尽量复用已有逻辑。harness 本身是各家 CLI 自己的，
AgentMaster 只需要知道每家在哪几件事上不一样。

在 Kiro CLI 2.24.1 上调研过它和 Claude、Codex 的差异，确认下面的拆法能容纳它：

| | Claude Code | Codex | Kiro CLI |
|---|---|---|---|
| hook 怎么注入 | settings.json + `--settings` | `-c hooks.X=…` + `--dangerously-bypass-hook-trust` | `<项目>/.kiro/agents/<名>.json` + `--agent <名>` |
| 事件名 | `PreToolUse` 等 | 同 Claude | `preToolUse` 等，首字母小写，没有 SessionEnd |
| 工具名 | `Bash`、`Edit`、`Write` | `Bash`（改文件是 Bash 里的 apply_patch） | `shell`、`write` |
| 恢复会话 | `--resume <id>` | `resume <id>` | `--resume-id <id>` |

## 决策

`AgentKind` 分成两部分：agent 自己**声明**的部分，和协议扩展里**共用**的部分。

**每个 agent 只写这些：**

- `id`、`displayName`
- `executable: ExecutableSpec`：可执行文件名、覆盖路径的环境变量、要跳过的同名包装（比如 cmux 的 claude）
- `glyph: AgentGlyphStyle`：新建窗口里的轮廓图标
- `shortcut: AgentShortcut?`：可选，跳过新建窗口、直接启动的菜单快捷键
- `options(environment:)`：设置项。默认模型的选项 id 统一用 `AgentOption.modelId`，新建窗口据此覆盖模型
- `hooksEnabled(preferences:)` 和 `hookArguments(for: HookPlan)`：把通用的 hook 清单写成自己的格式，返回让 agent 加载它的参数
- `arguments(preferences:hookArguments:resumeId:)`：完整的参数列表，由 agent 决定 hook 参数和恢复参数放在哪里
- `hookDialect: HookDialect`：可选。把自己的 payload 转成 Claude 的形状（`normalize`），
  或者补充 Claude 形状表达不了的文件改动（`fileChanges`）。默认是 `ClaudeHookDialect`，原样透传
- `supportsResume`：可选，默认 false

**共用的部分：**

- `launch`：找可执行文件，hooks 打开时找 hook helper 并生成 `HookPlan`，清理会话环境，拼参数。找不到时统一报
  `AgentLaunchError.notFound(agent:executable:)`，提示文案由 `ExecutableSpec` 生成。
- `HookPlan`：监听哪些事件、每个事件的 matcher 和超时、hook 命令，以及把文件写进本会话目录的方法（会话关闭时删除）。
  事件清单沿用 `SessionSettingsBuilder` 里的 Claude 事件名，名字不同的 agent 在自己的格式里做映射。
- `resumeId(from:)`：`supportsResume` 为真时，只要 hooks 报过的会话 id 对应的 transcript 还在，就能恢复。
- HookServer、`agentmaster-hook`、HookTranslator（先经过 dialect）、SessionState、面板、侧边栏、新建窗口、
  Settings、恢复会话：都不知道具体是哪个 agent。菜单里的 "New <agent> Session" 按 `shortcut` 从注册表生成。
- `SessionState.claudeSessionId` 改名为 `agentSessionId`。
- `AgentLaunchRequest` 增加 `projectPath`，给需要把配置写进项目目录的 agent 用（比如 Kiro）。

### 接入新 agent 的步骤

1. 新建 `Sources/AgentMasterBridge/XxxAgent.swift`，实现上面"每个 agent 只写这些"里的内容。hook payload 如果不是
   Claude 的形状，同一个文件里再写一个 `XxxHookDialect`。
2. 加进 `AgentRegistry.all`。
3. 测试照 `CodexAgentTests` 写：参数、设置项、`hookArguments`、dialect。录一段真实的 hook payload 放进
   `Tests/AgentMasterBridgeTests/Fixtures/`，用 `Fixtures.translate(_:dialect:)` 验证。
   最少要实现哪些，可以参考 `AgentLaunchTests` 里的 `MinimalAgent`。

## 后果

- Claude 和 Codex 的启动参数不变：单元测试的期望值没改；打包后用 `ps` 对比重构前后的实际参数，除了恢复用的会话 id 以外完全一致。
- 以后接 Kiro 预计只需要一个文件：用 `HookPlan.writeSessionFile` 之外的方式把 agent 配置写到 `<项目>/.kiro/agents/`
  （Kiro 只从那里或 `~/.kiro/agents` 读配置），再写一个 dialect 做事件名和工具名的映射。
  Kiro 不上报 `transcript_path`，要支持恢复的话需要覆盖 `resumeId(from:)`。
- 协议的要求项比以前多，但除了 `id`、`displayName`、`executable`、`glyph`、`options` 和 `arguments` 以外都有默认实现。
