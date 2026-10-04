# 0013 跨端协作：在 Web 版上加聊天视图、远程审批和手机推送

- 日期：2026-10-04
- 状态：已接受（2026-10-04）
- 前置：ADR 0010（agent 适配层）、0011（Web 版）
- 设计文档：`docs/superpowers/specs/2026-10-04-cross-device-design.md`

## 背景

用户想让 agent 在云主机上一直跑，电脑用浏览器深入干活，出门时用 iPhone 看进展、回答问题、审批、追加指令，并收到推送。
理想形态是 ChatGPT / Manus 那样的聊天界面，电脑和手机的体验、历史一致。

Web 版（ADR 0011）已经能在服务器上跑会话，但界面以终端为中心，审批和提问只能在终端里做，没有推送。
手机上看 TUI 体验差。

## 决策

- **不拆项目**：同一个仓库、同一个 `agentmaster-server`、同一次发版。聊天视图和 PWA 是 server 自带的 Web 资源，跟现有 Linux 包一起发。
  - 理由：执行引擎没变，hook、适配层、transcript 解析、PTY 都要复用。拆仓库的话，hook 协议要两边同步改。
  - 以后做原生 iOS App 时，在仓库里加独立目录，用单独的 tag 发版。
- **agent 照旧在 PTY 里跑 TUI，前端渲染成聊天**，不改成 headless（`claude -p --input-format stream-json`、Agent SDK）。
  - 对话的唯一来源是 transcript，用现有的 `Transcript.swift` 解析。同一个会话在电脑上随时能切回终端。
  - 代价：按消息更新，不逐字流式；斜杠命令菜单这类 TUI 交互在聊天里没法完整还原，需要时切到终端。
  - 如果实际用下来觉得不够，再考虑 headless，作为一种新的会话类型加进来。
- **任务就是会话**，不另加任务层。状态只分执行中 / 等待用户 / 一轮结束 / 已退出，“完成”由用户手动归档表达。
- **审批和提问一律交给 Web 和手机**：Claude Code 的 `PermissionRequest`、`AskUserQuestion` 不再立即回复 `nil`，而是存成待处理请求，哪一端先答算哪一端。
  - 580 秒左右没人回答（hook 的上限是 590 秒）就回 deny，让 agent 停下来等，请求标为已过期。不退回终端里等，因为那样手机就没法处理了。
  - 服务重启时等待中的请求全部过期，不重放。
  - 首版只做 Claude Code。Codex、Kiro 仍然在终端里审批。
- **指令继续写进 PTY**：带客户端生成的 ID 去重，只在 agent 空闲时接受，用 `UserPromptSubmit` hook 确认送达。中断就写 Esc。
- **推送用 PWA Web Push**，在服务端用 swift-crypto 实现 VAPID 和 RFC 8291 加密。触发事件有三种：等待用户、一轮结束、进程异常退出。
- **访问走 Tailscale**：服务端仍然只监听 `127.0.0.1`，`tailscale serve` 提供 HTTPS，登录仍然用现有 token。
  不经过 Coder 的 ALB，因为它只放行公司出口 IP，手机在外面连不上。
- **前端继续用纯 JS、不加构建步骤**，只多放一个 markdown 渲染库到 `Web/vendor/`。手机和电脑用同一套 `app.js`，窄屏时切换布局。

## 后果

- 电脑 Web 打开会话时默认显示聊天视图，终端改成可切换的视图。Web 版的重心从终端变成了聊天。
- 云端会话的审批同时出现在网页卡片和终端的原生对话框里（hook 等待期间 Claude 照样弹框），哪边先答算哪边。
- Mac App 不变。Mac App 本地开的会话手机上看不到，要跨端的任务需要在云端开。
- 数据目录新增 `push.json` 和 `vapid-key`。待处理请求只放在内存里，服务重启后不保留。
- ADR 0011 里“审批和提问还是在终端里处理”这一条，对 Claude Code 不再适用。
