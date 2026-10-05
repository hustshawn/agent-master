# 跨端协作：云端会话 + 聊天视图 + 手机 PWA 设计文档

- 日期：2026-10-04
- 状态：已批准（2026-10-04）
- 决策记录：`docs/adr/0013-cross-device-control.md`
- 前置：ADR 0010（agent 适配层）、ADR 0011（Web 版）
- 来源：用户和 Codex 整理的交接文档（`agent-master-cross-device-handoff.md`），以及 2026-10-04 的需求确认。交接文档里的“建议”以本文为准

## 1. 背景与目标

用户想让 agent 在云主机上一直跑，不依赖自己的电脑开着：

- 在电脑上用浏览器发指令、看进展、处理复杂的问题。
- 出门不带电脑时，在 iPhone 上看状态、回答问题、审批、追加指令。
- 需要处理的事情和一轮结束时收到推送。
- 电脑和手机的体验、历史一致，形态接近 ChatGPT / Manus 的聊天界面。

### 1.1 范围

做：
- 一台云主机（Coder workspace `jp-c8i-2`），单用户，多个会话并行。
- Claude Code 的审批和提问在 Web / 手机上回答（hook 真回复）。
- 往会话发指令带回执、可去重；能中断当前一轮。
- 聊天视图：从 transcript 渲染对话，工具调用折叠成步骤行。电脑和手机都以聊天视图为主，终端可切换。
- 手机布局：会话列表 + 会话详情，改动文件列表和单文件 diff，可以加到主屏幕（PWA）。
- Web Push：需要回答或审批、一轮结束、进程异常退出。
- 通过 Tailscale 访问，`tailscale serve` 提供 HTTPS。

不做（首版）：
- 自定义 harness、headless 执行（`claude -p --input-format stream-json`、Agent SDK）、多 agent 自动编排。
- 逐字流式输出（transcript 按条消息更新）。
- Manus 式“电脑面板”（浏览器画面、文件预览）。
- 接管不是 AgentMaster 启动的 CLI 进程。
- Mac App 连云端；Mac App 本地会话同步到手机。
- Codex、Kiro 的结构化审批。它们首版在聊天视图里能看、能发指令，审批仍在终端里做。
- 多用户、账号体系、git worktree 隔离、原生 iOS App。
- 整台云主机宕机的告警。

## 2. 术语

| 术语 | 含义 |
|---|---|
| 会话（Session） | 由 AgentMaster 启动、在服务端 PTY 里运行的一个 agent CLI 进程，及其 transcript。首版“任务”就等于会话，不另设任务层 |
| 会话状态 | 执行中 / 等待用户 / 一轮结束 / 已退出。“完成”由用户手动归档表达，系统不自动判定 |
| 聊天视图 | 根据 transcript 渲染的会话界面：用户消息、agent 回复、步骤行、待处理卡片、输入框 |
| 终端视图 | 现有 xterm.js 终端，直接显示 PTY 输出 |
| 步骤行 | 聊天视图里一次工具调用的单行摘要（如“编辑 Login.swift”“运行 swift test”），点开看输入输出；连续的步骤合成一组 |
| 待处理请求（ActionRequest） | agent 通过 hook 发出、等待用户的审批或提问。有唯一 ID、原始上下文、可选回答和状态 |
| 请求状态 | 等待中 / 已回答（谁、何时、答了什么）/ 已过期（超时、会话退出或服务重启） |
| 指令（Command） | 用户通过聊天输入框发给会话的一条消息，带客户端生成的唯一 ID |
| 回执 | 指令的进展：已接收（服务端记下）→ 已写入（写进 PTY）→ 已送达（`UserPromptSubmit` hook 确认 agent 收到）；或失败（附原因） |
| 设备订阅 | 一台设备的 Web Push 订阅（endpoint + 密钥），可单独删除 |

## 3. 总体设计

