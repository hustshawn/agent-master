# 0004 预留 Agent 抽象，设置按 agent 划分

- 日期：2026-09-26
- 状态：已接受（2026-09-26）。详细设计见 `docs/superpowers/specs/2026-09-26-agent-abstraction-design.md`。

## 背景

用户希望在 Settings 里选择默认模型，而且模型要对应到具体的 agent。以后还可能用 AgentMaster 管理 Kiro CLI、Codex 等其他 agent。
现有 spec 从头到尾默认底层只有 Claude Code，而 0001 的 `LaunchPreferences` 也是专为 Claude 写的。
不同 agent 的模型参数、审批或权限参数、事件机制各不相同，没法共用一套设置。

## 决策

- 范围：**只预留抽象**。设置按 agent 划分，目前唯一的实现是 Claude Code；接入其他 agent，以及它们的事件和面板适配，另行立项。
  这是用户在三个选项中选定的：只预留抽象、先跑起来面板后补、每个 agent 都要完整面板。
- 方案 A：协议 + 声明式选项。另外两个方案是"每个 agent 一套完整实现"和"用户自定义命令模板"，未采用。
  - `AgentKind` 协议负责行为：`options(environment:)` 和 `launch(...) -> AgentLaunch`（可执行文件、启动参数、环境变量）。
  - `AgentOption` 和 `AgentChoice`（放在 Core）声明每个 agent 有哪些设置项；Settings 页用一个通用视图按声明渲染。
  - 偏好设置按 agent 存储，UserDefaults 键格式为 `agents.<agentId>.<optionId>`。
- 模型选项的来源：
  - agent 内置常用别名，Claude 是 opus、sonnet、haiku、fable。
  - 用登录 shell 的环境变量（`ANTHROPIC_DEFAULT_<别名>_MODEL`）显示每个别名实际解析成的 ID。
  - 另外提供「自定义…」和「跟随 agent 自己的设置」两项。
- `ClaudeCodeAgent` 收拢现在散在 AppModel 里的 Claude 专用启动逻辑：查找 claude、写 hook 设置、清理环境变量、生成参数。AppModel 不再依赖 Claude。
- hook 服务器和 `HookTranslator` 保持不变。不是 Claude 的会话收不到消息，面板就是空的。协议里不为其他 agent 猜测将来的事件接口。

## 后果

- 0001 的 `LaunchPreferences` 被取代并删除。旧的 UserDefaults 键不做迁移，因为只在开发机上用过。
- 每个会话要记录 `agentId`。新建会话的入口暂时不加 agent 选择，等出现第二个 agent 时再加。
- 接入新 agent 的工作量是：写一个 `AgentKind` 实现（选项声明加启动逻辑），界面不用改；事件适配另外算。
