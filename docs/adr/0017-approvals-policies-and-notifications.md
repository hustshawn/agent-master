# 0017 原生审批、会话策略与"需要你"通知

- 日期：2026-11-24
- 状态：已接受（2026-11-24）
- 前置：ADR 0010（agent 适配层）、0011（Web 版）、0012（Kiro）、0013（跨端协作：远程审批和手机推送）

## 背景

和 Omnigent 对比后，有三件事值得做：在 AgentMaster 自己的界面里批准或拒绝，按会话的策略拦下有风险的调用，以及会话等人时通知用户。
Omnigent 用 tmux `send-keys` / `capture-pane` 从外面驱动 TUI，再加一套 ALLOW/ASK/DENY 的上下文策略。
AgentMaster 仍然只做真实 agent TUI 上面的一层薄壳，所以这几件事都建在已有的 hook 通道上。

代码里现在是这样的：

- `SessionSettingsBuilder.hookEvents` 注册了 11 个事件，`PreToolUse` 和 `PermissionRequest` 属于 `decisionEvents`，
  hook 超时 600 s，matcher 都是 `*`。Codex 经 `CodexAgent.hookArguments` 拿到同一份清单（`HookPlan.events`），
  Kiro 经 `KiroAgent.agentConfig` 拿到改名后的子集（`preToolUse` 等）。
- `HookShim.isDecision` 只把 `PermissionRequest` 和 `PreToolUse(AskUserQuestion)` 当成 `.request`：shim 会阻塞，
  最多等 590 s（`defaultDecisionTimeout`）。其他 `PreToolUse` 是 `.event`，发完就走。
  shim 连不上 socket、超时或回复的 id 不对时，什么都不打印，agent 就按自己的界面继续。这是"永不卡死 agent"的约定。
- `HookServer` 把 `.request` 的连接存进 `pending`，由 handler 回调 `reply`。`reply` 用 `removeValue` 取连接，
  所以第二次回复和 `stop()` 之后的回复都不起作用；`stop()` 关掉所有挂起的连接，shim 读不到回复，空输出退出。
- **Web 版已经有远程审批（ADR 0013）**：`SessionManager.open` 把 Claude 的 `PermissionRequest` 和 AskUserQuestion 存进
  `ActionRequestStore`（ServerKit），580 s 没人答就回 deny 并打断这一轮；`GET /api/requests`、`POST /api/requests/{id}`
  （`{"behavior":"allow"|"deny","message"?}` 或 `{"answers"}`）回答，`/api/events` 上的 `"request"` 事件广播开和关，先答者生效；
  `UserPromptSubmit`、`Stop`、`SessionEnd`、中断和关会话会让挂起的请求过期（回空输出）。网页上已有审批卡和提问卡，
  也已有 Web Push（VAPID + RFC 8291，`PushNotifier`），在请求等人、一轮结束、agent 自己退出时推送。
- 回复内容由 `AgentKind.hookOutput(for:decision:)` 按 agent 生成，决定用 Bridge 里的 `RemoteDecision`
  （allow / deny(message, interrupt) / answer）。只有 `ClaudeCodeAgent` 实现了它：`PermissionRequest` 回
  `hookSpecificOutput.decision.behavior`，AskUserQuestion 回 `permissionDecision: "allow"` 加 `updatedInput.answers`。
  Codex 和 Kiro 返回 nil，审批留在终端。
- **Mac App 里没有人在等**：`AppModel.init` 收到 `.request` 立刻 `reply(nil)`，注释是 "M3 replaces this…"。
- 花费来自 statusLine：`UsageParser` 读 `cost.total_cost_usd` 写进 `Usage.costUSD`，经 `SessionEvent.usageUpdated` 进 `SessionState.usage`。
  只有 Claude 有 statusLine（`AgentKind.reportsUsage`），Codex 和 Kiro 会话没有花费。