agent 的运行方式不变：AgentMaster 在 PTY 里启动交互式 CLI，hook 通过 Unix socket 上报。新增的部分都在 `agentmaster-server` 里，同一个仓库、同一个二进制、同一次发版。

```
iPhone PWA ─┐                       ┌─ PTY: claude (TUI) ── hooks ──┐
            ├─ HTTPS (tailscale) ─ agentmaster-server ──────────────┤
电脑浏览器 ─┘                       ├─ transcript JSONL（只读）       │
                                    ├─ requests.json / push.json     │
                                    └─ Web Push ──→ Apple Push 服务  ┘
```

- **对话的唯一来源是 transcript**。服务端用 `AgentMasterBridge/Transcript.swift` 解析，各端看到的是同一份。
- **审批和提问**：Claude Code 的 `PermissionRequest`、`PreToolUse(AskUserQuestion)` hook 已经阻塞等回复（`HookShim.isDecision`），回复通道 `HookServer.reply` 也已接好。现在 `SessionManager` 一律回 `nil`，改成保存为待处理请求，推给所有端，等用户回答再回复。
- **指令**：继续往 PTY 写文字和回车。只在会话处于“一轮结束 / 等待输入”时接受，用 `UserPromptSubmit` hook 确认送达。中断就往 PTY 写 Esc。

## 4. 各部分设计

### 4.1 待处理请求（阶段 1）

- 收到 `.request` 时：生成请求 ID，保存原始 hook 输入、所属会话，状态设为等待中，通过 `/api/events` 推给浏览器，触发推送。不再立即回复。
- 回答接口：`POST /api/requests/:id`，带 `{"behavior": "allow"|"deny", "message"?}` 或 `{"answers": {问题: 选项}}`。服务端检查请求还是等待中，再转成对应 agent 的 hook 输出调用 `reply`。第一个回答生效，之后的回答返回 409。
- 超时：`HookShim.defaultDecisionTimeout` 是 590 秒，服务端在 580 秒时主动回复 deny（审批带 `interrupt: true`），原因写“用户暂时不在，请停下来等待用户的下一条指示”，请求标为已过期。
- 这一轮结束（Stop）、用户在终端里提交了新 prompt（UserPromptSubmit）、中断、会话退出或关闭时，这个会话所有等待中的请求标为已过期，不重放。
- Claude Code 的输出格式（已按文档实现，并用 Claude Code 2.1.289 实测通过）：
  - `PermissionRequest`：`hookSpecificOutput.decision = {behavior: allow}` 或 `{behavior: deny, message, interrupt}`。
  - `AskUserQuestion`：`PreToolUse` 返回 `permissionDecision: allow`，`updatedInput` 原样带回 `questions`，加上 `answers`（问题文字 → 选中的选项）。拒绝时返回 `permissionDecision: deny` + `permissionDecisionReason`。
- 适配层新增 `AgentKind.hookOutput(for:decision:)`，返回 nil 表示这家 agent 只能在终端里答。Codex / Kiro 用默认实现，行为不变。
- 请求只放在内存里，不写文件：等它的 hook 是 agent 的子进程，服务重启后两边都不存在了。保留最近 100 条已处理的请求，用来显示结果。

### 4.2 指令与回执（阶段 1）

- `POST /api/sessions/:id/messages`，带 `{id, text}`，`id` 由客户端生成。同一个 `id` 再次提交时返回已有回执，不重复写入。
- 会话正在执行或在等审批时拒绝（409），界面提示“agent 正忙，可以先中断”。首版不做排队。
- 用 bracketed paste（`ESC[200~ … ESC[201~`）加回车写入，多行内容不会被提前提交（已实测）。
- 写入 PTY 后状态为“已写入”。下一次 `UserPromptSubmit` 的 prompt 包含指令文字就标为“已送达”。30 秒内没对上，标为“未确认”，不自动重发。
- `POST /api/sessions/:id/interrupt`：写 Esc，界面上写明是“中断当前一轮”，不是结束进程。实测 Claude Code 被中断时不触发任何 hook，所以服务端发完 Esc 后自己把这一轮记为结束。
- 回执在内存里保留到会话关闭，不跨重启。

