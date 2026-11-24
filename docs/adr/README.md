# 架构决策记录（ADR）

每条记录一个决策，格式：背景 / 决策 / 后果。状态取值：提议中、已接受、已被取代（注明被哪条取代）。
新决策按编号顺序追加；已接受的记录不改写，改变主意时新写一条并把旧的标为已被取代。

| 编号 | 标题 | 状态 |
|---|---|---|
| [0001](0001-default-permission-mode-in-settings.md) | 在 Settings 里设置新会话的默认权限模式 | 已接受；实现已由 0004 重构（LaunchPreferences → ClaudeCodeAgent） |
| [0002](0002-new-session-without-folder-picker.md) | 新建会话不必经过文件夹选择窗口 | 已接受 |
| [0003](0003-closing-sessions.md) | 关闭会话的行为 | 已接受 |
| [0004](0004-agent-abstraction.md) | 预留 Agent 抽象，设置按 agent 划分 | 已接受；协议由 0010 扩展为适配层 |
| [0005](0005-restore-sessions-on-launch.md) | 启动时恢复上次的会话 | 已接受 |
| [0006](0006-sidebar-groups-and-session-titles.md) | 侧边栏项目分组与会话标题 | 已接受；默认标题由 0016 改为第一轮后 AI 起的标题 |
| [0007](0007-collapsible-inspector-and-header-usage.md) | 右侧面板按需展开、可收起，USAGE 移到页头 | 已接受 |
| [0008](0008-app-icon.md) | App 图标：A 与 M 交织的几何字母组合 | 已接受 |
| [0009](0009-codex-agent.md) | 接入 Codex CLI 作为第二个 agent | 已接受；默认模型的选项由 0015 改为读 codex 的模型目录 |
| [0010](0010-agent-adapter.md) | Agent 适配层：每个 agent 只描述自己的差异 | 已接受 |
| [0011](0011-web-edition.md) | Web 版：agentmaster-server + 浏览器界面 | 已接受 |
| [0012](0012-kiro-agent.md) | 接入 Kiro CLI 作为第三个 agent | 已接受；默认模型的选项由 0015 改为读 kiro-cli 的模型列表 |
| [0013](0013-cross-device-control.md) | 跨端协作：聊天视图、远程审批和手机推送 | 已接受；审批由 0017 扩展到 Mac App 和会话策略 |
| [0014](0014-kiro-v3-engine.md) | 支持 Kiro CLI 的 V3 引擎 | 已接受 |
| [0015](0015-codex-model-list.md) | Codex 和 Kiro 的默认模型从 CLI 自己的模型列表里选 | 已接受 |
| [0016](0016-ai-session-titles.md) | 会话标题在第一轮后由 AI 起 | 已接受 |
| [0017](0017-approvals-policies-and-notifications.md) | 原生审批、会话策略与"需要你"通知 | 已接受 |
