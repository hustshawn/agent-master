# 架构决策记录（ADR）

每条记录一个决策，格式：背景 / 决策 / 后果。状态取值：提议中、已接受、已被取代（注明被哪条取代）。
新决策按编号顺序追加；已接受的记录不改写，改变主意时新写一条并把旧的标为已被取代。

| 编号 | 标题 | 状态 |
|---|---|---|
| [0001](0001-default-permission-mode-in-settings.md) | 在 Settings 里设置新会话的默认权限模式 | 已接受；实现将被 0004 重构 |
| [0002](0002-new-session-without-folder-picker.md) | 新建会话不必经过文件夹选择窗口 | 已接受 |
| [0003](0003-closing-sessions.md) | 关闭会话的行为 | 已接受 |
| [0004](0004-agent-abstraction.md) | 预留 Agent 抽象，设置按 agent 划分 | 已接受 |
| [0005](0005-restore-sessions-on-launch.md) | 启动时恢复上次的会话 | 已接受 |