- Codex（本机 0.160.1，按 [Codex hooks 文档](https://learn.chatgpt.com/docs/hooks)）：`PreToolUse` 只认 `deny`，
  `permissionDecision: "ask"` 和不带 `updatedInput` 的 `allow` 会被记为 hook 失败，**然后照常执行这次调用**。
- Kiro 的 hook 只靠退出码 2 拦下 `preToolUse`；shim 永远退出 0（"永不打扰会话"），所以 AgentMaster 拦不下 Kiro 的调用。
- `ServerSettings` 把设置存在 `<data-dir>/settings.json`，用合成的 `Codable` 解码 `Stored`；新字段靠写成可选才能读旧文件，
  文件用 `.atomic` 写，没设权限。

## 决策

### 1. 审批卡和提问卡：Mac App 也有，挂起表两端共用

- `ActionRequestStore` 和 `ActionRequestJSON` 从 ServerKit 挪到 Bridge，Mac App 和服务端用同一个挂起表：
  先答者生效、到点自己回复、`expire` 回落、记最近 100 条结果。
- 请求的种类在 permission、question 之外加 **policy**（见 2），带上策略给的理由（`reason`）。
- **到点怎么回**由开表的一方定：服务端照 ADR 0013 回 deny 并打断（用户可能不在电脑前）；Mac App 回空输出，交回终端，
  因为用户就在这台电脑上，终端里的审批框还在。策略 ASK 的到点回复见下表，两端一样。
- **Mac App**：终端区底部的浮层。审批卡：允许、拒绝、在终端处理；提问卡：按 `questions` 渲染选项，点一个就答。
  "始终允许（写入 `permission_suggestions`）"和多选不进第一版。
- **Web 版**：沿用已有卡片和 `POST /api/requests/{id}`。`behavior` 多一个 `"terminal"`，只对 policy 卡有效，意思是"交给 agent 自己决定"。
- **Codex 和 Kiro 的 `PermissionRequest` 仍在终端里审批**（跟 0013 一样），要先录 0.160 的 fixture，见待定问题。

### 2. 策略层（ALLOW / ASK / DENY）

- **在哪里算**：在 App 和服务端的 HookServer handler 里，请求到达用户之前。规则和每个会话的状态放在 AgentMasterCore 里的
  `PolicyState` + `PolicyReducer`，和 `SessionState` reducer 一样是纯 Swift；Bridge 里的 `PolicyBook` 用一把锁按会话 id 存状态。
  handler 在 HookServer 的 accept 线程上被调用，策略在锁里同步算完，不经过主线程，免得拖慢后面事件的读取
  （`HookServer` 注释里的 1 s 读取上限和 300 ms 目标）。
- **合并规则**：每条规则返回 ALLOW / ASK / DENY 和理由。有一个 DENY 就是 DENY，否则有一个 ASK 就是 ASK，否则 ALLOW。
- **ALLOW 的意思是"AgentMaster 不反对"**，不是批准：`PreToolUse` 回空输出，让 agent 自己的权限规则决定。
  策略层永远不会把 agent 本来要问的事情自动批准。
- **必须用 `PreToolUse`**：`PermissionRequest` 只在 agent 本来要问时才触发，被 allow 规则、`acceptEdits`、`bypassPermissions`
  或 Codex `--ask-for-approval never` 放行的调用都看不到。所以三条规则都挂在 `PreToolUse` 上，
  `HookShim.isDecision` 改成所有 `PreToolUse` 都是 `.request`。代价是每次工具调用多一次 socket 往返；
  App 或服务端没开时 connect 立刻失败，shim 照常空输出；没有规则命中时 handler 当场回空输出。
  `PermissionRequest` 不过规则，因为 agent 已经在问了。AskUserQuestion 也不过规则。
- **只对能拦的 agent 生效**：由 `AgentKind.policyHookOutput(_:)` 给出回复，返回 nil 的 agent 不算策略。
  Claude 和 Codex 生效；Kiro 拦不下（见背景），Settings 里注明。
- **结果怎么回给 agent**（`PolicyReply`：allow / deny(理由) / handBack）：

  | 结果 | Claude `PreToolUse` | Codex `PreToolUse` |
  |---|---|---|
  | ALLOW | 空输出 | 空输出 |
  | DENY | `permissionDecision: "deny"` + 理由 | `permissionDecision: "deny"` + 理由 |
  | ASK，有人在卡片上点了允许 | `permissionDecision: "allow"` | 空输出（Codex 不接受不带 `updatedInput` 的 allow），之后 Codex 自己的审批照常 |
  | ASK，拒绝 | `"deny"` + 用户填的原因 | `"deny"` + 用户填的原因 |
  | ASK，选"在终端处理"、超时或过期 | `permissionDecision: "ask"`，交给 Claude 自己的审批框 | `"deny"`，理由写明"AgentMaster 里无人回应" |

  Codex 的 ASK 回落只能拒绝：它不支持 `"ask"`，空输出就等于放行。策略层判成 ASK 的调用（比如 `rm -rf`）没人确认就不该跑。
  因此 policy 请求过期（新提问、一轮结束、中断、关会话）时也回这一行，不回空输出。
- **超时**：shim 等 590 s，挂起表 580 s 到点自己按上表回复，记为 `timed out`，所以回落由 AgentMaster 决定，不会被 shim 的空输出变成放行。
  App 退出或服务端停止时 `HookServer.stop()` 关掉挂起的连接，shim 空输出。也就是说，**AgentMaster 没在运行时策略不生效**；
  策略是护栏，不是安全边界（Codex 文档也这样定位它的 hook）。
- **第一版只有三条内置规则**，没有插件系统，也不能写脚本：
  1. **花费预算**：`askAtUSD` 和 `denyAtUSD`。数据是该会话最近一次 statusLine 的 `cost.total_cost_usd`。
     花费第一次到 `askAtUSD` 时 ASK；用户允许后，这个会话不再因预算询问，直到 `denyAtUSD`，之后每次工具调用都 DENY。
     statusLine 的数字如果变小了（`/clear` 或恢复会话后计数可能从头开始），把之前的值累加进 `carriedCostUSD`，
     预算按整个 AgentMaster 会话算。statusLine 比工具调用晚一点，数字最多落后一轮，设置说明里写明。
     **没有花费数据的 agent**（`reportsUsage == false`，即 Codex 和 Kiro）这条规则返回 ALLOW，Settings 里注明，不会因为没有数据就拒绝。
  2. **危险 Bash 命令**：一组正则（不分大小写），匹配 `tool_name == "Bash"` 的 `tool_input.command`（Claude 和 Codex 都叫 `Bash`），
     命中就 ASK，没有记忆，每次都问。默认列表：`rm -rf`/`rm -fr`（含拆开写的参数）、`git push --force`/`-f`/`--force-with-lease`、
     `git reset --hard`、`git clean -fd`、`terraform apply|destroy`、`kubectl delete`、`DROP TABLE|DATABASE`、`mkfs`、`dd of=/dev/`、
     `chmod -R 777`、`curl … | sh`。用户可以增删；写错的正则跳过。正则匹配命令文本，`bash -c`、变量拼接都能绕过，设置里明说。
  3. **每个会话最多工具调用数**：`maxToolCalls`。每个过策略的 `PreToolUse` 计一次（AskUserQuestion 不算），跨轮次累计，会话关闭才清零。
     到上限时 ASK；用户允许后再放行 `maxToolCalls` 次。
- **状态**按 AgentMaster 会话 id 存在内存里，跟会话一起没。恢复会话时从零开始（见待定问题）。
- **设置**（`PolicySettings`，Codable，键名两端一致）：
  - Mac App：Settings 里加一个 Policies 页，整个对象以 JSON 存在 `UserDefaults` 的 `policies` 键下。
  - 服务端：`settings.json` 增加 `policies` 对象，例如
    `{"cost":{"askAtUSD":5,"denyAtUSD":20},"dangerousBash":{"enabled":true,"patterns":[…]},"maxToolCalls":null}`，
    `GET /api/agents` 返回、`PUT /api/policies` 整个替换，网页 Settings 有对应分区。
  - `ServerSettings.Stored` 改成手写的容错解码（每个字段 `decodeIfPresent`），并加一个"旧 settings.json 能读"的测试。
  - 默认：危险命令规则打开，预算和调用数关闭（没有合理的默认金额）。

### 3. 需要你时发通知

- **触发**沿用 0013 的 Web Push：请求等人（含 policy）、一轮结束、agent 自己退出。
- **Mac App**：`UNUserNotificationCenter`，在请求等人和一轮结束时发，App 在前台且选中该会话时不发。点通知把 App 拉到前面并选中会话。
  `UNUserNotificationCenter` 需要 bundle id，只在 `scripts/bundle.sh` 打出来的 .app 里启用，`swift run` 时跳过。通知上的允许/拒绝按钮不进第一版。
- **服务端 webhook**：`settings.json` 里 `notifications.webhooks` 是一个列表，每项有 `url` 和 `format`（`ntfy`、`telegram`、`json`），
  跟 Web Push 同时发。`ntfy` 把标题放在 `Title` 头、链接放在 `Click` 头、正文是 body；`telegram` POST `sendMessage`，
  URL 里自带 bot token，`chat_id` 写在 URL 的查询参数里；`json` 发 `{sessionId, kind, title, body, url}`。
  用 AsyncHTTPClient 发，5 s 超时，失败只记日志，不重试，不影响 hook 回复。
  - 链接是 `<publicURL>/#session=<id>`。服务端不知道自己在反向代理后面的地址，`notifications.publicURL` 写进 `settings.json`，没配就不带链接。
    **链接里不带 token**；前端 `hashchange` 认 `session=`，打开对应会话。
  - **webhook 的内容只有**：事件种类和会话名（例如 "Approval needed · Fix the tests"）。不放命令文本、`tool_input`、问题内容、
    `last_assistant_message` 和文件路径，因为 webhook 经过第三方，这些可能含密钥。Web Push 是端到端加密的，内容不变。
  - **密钥**：webhook URL（尤其 Telegram 的 bot token）算密钥。`settings.json` 写成权限 600；
    `GET /api/agents` 只返回打码后的 URL，`PUT /api/notifications` 里某项的 `url` 等于打码值时保留旧值。日志里不打 URL。
- Web Push 已有（0013），本 ADR 不改它。

### 备选方案

- **像 Omnigent 那样用 tmux 抓屏、发按键**：要解析每家 TUI 的审批框，版本一变就坏；还要把 agent 放进 tmux。hook 已经给了结构化的请求和回复。
- **Python 或插件式策略引擎**：要多带一个运行时，Linux 静态包也会变复杂，而第一版只有三条规则。等真有人要第四种规则再说。
- **Omnigent 式的 meta-harness**：违背 ADR 0010 的方向，harness 是各家 CLI 自己的，AgentMaster 只描述差异。
- **只用 `PermissionRequest`，不碰 `PreToolUse`**：开销最小，但在 allow 规则和 bypass 模式下看不到调用，危险命令和预算规则就没法做。
- **策略 ASK 一律回 `permissionDecision: "ask"`，让 agent 自己弹框，再由 `PermissionRequest` 出卡片**：Codex 不支持 "ask"，
  Claude 上会出现两张卡。第一版直接在 `PreToolUse` 上出卡。

## 后果

- 每次工具调用多一次本机 socket 往返，策略在锁里同步算完，远低于 300 ms 的 hook 延迟目标。
- policy 卡挂着时 Claude 的 TUI 里看不到审批框，只看终端的用户会觉得 agent 卡住了；所以卡片上一直有"在终端处理"。
- Codex 的策略 ASK 没人答会拒绝，跟 Claude 不一样，Settings 里写明。
- 预算规则只对 Claude 有用，而且数字最多落后一轮。Kiro 不受策略约束。
- AgentMaster 关着时没有策略、没有卡片、没有通知，agent 跟直接在终端里跑一样。
- `ServerSettings` 改成容错解码以后，以后加设置项也不会再把旧文件清空。
- ADR 0013 里"Mac App 不变"一条，审批部分由本 ADR 取代：Mac App 也出卡片。

### 待定问题

- Claude Code 在 `bypassPermissions` 模式下是否尊重 `PreToolUse` 的 `"ask"`；`"ask"` 之后是否还会触发 `PermissionRequest`。
- `/clear` 和 `--resume` 之后 `cost.total_cost_usd` 是否从零开始；恢复会话时预算状态要不要写进 `OpenSessionJournal`。
- Codex 0.160 的 `PermissionRequest` payload 要录一份 fixture，再决定 Codex 审批是否也出卡片、最低支持哪个版本。
- 提问卡在 `multiSelect` 时 `answers` 的格式（设计稿只验证了单选）。
- 通知的节流：Claude 自己弹框时的 `Notification(permission_prompt)` 去重、审批通知延迟 5 s、用户正在看这个会话时网页不推送
  （需要前端上报焦点）。第一版沿用 0013 的推送时机。
- Mac 通知要不要带允许/拒绝按钮；要不要做"始终允许"。

### 实现顺序

1. `PolicyReducer` 和 `PolicyState`（Core），单元测试覆盖：DENY > ASK > ALLOW 的合并；预算的一次询问、允许后不再问、到 deny 线拒绝、
   花费变小时累加；危险命令默认列表的命中和不命中（各给几条容易误判的命令）；调用数到上限询问、允许后再放行 N 次；没有花费数据时预算规则返回 ALLOW。
2. `PolicyReply` 和 `AgentKind.policyHookOutput`（Bridge）：Claude 和 Codex 每种结果的输出 JSON，Kiro 返回 nil；
   Claude 的已有输出对照 `permission-request.jsonl`、`ask-user-question.jsonl`。
3. `HookShim.isDecision` 改为所有 `PreToolUse`；更新 `HookShimTests` 里 `testOnlyAskUserQuestionPreToolUseIsADecision`。
4. 挂起表挪到 Bridge，加 policy 种类、按种类的到点回复和过期回复、`PolicyBook`；测试超时、过期和"先回复者生效"。
5. 服务端：PreToolUse 过策略、`behavior: "terminal"`、`PUT /api/policies`、容错解码、settings.json 权限 600；HTTP 测试用已有的假 claude 脚本走真实 PTY 和 socket。
6. 网页 policy 卡和 Settings 分区；`scripts/web-smoke.py` 加一段：用 Claude 跑一条命中危险命令规则的 `rm -rf` 到临时目录，
   在 `/api/events` 上等 policy 请求，先拒绝一次、确认文件还在，再允许一次、确认已删除；`scripts/web-ui-check.py` 检查卡片能显示和收起。
7. Mac App 浮层和 Policies 设置。
8. 通知：Mac 的 `UNUserNotificationCenter`，服务端 webhook（ntfy 的单元测试只校验请求的头和正文，不连外网）。Web Push 已由 0013 做完。
