# 0001 在 Settings 里设置新会话的默认权限模式

- 日期：2026-09-26
- 状态：已接受。0004 会把实现（`LaunchPreferences`）重构为按 agent 划分的设置，但行为不变。

## 背景

AgentMaster 启动 claude 时只传 `--settings`，因此新会话总是按 Claude Code 自己的配置（多数情况下是 manual/default）启动。
用户平时使用 bypass 模式。Shift+Tab 的切换循环只有在启动时带了 `--dangerously-skip-permissions` 或
`--allow-dangerously-skip-permissions` 时才包含 bypass，所以在 AgentMaster 里根本切不到 bypass。

当时考虑过的其他做法：
- 在项目里写 `.claude/settings.local.json`，设置 `permissions.defaultMode`。只对单个目录生效，而且会改动用户项目里的文件，只适合临时绕过。
- 在新建会话时临时选择模式，比如在 NSOpenPanel 里加一个下拉框。用户选择先记入 M3。

## 决策

- Settings 窗口（⌘,）里放一个「默认权限模式」下拉框：
  - 第一项是「跟随 Claude Code 设置」，不传参数，也是默认值。
  - 其余是 claude 接受的全部值：manual、acceptEdits、plan、auto、dontAsk、bypassPermissions。
  - 选定后启动时传 `--permission-mode <值>`。
- 复选框「允许在会话中切换到 bypass」，默认勾选，对应 `--allow-dangerously-skip-permissions`。默认模式是 bypass 时，这一项视为已开启，界面上显示为勾选且不可操作。
- 设置保存在 UserDefaults，只对之后新建的会话生效，已经在运行的会话继续用 Shift+Tab 切换。
- 实现为一个纯函数：给定偏好设置，生成启动参数。这个函数有单元测试。

## 后果

- 因为这个复选框默认勾选，所有新会话都能用 Shift+Tab 切到 bypass。这是用户的明确选择（团队内部工具）。
- 用了 `--permission-mode` 以后，页头显示的模式来自 hook 事件里的 `permission_mode`，与启动参数一致。
- 新建会话时临时选择模式的功能仍留在 M3。