### 4.3 聊天视图（阶段 2）

- 服务端提供 `GET /api/sessions/:id/chat?after=<条数>`，返回 `{start, total, items}`，前端把 `start` 之后的内容整体替换（还在等结果的工具行可能已经有了输出）。前端收到这个会话的 `session` 事件后再来拉增量。
- transcript 条目加了工具调用 ID，工具结果按 ID 配对，并行调用也不会对错。
- 渲染：用户消息、agent 文字（markdown，放一个 markdown 渲染库到 `Web/vendor/`）、步骤行（工具名 + 关键参数，点开看输入输出）、待处理卡片（审批的允许/拒绝按钮、提问的选项）、输入框和中断按钮。
- 电脑 Web 打开会话时默认显示聊天视图，页头可以切到终端视图，每个会话记住上次选的视图。
- Codex、Kiro 的 transcript 已经能解析，聊天视图同样能用。

### 4.4 手机布局与 PWA（阶段 3）

- 同一个 `app.js` / `app.css`，窄屏时分成两页：
  - **会话列表**：等待用户的会话排在最上面；每行显示标题、项目、状态、最近活动时间、agent 图标。可以新建会话（选项目、选 agent）。
  - **会话详情**：聊天视图、改动文件列表（复用现有 CHANGES），点开看单文件 diff，可以展开终端。
- 页头显示连接状态和数据更新时间，断线时明确标出“未连接”，不把旧状态当成实时的。
- PWA：manifest、图标、Service Worker（只缓存静态资源，接口不缓存）。
- 登录：继续用现有 token。设备在首次打开时用 `#token=` 链接登录（ADR 0011 的机制），token 存在 localStorage。

### 4.5 Web Push 与部署（阶段 4）

- 服务端生成 VAPID 密钥（`<data-dir>/vapid-key`，权限 600），实现 Web Push 加密（RFC 8291，aes128gcm）和 VAPID JWT（ES256），用 swift-crypto（Hummingbird 原本就间接依赖它）。加密已用 RFC 8291 附录 A 的测试向量验证。
- 接口：`GET /api/push/key`、`GET/POST/DELETE /api/push/subscriptions`、`POST /api/push/test`。订阅存在 `<data-dir>/push.json`，推送服务返回 404/410 时删除。设置里可以列出、删除设备，发送测试通知。
- 触发：待处理请求新建、会话一轮结束（`turnFinished`）、进程异常退出。同一个请求只推一次，一轮结束在短时间内合并。
- 通知内容：会话标题 + 原因（“等你审批：Bash `rm -rf build`”“一轮结束”“进程退出”），点击后打开对应会话，先拉最新状态，已经处理过的请求显示处理结果。
- 部署：`jp-c8i-2` 上用 `install-server.sh` 安装，监听 `127.0.0.1`，`tailscale serve` 转 HTTPS。iPhone 装 Tailscale，用 Safari 打开后加到主屏幕，再在页面里点按钮申请通知权限（iOS 16.4+ 的要求）。部署步骤写进 `docs/INSTALL-AGENT.md` 或 README。

## 5. 阶段与验收

每个阶段结束时都要能运行、有测试，并部署或在本机验证过。底层不支持的地方记录限制，不在界面上假装成功。

| 阶段 | 内容 | 验收 |
|---|---|---|
| 1 | 待处理请求 + 指令回执（4.1、4.2），现有 Web 界面加最简单的请求卡片和发送框 | 本机 server 跑 Claude Code：审批、AskUserQuestion 在网页上回答后 agent 继续；两个标签页同时回答只有一个生效；超时后 agent 收到 deny 并停下；同一个指令 ID 重复提交只写一次；服务重启后旧请求是已过期。状态转换、去重、超时有单元测试 |
| 2 | 聊天视图（4.3） | 电脑 Web 默认显示聊天视图，内容和终端一致；步骤行可以展开；待处理卡片可以操作；切到终端再切回来状态不丢；Codex 会话也能显示 |
| 3 | 手机布局 + PWA（4.4） | iPhone 尺寸下可以完成：看列表 → 进详情 → 回答请求 → 发指令 → 看 diff；能加到主屏幕；断网重连后显示最新状态 |
| 4 | Web Push + 部署到 jp-c8i-2（4.5） | Mac 合上、iPhone 锁屏时能收到三类通知；点击进入正确的会话；同一请求不重复推；订阅失效后会清理；记录 iPhone 系统版本、CLI 版本和已知限制 |

阶段 1 和 2 的服务端接口可以先定好，阶段 2 的前端和阶段 4 的 Web Push 加密可以并行做。

## 6. 关键场景

| 场景 | 预期 |
|---|---|
| 关掉电脑浏览器 | 云端会话继续跑，手机能看 |
| 电脑和手机同时回答同一个请求 | 只有第一个生效，另一端显示已处理 |
| 590 秒内没人回答 | agent 收到 deny 并停下，请求是已过期，可以发新指令接着做 |
| 网络重试导致重复提交指令 | 同一个 ID 只写一次 PTY |
| agent 正在执行时发指令 | 拒绝并提示可以中断 |
| 一轮结束 | 推送“一轮结束”，会话状态是一轮结束，不算完成 |
| 进程异常退出 | 推送，保留 transcript，可以恢复会话 |
| 服务重启 | 等待中的请求变成已过期，会话按现有规则恢复，不重放指令 |
| 推送丢失或延迟 | 会话列表里等待用户的会话照样排在最前 |

## 7. 实测结果与已知限制

2026-10-04 在 macOS 上用 Claude Code 2.1.289 实测（`agentmaster-server` 本地运行，通过 API 操作）：

- 通过：多行指令写入并确认送达；`AskUserQuestion` 远程回答，agent 按答案继续；Bash 审批允许 / 拒绝，拒绝原因 agent 能看到；第二个回答返回 409；审批超时后 Claude 被中断，会话回到空闲，命令没有执行。
- hook 等待期间，Claude 的 TUI 也会同时弹出原生审批框，所以在电脑终端里也能直接答。在终端里答完后，对应的请求要到这一轮结束才变成已过期。
- Claude 第一次进入一个文件夹时会弹“是否信任这个文件夹”，这个只能在终端里答，不走 hook。在手机上新建会话时，如果选的是没信任过的文件夹，需要打开终端视图确认一次。
- 用户直接在终端里按 Esc 中断，服务端收不到通知，状态会停在“执行中”，直到下一个 hook 到来。这是现有行为，没有改动。

2026-10-04 部署到 `jp-c8i-2`（Ubuntu 20.04，Swift 6.1.3），用 iPhone 真机验证：

- 通过：经 `tailscale serve` 的 HTTPS 打开、加到主屏幕、开启通知、收到测试推送。
- iOS 只给主屏幕 App 开 Web Push；在 Safari 标签页里设置页会提示先加到主屏幕。
- 主屏幕 App 不能用 `apple-mobile-web-app-status-bar-style: black-translucent`：这样 iOS 给网页的高度会比屏幕少一个状态栏，底部多出一条，输入框会被遮住。改用 `black`。这个设置在加到主屏幕时读取，改了以后要删掉图标重新添加。
- Linux 上推送改用 AsyncHTTPClient 发送：`URLSession` 在 Linux 上要链接 libcurl，安装包会多一个系统依赖。swift-crypto 的版本范围放宽到 3.x–5.x，让 Swift 6.1 也能编译。

仍待验证：

- transcript 写入的及时性：一条消息写完后多久出现在 JSONL 里。
- iPhone 弹出键盘时聊天输入框的表现。
