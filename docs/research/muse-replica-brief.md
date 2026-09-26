# Muse 复刻调研简报（2026-09-26）

> 标注说明：**[已核实]** 表示读过官方文档、代码或二进制字符串，或经过实机抓取。**[第三方]** 表示只来自第三方仓库或逆向资料。**[待核实]** 表示事实核查没能确认，或者属于推测。事实核查判定错误（REFUTED）的说法已经删掉。

---

## 1. 一句话结论

**"Muse" 指的是 Meta Superintelligence Labs（MSL）出的两个产品，底层都是闭源的 Muse Spark 模型。**

| | **Muse（消费级个人 Agent）** | **Muse Code（终端编程 Agent）** |
|---|---|---|
| 发布时间 | 2026-09-08 发布；Connect 2026（9/23）上被称为 "centerpiece" | 2026-08-05 开始 beta，随 Muse Spark 1.2 一起发布 |
| 内部代号 | "Hatch" | "TBH"（crate 名 `tbh_*`） |
| 运行形态 | iOS、Android、muse.ai、WhatsApp；每个用户一台云端 Linux VM | 原生 CLI/TUI 二进制 `muse`，另有 `muse serve` 和 `muse exec` |
| 公开资料 | 只有官方设计博客和安全博客 | 官方文档很全；SDK 和 MSP 协议以 MIT 开源；二进制可以匿名下载 |
| 你本机的证据 | 无 | superpowers 6.4.1 的 `.muse-plugin/plugin.json` 适配的就是它 |

- 复刻资料基本都集中在 Muse Code 上：协议 schema、52 份 ndjson 一致性对话录制、工具集、配色都拿得到。
- 消费级 Muse 只能参考两篇博客里写的架构和设计原则。
- 下面以 Muse Code 为主线，消费级 Muse 单独成节。你要复刻的是哪一个，最好先定下来（见第 6 节）。
- 其他同名产品我这次没有核实，也都不是当下的热门 Agent：Microsoft Muse/WHAM、Google Muse、Sudowrite Muse。

---

## 2. 整体架构与技术栈

### 2.1 Muse Code

**语言与构建 [已核实，二进制字符串]**
- Rust 1.98.1，在 Meta 的 monorepo 里构建（路径 `fbcode/musecode/build/src/crates/…`）。

**crate 划分 [已核实，二进制字符串]**
- 会话与存储：`agent`、`session-server`、`session-view`、`session-view-serve`、`local-store`、`agent-fork`、`agent-run-driver`、`agent-peer`
- 界面与入口：`tui`、`cli`
- 模型与配置：`model`、`config`
- 扩展：`agent-mcp`、`plugins`、`plugin-manager`、`agent-hooks`、`agent-reminder`、`script`
- 安全：`sandbox`、`approval`、`agent-session-permissions`
- 其他：`goal`、`local-tracing`

**依赖库 [已核实，二进制字符串]**
- tokio、hyper/h2、reqwest、tokio-tungstenite、tracing、crossterm、sqlite、rmcp（MCP）
- 语法高亮用的是 TextMate scope。
- 字符串里完全没有 ratatui，所以 TUI 可能是直接在 crossterm 上自研的。这一点属于推测 **[待核实]**。
- 内嵌了 V8（`workflow-script-engine-v8`），用来跑 JS workflow 和实验性的 "code mode"（`code_exec`/`code_wait`，由 `MUSE_EXPERIMENTAL_CODE_MODE` 开关控制）。
- 文档说公开的 aarch64 macOS 版不带 V8，所以这个平台用不了 workflow。

**核心与界面分离 [已核实]**
- `muse serve` 提供 **Muse Session Protocol（MSP）**：JSON-RPC 2.0，走 stdio，按行分隔。
- 官方 TUI 正在迁移成一个 MSP 客户端。证据是 `MUSE_EXPERIMENTAL_TUI_MSP_CLIENT`、`msp_view_reducer` 这些字符串。
- 所以只要实现了 MSP，TUI、IDE、GUI 和 SDK 可以共用同一个后端。

**分发 [已核实]**
- 安装：`curl -fsSL https://dev.meta.ai/install.sh | sh`；Windows 用 `irm https://dev.meta.ai/install.ps1 | iex`。
- 安装的是一个 bash launcher（`~/.local/bin/muse`，`launcher_version="3"`），真正的二进制文件叫 `muse-bin-<version>`。
- 更新：每小时轮询一次 `https://api.meta.ai/muse-code/channels/muse-stable`（另有 `muse-canary`）。当前稳定版是 `1.4.0-R4161.1`，版本号格式为 `X.Y.Z-R<build>.<n>`。
- 安装包托管在 `lookaside.facebook.com`，manifest 里给了每个平台的 sha256。
- 包体大小：Linux x86 348MB、aarch64 308MB、macOS 317 到 343MB、Windows 434MB。
- 更新相关的环境变量：`MUSE_NO_AUTO_UPDATE`、`MUSE_SYNC_UPDATE`。

**模型后端 [已核实]**
- Meta Model API：
  - `https://api.meta.ai/v1` 提供 Responses 和 Chat Completions 两种接口。
  - `https://api.meta.ai` 提供兼容 Anthropic Messages 的接口。
- Muse Code 用的是 `/v1/responses`，走 SSE，带 `previous_response_id` 和 `prompt_cache_key`。
- 有第三方反馈，在 `/chat/completions` 上 prompt cache 几乎命中不了 **[第三方]**。
- 模型：`muse-spark-1.1`、`1.2`（文档写的默认值）、`1.3`，以及各自的 `-contributor` 变体。
- 上下文 1,048,576 tokens，输出上限 131,072 tokens。
- 价格：输入 $1.25 / 输出 $4.25 / 缓存 $0.15（每百万 tokens）。contributor 档是 $0.10 / $0.20，代价是允许 Meta 用你的数据训练。
- 开放权重的 **Muse Glimmer 30B** 可以本地跑。许可证我没核实 **[待核实]**。
- 二进制里有 `provider-anthropic`、`provider-openai`、`provider-openrouter` 这几个编译特性。公开版没编进 openrouter，还有一个测试用的 `echo` provider。
- Meta 网关的私有路径 [已核实，二进制字符串]：
  - `/muse-code/models`
  - `/muse-code/search`（服务端网页搜索）
  - `/muse-code/browser_open`
  - `/muse-code/key`
  - `/muse-code/feedback`
  - `/muse-code/telemetry/traces/muse`
- 请求头里带 `x-meta-ai-gateway-session-id` 和 `traceparent`。

**认证 [已核实]**
- OAuth device code 流程，对接 `auth.meta.com`：
  - `client_id=1031625952748946`
  - 端点 `/oidc/device/authorization/` 和 `/oidc/device/token/`
- 拿到身份后调用 `POST https://api.meta.ai/muse-code/key`，换回一把形如 `LLM|…` 的模型 key。
- 凭据存在 `~/.config/muse/auth.json`。
- 优先级：`META_API_KEY` 高于已存的 key，已存的 key 高于浏览器会话。

**遥测 [已核实，二进制字符串]**
- 按 OpenTelemetry 的 gen_ai 规范生成 span，通过 OTLP 导出。

### 2.2 消费级 Muse（Hatch）[已核实，安全博客]

**整体形态**
- 每个用户一台云端 Linux VM（"Muse Secure VM"），里面有浏览器、文件系统和终端。
- iOS、Android、Web 客户端通过安全通道直连这台 VM。

**容器内**
- `hatch` daemon（也就是 Agent harness）和工作区跑在 systemd-nspawn 容器里：
  - Debian rootfs
  - 容器内 root 映射到宿主机的非特权用户
  - seccomp 禁用了 io_uring
  - 没有 `CAP_SYS_PTRACE` 和 `CAP_NET_ADMIN`

**容器外（各自是独立的 systemd unit）**
- `hatch-safety`：各种分类器，包括 prompt 注入检测
- `privsep` 连接器 worker：按 cgroup 识别身份，每个 worker 有一份凭据白名单
- `hatch-authd`：凭据库，负责发放替身令牌
- **Sentinel**：一个独立的 Agent，是连接器动作和所有出网流量的唯一裁决者
- Postgres
- 推理代理和遥测代理

**进程间通信与出网**
- 所有 IPC 都走 Unix socket，用 `SO_PEERCRED` 加对端 ACL 做鉴权。
- 出网流量经过 veth、eBPF 和正向代理，由 Sentinel 做 L4 和 L7 两层检查外加 SSRF 检查，并在最后一刻把替身令牌换成真实凭据。Agent 自己永远看不到真实密钥。
- **Tainted egress**：用 eBPF 加自定义 LSM hook，给读过用户数据的进程打上"污染"标记。被污染的进程不再享受网络请求的自动放行。

---

## 3. Agent 核心实现（Muse Code）

### 3.1 主循环（事件溯源）[已核实：官方博客、第三方 0.2.1 fixture]

**会话日志**
- 会话就是一份只追加的 JSONL 事件日志，能精确重放，进程崩了也能恢复。
- 子 agent 有自己的日志：`subagent/<id>/session.jsonl`。

**记录信封**
```
{schema_version, id, stream{kind: session|run|task, id}, sequence, recorded_at(µs),
 record_type:"event", durability: durable|ephemeral, causation_id,
 payload_type, payload_schema_version, payload}
```

**一轮 run 的顺序**
1. `runtime.user_intent.accepted`，载荷是 `{model_messages, refill_blocks, wake_policy}`
2. `run.model.configured`，载荷是 `{base_instructions, toolset, run_context_messages, reminder_roster}`
3. `assistant_tool_calls_committed`
4. `tool_batch.effect.{started,terminal}`：每个批次带 `parallel_profile`，只读调用并行执行，写操作串行执行
5. `tool_result_batch_committed`
6. 再次调用模型，直到出现 `assistant_message_committed`，最后是 `terminal`

**其他机制**
- Task 有独立的生命周期：proposed → accepted → scheduled → side_effect_intent → started → status/output → completed / failed / rejected。
- 恢复时，被中断的副作用会记成 "unknown outcome"，并提示 agent 先检查真实状态再决定要不要重试 [已核实]。
- 模型调用失败最多重试 10 次。
- 上下文压力分三档：normal、warning、blocked。支持自动和手动 compaction，会触发 PreCompact 和 PostCompact 两个 hook，并在日志里写一条 compaction item。
- 忙碌时的输入处理：`turn/start` 带参数 `ifBusy = queue | steer | replace`；另外还有 `turn/steer`、`turn/interrupt`、`turn/unqueue` 可用。

**上下文注入（开发者角色的 block，按 order 排序）**

| block | order | 说明 |
|---|---|---|
| `workspace_identity` | 85 | 缓存类别 `stable_prefix` |
| `security_mode` | 96 | |
| `skills_catalog` | 200 | |
| `session_identity` | 240 | |
| `completion_tool_nudge` 等 | 736 | 延迟投递的提示 |

- 缓存类别一共三种：`stable_prefix`、`runtime_prefix`、`dynamic_turn`。
- provider 参数：`meta.instructions`（系统 prompt）、`meta.prompt_cache_key`（按会话固定）、`meta.session_id`、`meta.tool_namespace`、`meta.reasoning.effort`。

**系统 prompt [已核实，二进制字符串]**
- 开头是 "You are Muse Code, an agentic coding CLI … powered by Muse Spark … by Meta MSL"。
- 分为这几节：Communication、Truthfulness、Verification、Preciseness、Repository Work、Code Style、Final Answer。
- 大小有两个说法：约 25KB（二进制提取）和约 32KB（fixture）。可能是版本不同，没有核对清楚 **[待核实]**。

**发往模型的请求 [已核实，实机抓包]**
```
tools:[{type:"namespace", name:"muse", tools:[...]}]
reasoning:{effort:"high", summary:"auto"}
include:["reasoning.encrypted_content"]
store:false
prompt_cache_key:"tbh:main:<uuid>"
```
- 历史里的 assistant 消息带 `phase:"final_answer"`。

### 3.2 工具清单 [已核实：1.4.0 实机抓包 34 个，另有 0.2.1 fixture 和二进制字符串]

| 类别 | 工具 |
|---|---|
| 文件与搜索 | `read_file(path,offset,limit)`，输出形如 ``"Read text file `x`.\n1|..."``；`write_file(path,content)`；`edit_file(path,find,replace)`；`search(pattern,paths,glob,mode,output_mode…)`；`apply_patch`（只在二进制字符串里见过） |
| Shell | `bash`：`command` 和 `description` 必填，可选 `workdir`、`timeout_ms`、`yield_time_ms`、`tty`、`sandbox_permissions: use_default\|require_escalated`；`bash_input` 往运行中的 shell 写 stdin；`monitor` |
| 后台任务 | `work_list`、`work_status`、`work_stop` |
| Web | `web_search`、`web_fetch` |
| 记忆与技能 | `read_memory`、`add_memory`、`edit_memory`、`read_skill` |
| 计划与目标 | `write_todos`；`get_goal`、`create_goal`、`update_goal`；`report_progress(current_work,next_work,percent_complete)` |
| 定时 | `cron_create`、`cron_delete`、`cron_list` |
| 子 agent | `subagent_spawn(command_id, role, objective, task_name, subagent_type, worktree_isolation, output_schema)`；`subagent_status`、`subagent_send_message`、`subagent_wait`、`subagent_read_result`、`subagent_cancel` |
| 跨会话 | `list_peer_sessions`、`send_session_message` |
| 交互 | `request_user_input`、`snooze_reminder` |
| 编排 | `workflow(name, script\|scriptPath, args)`；实验性的 `code_exec`、`code_wait` |
| MCP | 命名规则为 `mcp__<server>__<tool>` |

**部分工具的参数结构**
- `request_user_input`：
  ```
  questions[]{id, header(≤12字符), question,
    options[2-3]{label, description, preview?},
    selection{mode: single|multiple}}
  ```
  可选 `auto_resolution_ms`（120000）。用户选中的 label 会直接作为工具输出。
- `write_todos`：`{todos:[{text, status: pending|in_progress|completed|cancelled}]}`。
  - 实机抓到的是 `in_progress`，但 MSP 里可能是 camelCase `inProgress` **[待核实]**。
- Goal 对象：`{objective, status, percentComplete, currentWork, nextWork}`。

**与 Claude Code 的对应关系（来自本机 superpowers 的 muse-tools.md）**

| Claude Code | Muse Code |
|---|---|
| Read / Write / Edit | `read_file` / `write_file` / `edit_file` |
| Bash | `bash` |
| Grep 和 Glob | `search` |
| WebFetch / WebSearch | `web_fetch` / `web_search` |
| TodoWrite | `write_todos` |
| Task | `subagent_spawn` |
| AskUserQuestion | `request_user_input` |
| Skill | `read_skill` |

### 3.3 规划与目标
- 规划主要靠三样东西：
  - `write_todos` 驱动 todo 面板
  - 内置技能 `/plan` 和 `/grill`，具体内容没有公开
  - Goal 模式
- **Goal 模式 [已核实]**：
  - 每轮结束后，运行时会自动排一个后续轮次。
  - 连续约 10 步没调用 `report_progress` 就会提醒 agent。
  - 宣布完成之前，必须逐条核对需求。
  - Esc 可以暂停 goal。
  - `goal_usage_attribution` 按 goal 统计 token 花费。

### 3.4 后台观察者 / Reminder Agent（最值得抄的设计）

**文档里的说法 [已核实]**
- 有 4 个常驻后台 observer：memory recall、skill recall、goal tracking、verification。
- observer 只提出建议，由 **reconciler** 决定这条建议是否注入下一轮。

**实现方式 [名字已在二进制中核实；各角色的 prompt 内容来自第三方 fixture]**
- 每个 observer 都是一个只读子 agent：
  - 模型与主 agent 相同
  - preset 为 `reminder-readonly`
  - 没有工具，只能调用 `submit_reminder_decision{decision: remind|none, advisory_text, confidence, priority}`
- 判定为 remind 时，宿主注入的是一条**固定的** continue-note，而不是 observer 自己写的文字。

**四个 reminder 角色**

| 角色 | 设置 | 判断内容 |
|---|---|---|
| `skill-reminder` | 非阻塞，effort 低，最多 2 步 | 是否该提醒主 agent 加载某个相关技能 |
| `goal-reminder` | 阻塞，effort 高，状态文案 "Finishing up"，在 agent 停下时触发 | 用户明确要的交付物是否都齐了 |
| `verify-reminder` | 阻塞，effort 高 | 可运行的产物在宣布完成前，是否真的用真实引擎或 headless 浏览器跑过 |
| `scope-reminder` | effort 中，在一轮中途运行 | 用户没要求的对外或提权操作（chmod、deploy、publish、merge、send）。这是文档 4 个 observer 之外的第 5 个 |

- `goal-reminder` 的判断细则：
  - 真正向用户提问算正常暂停。
  - 说"要我继续吗？"算拖延。
  - 验收条件、"最好的 X"这类最高级目标（至少要实测两个候选）、agent 自己点出的缺陷，都算没完成。
  - compaction 之后默认判 none。
- `verify-reminder` 有很多判 none 的情形，比如用户说了不用测、目测就能判断的视觉效果。

**插件 manifest 里 reminder 的字段**
- `id`、`path`、`decision`、`enabledDefault`、`enabledDefaultByModel`、`tools`
- `blocking`、`defaultPriority`、`maxPriority`、`maxChildSteps`、`maxInstallsPerRun`
- `reasoningEffort`、`intervalSteps`、`context`

**其他旁路模型调用 [已核实，实机抓包]**
- reminder 调用非常频繁，一个短会话里有 144 次。
- 空闲时有个"提示挑选器"，从约 20 个 tip id 里选一个，或者返回 NONE。
- Auto-review 模式下有一个审批裁判，输入是 `{"record":"approval_…"}`。

### 3.5 子 agent 与多 agent

**子 agent [已核实]**
- agent 树默认同时跑 8 个，由 `agents.execution_capacity` 配置，范围 1 到 64。未配置时，`ultra` 档默认用 64。
- 子 agent 可以再派生孙 agent。
- 每个子 agent 可以单独选择是否用 git worktree 隔离，目录在 `.muse/worktrees/`。选了隔离但失败时，不会悄悄退回共享工作区。
- 取消是协作式的，每次派生和控制动作都记日志。
- 返回结果的结构：`{summary ≤512字符, text ≤32KiB, artifactRefs, evidenceRefs, structuredData}`。
- MSP 控制方法：`subagent/{sendMessage, followupTask, interrupt, stop, close, reopen, resume, readResult}`。

**Workflow**
- 用 JS（V8）编写，最多 1,000 个子任务，同时活跃 16 个。
- 保存在 `.agents/workflows/*.js`，由 `/workflows` 控制室监控。
- 目前处于灰度发布。JS API 的细节没有抓到。

**会话间通信**
- 活着的会话之间可以互相交接任务、请求评审。

### 3.6 记忆与上下文 [已核实]

**项目指令查找**
- 从工作区一路往上找到 `.git` 边界为止。
- 每一层按顺序检查：`AGENTS.md` → `CLAUDE.md` → `.agents/AGENTS.md` → `.claude/CLAUDE.md`。

**记忆**
- `.agents/memory/MEMORY.md` 加上每个主题一个文件，最多注入 48 个路径。
- 通过 `read_memory`、`add_memory`、`edit_memory` 三个工具读写。

**迁移**
- `/migrate` 可以导入 Claude 和 Codex 的记忆以及 MCP 配置。

### 3.7 扩展机制

**Skills [已核实，基于 1.3.0 文档]**
- 格式是 `SKILL.md` 加 YAML front matter：
  - `description` 必填。
  - `name` 可选，默认取目录名。允许字符 `[A-Za-z0-9._:-]`，最长 128，不能以 `bundled:` 或 `plugin:` 开头。
  - 可选字段：`argument-hint`、`user-invocable`、`disable-model-invocation`、`metadata.short-description`。
  - `allowed-tools` 会记录但不强制执行。
  - Claude 独有的字段会保留为元数据，同时给出警告。
- 扫描顺序：
  1. `$CONFIG_DIR/skills`
  2. `~/.agents/skills`
  3. `~/.claude/skills`
  4. `$CODEX_HOME/skills`（没有则用 `~/.codex/skills`）
  5. `<proj>/.agents/skills`
  6. `<proj>/.codex/skills`
  7. `<proj>/.claude/skills`
  - 项目级技能只在受信任的工作区里加载。
- 投递方式：
  - 会话开始时只给模型一份目录（`{id, scope, path, description}`，不含正文），模型需要时用 `read_skill` 加载。
  - 用户输入 `/id args` 时，把正文发过去，参数空一行附在后面。
- 优先级：项目 > 用户 > 内置 > 插件。
- 上限：
  - `SKILL.md` 最大 256KiB，`read_skill` 最多返回 128KiB。
  - 目录预算 24,000 字节，超出时各行压缩成 short-description。
- 内置技能：plan、grill、taste、git、python-env、doctor、migrate、create-skill；threejs 作为内置插件提供。

**Hooks [已核实]**
- 文档列出 15 个事件：SessionStart、UserPromptSubmit、PreToolUse、PermissionRequest、PostToolUse、PostToolUseFailure、PreLLMCall、PostLLMCall、PreCompact、PostCompact、SubagentStart、SubagentStop、Notification（审批等待 6 秒后触发）、Stop、SessionEnd。
- `PostToolBatch` 和 `StopFailure` 只在二进制里出现过 **[待核实]**。
- 格式与 Claude 兼容：
  - stdin 传 JSON，exit code 2 表示阻断。
  - 输出放在 `hookSpecificOutput.{additionalContext, permissionDecision, updatedInput, decision}`。
  - muse-spark-1.3 要求用这种嵌套格式。
- 上限：stdin 256KiB，stdout 和 stderr 各 16KiB，默认超时 600 秒。
- hook 运行在沙箱之外。
- 环境变量会先清空，再注入 `MUSE_PLUGIN_ROOT`、`MUSE_PLUGIN_DATA_DIR`、`MUSE_PLUGIN_ID`、`MUSE_SESSION_ID`。
- 配置位置：`.muse/hooks.json`、settings.json 里的 hooks、`managed_hooks_path`。

**Plugins [已核实]**
- manifest 在 `.muse-plugin/plugin.json`，最大 128KiB：
  ```
  {schemaVersion:1, name, displayName, version, description,
   compat{source, manifestDir},
   capabilities{skills[{id,path}], commands[],
     hooks[{id, event, command[], timeoutMs}], mcpServers[], reminders[]}}
  ```
- 也能读 Claude 和 Codex 的插件格式；同时会设置 `CLAUDE_PLUGIN_ROOT` 以保持兼容。
- 信任模型：
  - skills 和 commands 装上就生效。
  - hooks、MCP、reminders 必须 `muse plugins approve`。批准绑定在具体的定义上，插件更新后要重新批准。
- 保留 id：`loop`、`muse-core`。
- 注意：安装时会拒绝符号链接形式的 `AGENTS.md`。

**MCP [已核实]**
- 配置写在 settings.json 的 `mcpServers` 或 `.mcp.json`。
- 传输方式：stdio（分帧可以是 auto、contentLength 或 lineDelimitedJson）和 streamableHttp。
- `mode`：`required` 表示连不上就中止；`optional` 表示可以跳过。
- `muse mcp login` 走 OAuth 2.1，支持动态客户端注册，用本地回环地址接收回调。

### 3.8 权限与沙箱 [已核实]

**权限档位**
- Read-only、Ask me、Auto-review（默认，由 LLM 裁判决定，失败时回退为询问用户）、Unrestricted（`--yolo`）。
- `--disable-approval` 只关审批，沙箱还开着。`--yolo` 同时关掉审批和沙箱，并且直接信任当前工作区。
- 另有 `--approval-mode on-request|untrusted|never`。

**Shell 审批**
- 复合命令会拆成多个 stage，逐个审批（界面上显示 "Stage 3 of 4"）。遇到第一个不能批准的 stage，整条命令就被拦下。
- 可选项：Allow once、Always allow in this workspace（保存为前缀规则）、Reject。
- deny 优先于 allow。python、bash、node 这类解释器前缀不能保存为宽泛的 allow 规则。

**MSP 层的审批模型**
- 审批主体类型：`shell`、`fileAccess`、`network`、`unixSocket`、`process`、`tool`。遇到未知类型一律拒绝。
- 流程：`approval/requested` → `approval/decide{approvalId, requirementId, choiceId}`（幂等）→ `approval/resolved`。以第一个持久化的决定为准。
- `ApprovalMode`：`allowAll`、`promptUnmatched`、`onRequest`、`denyUnmatched`。
- 授权作用域：`once`、`session`、`localPersistent`。
  - session 级的 shell 授权只匹配字节完全相同的命令。
  - 写授权不包含读授权。
- `resolvedBy`：`user`、`policy`、`llmJudge`。请求上还带 `judgeEscalated` 和 `protectedWrite` 两个标记。
- 审批记录永不过期，崩溃后仍然有效。
- 目录信任记在 `trust.json`。

**OS 沙箱**
- macOS 用 Seatbelt（`sandbox-exec`），规则从 `(deny default)` 起步。
- Linux 用自带的 bubblewrap 加 seccomp。
- Windows 用提权沙箱，第一次运行会弹一次 UAC；shell 用 PowerShell。
- 只有工作区和 tmp 可写。`.git`、`.muse`、`.agents` 始终只读。
- 网络：`--sandbox-network proxy-only`（默认，每个新目的地都要批准）、`restricted` 或 `enabled`。
- 如果确认不了沙箱已经生效，agent 会拒绝执行 shell。

### 3.9 配置目录

| 路径 | 内容 |
|---|---|
| `~/.config/muse/settings.json` | 必须包含 `"schema_version":1`；其他字段有 `endpoint_transport{base_url, auth}`、`model_catalog`、`skills`、`hooks`、`mcpServers`、`context` |
| `~/.config/muse/auth.json` | `{schema_version:1, providers{meta{api_key}}}` |
| `~/.config/muse/` 下其他文件 | `trust.json`、`machines.toml`、`skills/` |
| 会话日志 | `.../muse/sessions/YYYY/MM/DD/<uuidv7>/session.jsonl`，见下 |
| `~/.muse/` | 二进制字符串里出现过 `projects/`、`worktrees/`、`host-manager/sessions.json`、`lock.json`、`.musequarantine` |
| 项目目录 | `.muse/hooks.json`、`.mcp.json`、`.agents/skills/`、`.agents/memory/`、`.agents/workflows/` |

- 会话日志放在 `$XDG_DATA_HOME`（默认 `~/.local/share`）还是 `~/.muse`，有冲突说法，XDG 的可能性更大 **[待核实]**。
- 至少定时任务用了 SQLite 存储。

### 3.10 MSP 协议要点 [已核实，msp.d.ts]

**握手**
- `initialize` 返回 `serverInfo`、`museHome`、`platformOs`、`schema{version, fingerprint}`、`grantedCapabilities`、`sessionDurability`。
- 客户端随后发送 `initialized` 通知。

**方法**
- 会话：`session/{start, resume, fork, list, read, rename, compact, setModel, setReasoningEffort, setApprovalMode, userShell}`
- 轮次：`turn/{start, steer, interrupt, cancel, unqueue}`
- 审批与用户输入：`approval/{decide, listPending}`、`userInput/{answer, cancel, clarify}`
- 目标：`goal/{set, edit, pause, resume, clear}`
- 后台任务与 workflow：`task/{background, stop, stopAll}`、`workflow/{cancel, childControl}`
- 视图与输出：`view/{subscribe, unsubscribe, page}`、`item/readOutput`
- 其他：`model/list`、`skill/list`、`usage/read`

**通知**
- `item/{started, delta, updated, completed}`
- `turn/{started, completed, retracted, retryScheduled, unqueued}`
- `approval/{requested, updated, resolved}`、`userInput/{requested, settled}`
- `session/{statusChanged, todoListChanged, tokenUsage, contextUsage, goalChanged, modelChanged, …}`
- `view/gap`

**Item 模型**
- 类型：`userMessage`、`agentMessage`、`reasoning`、`toolCall`、`userShell`、`subagent`、`workflow`、`reminderChild`、`compaction`。
- 每个 item 带 UUIDv7 的 `itemId`；`revision` 高的覆盖低的；`status` 取值为 inProgress、completed、failed、cancelled、rejected、timedOut。
- toolCall 的字段：`tool`；`args`（模型原样输出的 JSON 字符串）；`visibleOutput`（通过 delta 字段 `"output"` 流式推送）；`outputRef`；`patchRef` 和 `patchSummary{files, added, removed}`。
- reasoning 摘要通过 delta 字段 `"summary.n"` 推送。
- 遇到未知 kind，用 `fallbackText` 渲染。

**其他**
- 每条命令都带一个 UUIDv7 `commandId` 作为幂等键。
- 输入分片类型：`text`、`image`、`skill`。
- reasoning effort 档位：none、minimal、low、medium、high（默认）、xhigh、max、ultra。`ultra` 是客户端模式，意思是最大 effort 加上激进地派发子 agent。
- 无头模式：`muse exec --json`，输出 JSONL。退出码：0 完成；1 失败或取消；2 用法错误；130 和 143 表示被信号终止。

---

## 4. UI 设计规范

### 4.1 Muse Code TUI

**抓取方式与可信度**
- 这些颜色是我在 Docker 里跑真实的 1.4.0 二进制、接一个 mock 后端、tmux 140×60 抓下来的 truecolor 数据，默认暗色主题 [已核实]。
- 字体就是终端等宽字体，靠粗体、dim、下划线（OSC8 链接）和颜色区分层级，很少用斜体。

**布局，自上而下**
1. **Header**：缩进两格，`Muse Code` 粗体 #ccd3db，后面跟 ` 1.4.0`。下方是通知，例如 `Model set to …`（#8a9098，值用 #8abeb7），子行用 `  ⎿  `（#676c74）。
2. **Transcript**：直接写进终端的滚动缓冲区，不用 alternate screen。cell 之间空一行。
3. **状态行**：只在一轮运行时出现。
4. **Plan/todo 面板**：紧贴在输入框上方。
5. **输入框**：上下各一条满宽的 dim `─` 分隔线（#676c74），提示符 `❯ ` 用 #5aa0ff。审批、提问、弹层、选择器都在这块区域里替换或向下扩展。
6. **子 agent 树**：
   ```
   main · ↓ to select
   └ • reviewer  shared · <objective>        0s · 1.6k
   ```
   `main` 粗体 #5aa0ff，`•` 用 #a6e3a1，耗时和 token 数右对齐。
7. **底栏**：`  Muse Spark 1.2 · high · /work/proj · Auto-review`。模型、effort、权限档位用 #5aa0ff，分隔符和 cwd 用 #8a9098。可以通过 `/hud` 配置。
8. **查看子 agent 线程时**：输入框分隔线变成强调蓝，并带上标签 `── Subagent · reviewer · read-only ──`。

**暗色默认配色 [已核实]**

| Token | Hex |
|---|---|
| text | #ccd3db |
| muted | #8a9098 |
| faint / 分隔线 / 提示 | #676c74 |
| accent | #5aa0ff |
| 用户消息底带 | #263854 |
| teal（行内代码、数字、进行中的 todo） | #8abeb7 |
| success | #a6e3a1 |
| error | #f38ba8 |
| warning | #ffe14a |
| diff 删除行 底色 / 符号 | #4a221d / #cc6666 |
| diff 新增行 底色 / 符号 | #213a2b / #b5bd68 |
| shimmer 渐变 | #676c74 → #767b83 → #9aa0a8 → #bdc4cc → #ccd3db |

- diff 新增行的语法高亮是 Catppuccin Mocha：keyword #cba6f7、文本 #cdd6f4、运算符 #94e2d5、标点 #9399b2、函数 #89b4fa、#fab387。删除行用的是去饱和的颜色。
- 代码块和 shell 接近 Tomorrow Night Eighties：keyword #8abeb7、函数或命令 #81a2be、标点 #7d7e7f、参数 #89a1b5、数字 #c397d8、标识符 #ffffff。
- 亮色主题（以 Catppuccin Latte 为基础）**[待核实]**：text #4c4f69、muted #6c6f85、faint #8c8fa1、分隔线 #acb0be、accent #1e66f5、用户底带 #ddf4ff、error #d20f39、success #40a02b、diff 底色 #ffebe9 和 #dafbe1。
- 内置主题有 17 个暗色、9 个亮色，包括 Catppuccin、Dracula、Tokyo Night、Nord、GitHub、Gruvbox、Rosé Pine 等。选择器带一个 `Terminal background: ‹ auto/light/dark ›` 开关和实时预览。
- 颜色深度按 truecolor → 256 色 → 16 色 → 无色 逐级降级。

**字形约定**

| 字形 | 含义 |
|---|---|
| `❯` | 提示符 / 用户消息 |
| `◆` | cell 的前导符号 |
| `◆ ◈ ◇` | spinner 循环帧 |
| `✓` / `✗` | 成功 / 失败 |
| `├ └` | 输出树 |
| `⎿` | 通知子行 |
| `› ⟩ >` | 选择光标 |
| `•` | 列表项 / agent |
| `[x]` `[ ]` | 多选 |
| `…` | 截断 |
| `▌` | 输入框光标 |
| `−`（U+2212） | diff 统计里的减号 |

**Cell 样式**
- **用户消息**：`❯ text`，铺满宽的 #263854 底带。
- **助手消息**：`◆ ` 粗体 #ccd3db，后接 GFM markdown。
  - 行内代码 #8abeb7。
  - 列表项 `  • `，用 #676c74。
  - 代码块缩进 4 格，没有围栏也没有底色，带语法高亮。
  - 表格用 box drawing 字符（#676c74），表头粗体。
  - 文件链接：`app.py` 用 #5aa0ff 加下划线，后面跟 ` (app.py:2)`（#676c74）。
- **轻量工具行**：不带 bullet，缩进 2 格，#8a9098。例如 `  Read app.py`、`  Searched "def " (1 match)`。
- **编辑**：`◆ Edited app.py (+1 −1)`。+N 用 #a6e3a1，−N 用 #f38ba8。下面是内联 unified diff，底色铺满整行：`  <行号> <符号><高亮代码>`。
- **Shell（折叠）**：`◆ Ran command · <description> · ✓ · 0.1s · ctrl+o`。
  - description 用 #5aa0ff。
  - 失败时 `◆` 变成 #f38ba8，并显示 `✗`。
- **Shell（ctrl+o 展开）**：
  ```
  ├ <命令>
  ├ exit 0
  └ <stdout>
  ```
- **正在运行的 shell**：`◈ Running command · <desc> — running (8s · esc to interrupt)`，尾部只保留约 4 行，并提示 `ctrl+b to send to background`。
- **其他 cell**：
  - `◆ Spawned subagent · reviewer`，结束时是 `◆ Finished · reviewer ✓`。
  - 警告：`  ! msg`。
  - `• Queued input`。
  - 用户 `!` shell：`◆ ! cmd · exit 1 · 46ms`。

**状态行与动效**
- 格式：`<glyph> <Label> (<Ns> · esc to interrupt)`。
- Label 有 Thinking、Calling tools、Running command · x、Double checking 等。
- glyph 在 `◆◈◇` 之间循环，大约每秒一帧。
- Label 上有一条 5 级亮度带从左往右扫（就是上面的 shimmer 渐变），秒数计时器同步递增。
- 文档提到但我没亲眼看到的：
  - max effort 时有金色激活动画，提示符和边栏也变成金色。
  - 状态行里显示一行 reasoning 摘要。mock 环境下没出现。

**Todo 面板**
```
  ✓ Read app.py            （✓ 用 #a6e3a1，文本 #8a9098）
  ◆ Fix add() operator     （◆ 用 #8abeb7，文本 #ccd3db）
  ◇ Run the script         （#8a9098）
```

**审批**
- 替换输入框里的内容：
  ```
  Would you like to run the following command?
    $ <高亮命令>
  › 1. Yes, proceed (y)
    2. No, and tell Muse Code what to do differently (esc)
  ```
- `/permissions` 是一个编号列表，当前档位标注 `(current)`。

**澄清问题**
- 一次最多 3 个问题，每个问题 2 到 3 个选项，再自动追加一项 `None of the above`。
- 分页显示 `1 of 2`。
- 多选时每行是 `[x]` / `[ ]`，末尾有 `Submit answer (2 checked)`。
- Tab 弹出 `Note (optional)`。
- 提交前有一个 Review 页，操作是 `> Submit answers` / `Interrupt turn`。
- 提问期间输入框的 `❯` 变暗。

**覆盖层**
- `/status`：55 列宽的框，标题 `MUSE CODE 1.4.0 / <形容词-moon 形式的会话名>`，右上角是绿色的 `COMPLETED`。键名是大写粗体，包括 MODEL、WORKSPACE、ACCESS、USAGE、CONTEXT、SESSION、ACTIVITY。
- 选择器（如 `/effort`）：
  ```
  Effort  |  Select …
    filter
  ⟩ high   current
    ↑↓ move · type to filter · enter confirm · esc go back
  ```
- `/settings`：可搜索、分组，分组有 Model、Appearance、Context、TUI、Input、Tools。
- `/keymap`：顶部是标签页。
- `?`：两栏快捷键速查。
- slash 面板：显示 7 行，底部提示 `↓ 42 more`。
- 首次运行会弹信任对话框，警告文字用 #ffe14a。
- rewind 选择器把条目标成 Exact、Review required、Blocked。

**快捷键**

| 按键 | 作用 |
|---|---|
| Enter | 提交；运行中则是插话（steer） |
| Shift+Enter | 换行 |
| Alt+Enter | 排到下一轮 |
| Esc | 中断；输入框为空时撤回已排队的消息 |
| Esc Esc | 打开 rewind |
| ctrl+o | 展开或折叠工具输出 |
| ctrl+b | 把命令转到后台 |
| ctrl+g | 用 $EDITOR 编辑 |
| ctrl+p / ctrl+n | 历史记录 |
| ctrl+c | 输入框为空时中断，否则清空输入 |
| ctrl+l | 清屏 |
| ctrl+v | 粘贴图片，显示为 `[Image #N]` |
| alt+v | 语音输入 |
| `@` | 文件路径 |
| `!` | shell |
| `/` | 命令面板 |
| `?` | 快捷键速查 |
| 在输入框按 ↓ | 进入子 agent 树 |

- `/workflows` 里：J/K 移动，C 取消，R 查看结果或重启，P 暂停，X 跳过。

**Slash 命令**
- 会话：`/new`、`/clear`、`/name`、`/resume [--last]`、`/fork`、`/rewind`、`/side`（别名 `/btw`）、`/compact`、`/recap`、`/export transcript|trajectory [--redacted]`、`/copy`
- 目标与定时：`/goal`、`/loop`（cron 任务 7 天后过期）
- 面板：`/tasks`、`/subagents`、`/stop`、`/workflows`、`/mcp`、`/plugins`、`/skills`、`/settings`、`/effort`、`/model(s)`、`/theme`、`/permissions`、`/hud`、`/keymap`、`/help`
- 内置技能：`/plan`、`/grill`、`/taste`、`/migrate`

### 4.2 消费级 Muse App [已核实，introducing.muse.ai 设计文章]

**交互结构**
- 一条长主线聊天，而不是一问一答。可以中途打断，也可以一次丢多个任务。大话题放到单独的 side chat 里。
- 用聊天气泡，因为会有 Agent 主动发来的、不在对话轮次里的消息。主动消息门槛很高，用户可以调节。
- 可定制头像：自己起名、选样式（作者的叫 "Veda"）。头像下面有一行实时的"正在做什么"。点头像打开活动日志和已授予的权限。
- Goals 页：分为 Tracking 和 Goals 两个区。
- Ideas 页：主动建议，格式是 "I can…" 加一段解释，配 3D emoji 风格的图标。
- Artifacts：富网页、追踪器、仪表盘，以卡片形式出现在聊天里。截图里用的是编辑风格的衬线排版。
- 关键环节用确定性 UI：结构化的 Allow/Deny 审批卡、安全的凭据输入框。审批卡由 Sentinel 直接推到客户端，不走聊天。授权可以是一次、会话、任务、限时或永久。

**视觉**
- 浅色、接近纯白的圆角面板，大号圆润的无衬线字体，浅灰色辅助文字。
- 胶囊形分段标签，圆形头像带铅笔编辑角标，蓝色主按钮。
- 吉祥物是毛毡或毛绒质感的 3D 形象。"Jolly" 这个名字出自 TechCrunch 转述的扎克伯格原话。

**设计 token（来自营销页 CSS，App 是否一致见下）**

| Token | 亮色 | 暗色 |
|---|---|---|
| accent | #0064d4 | #1793ff |
| 背景 | #fcfcfc | #181819 |
| 文本 | #111112 | |
| 次级文本 | #00040996 | |
| 分隔线 | #0000001a | |

- 胶囊圆角 999px，字体 "Optimistic"（Meta 自家字体）。
- 这些值只在营销页核实过，App 内是否相同 **[待核实]**。

---

## 5. 复刻方案建议

### 5.1 推荐技术栈

**模型**
- 直接用 Meta Model API 的 `/v1/responses`，接口是 OpenAI Responses 风格。
- 本地开发可以用 Muse Glimmer 30B 或任何兼容 Responses 的服务。
- 抽象一层 provider，把 Anthropic 和 OpenAI 也接上。

**核心：Rust + tokio**
- 最快的起点是 fork `xai-org/grok-build`（Apache-2.0，Rust TUI agent）。
- 也可以复用 `openai/codex` 的 codex-rs 组件：Seatbelt/bwrap 沙箱、apply-patch、ratatui TUI。
- `h1ddenpr0cess20/guac-build` 只是把 grok-build 的模型换成了 Muse Spark 1.1，并不是 Muse Code 的克隆，参考价值有限。

**协议**
- 自己实现一个兼容 MSP 的 JSON-RPC stdio server。
- 好处一：现成的 `@muse-code/sdk`、helicon、openmuse、各种 ACP 桥接可以直接连到你的核心上。
- 好处二：官方仓库里的 52 份 ndjson 录制可以直接当一致性测试。

**Shell 安全**
- 用 `tree-sitter-bash` 把命令切成 stage，配合前缀规则、LLM 裁判、沙箱（Seatbelt / bubblewrap）。

**TUI**
- Rust：ratatui 或直接用 crossterm，输入框用 `tui-textarea`，diff 用 `similar` 或 `imara-diff`，高亮用 `syntect`，markdown 用 `pulldown-cmark`。
- TS 方案：Ink 或 opentui，配 `diff` 和 shiki。

**GUI（可选）**
- 参考 helicon：Tauri 2、React、radix-ui、cmdk、motion、react-markdown/remark-gfm、sugar-high/shiki、use-stick-to-bottom、Phosphor 图标、Inter 和 JetBrains Mono 字体。

**扩展**
- MCP 用 `rmcp` 或 `@modelcontextprotocol/sdk`。
- 编辑器集成走 ACP。
- `SKILL.md` 和 hook JSON 保持 Claude 兼容，这样 superpowers 这类插件可以直接用。

### 5.2 可以直接参考的开源资料

| 仓库 | 用途 |
|---|---|
| `meta-models/muse-code-sdk`（MIT） | `msp.d.ts`、`msp.schema.json`、ndjson 录制、cookbook（stream-a-turn、approve-or-deny、queue-steer-reclaim、survive-the-host-dying 等） |
| `xhluca/session-migrate` | session.jsonl 的读写实现，以及格式文档 |
| `xhluca/muse-code-openrouter` | 把 Muse 接到任意后端的配置方法（`model_catalog` 格式） |
| `luckeyfaraday/muse-shim` | 展示 Responses 的 namespace 工具格式 |
| `RandyNorthrup/muse-spark-code` | 独立的 TS agent 循环，代码好读 |
| `HarjjotSinghh/helicon`、`EtienneLescot/muse-desktop`、`ibchouti9/openmuse` | GUI 客户端 |
| `BrokkAi/muse-acp`、`bex-co/muse-code-acp` | MSP 到 ACP 的桥接 |
| `wch887292/feihong-code` | 中文项目，自称"对标 Muse Code" |

**一个很实用的办法**：把真 `muse` 的 `endpoint_transport.base_url` 指向你自己的 mock 或日志代理（第 3 节配置里的 `"auth":"none"` 配置可用）。这样可以抓到完整的工具 schema 和旁路调用，拿你的实现跟官方行为逐项对比。

**避开这些仓库**：`muse-spark-app/muse-spark`、`*/Meta-Muse-Spark-1.3-Free`，疑似恶意软件。

**合规提醒**：从二进制或 fixture 里拿到的系统 prompt 和 reminder prompt 是 Meta 的内容。建议参考它的结构，自己重写，不要原样照搬。

### 5.3 MVP 优先级

**P0（能跑起来的编程 agent）**
1. 事件溯源的 JSONL 会话存储，用信封格式；把事件 fold 成状态，resume、fork、崩溃恢复就都有了。
2. 主循环：组装请求（系统 prompt、有序的上下文 block、工具集）→ Responses 流式输出 → 工具批次（读并行、写串行）→ 提交结果 → 循环。
3. 核心工具：`read_file`、`write_file`、`edit_file`、`search`、`bash`（`description` 必填）、`write_todos`、`request_user_input`。
4. 审批：按 stage 解析 shell，提供 once、session、workspace 前缀三种授权，默认拒绝未知类型。另加 OS 沙箱。
5. TUI：输入框、transcript cell（◆ 样式、可折叠的工具行、内联 diff）、带 shimmer 的状态行、todo 面板、审批和提问 UI，Enter/Alt+Enter/Esc 按上面的规则处理。

**P1（拉开差距的部分）**
6. Reminder sidecar：goal、verify、scope、skill 四个只读小调用，只输出 remind 或 none，命中时注入固定提示。成本低，质量提升大。
7. Skills（目录加 `read_skill`，有字节预算）、AGENTS.md/CLAUDE.md 分层加载、记忆文件和记忆工具。
8. 子 agent：并发上限、worktree 隔离、结果结构。
9. Hooks（Claude 兼容）、MCP、compaction。
10. MSP server 和 `exec --json` 无头模式。

**P2**
11. Goal 模式、cron/`/loop`、`/side`、`/rewind`、主题系统、Auto-review LLM 裁判、插件与审批锁定、JS workflow 引擎。
12. 如果还要做消费级 Muse：每用户一个 VM 或 nspawn、能替换凭据的出网代理、污染追踪、独立的策略 agent（Sentinel）、只看无障碍树的浏览器子 agent。

---

## 6. 信息缺口与待核实点（需要你亲自抓包或截图）

1. **先确认复刻目标**：是消费级 Muse（App，云端 VM）还是 Muse Code（终端编程 agent）。本报告偏向后者。
2. **完整的工具 JSON schema**：`/tmp/muse/tools.txt` 里是截断的。完整请求在 Docker 容器 `mt` 的 `/tmp/req_002.json` 里。也可以用 `MUSE_TRANSPORT_TRACE=1`，或者用 `--base-url` 指向日志代理重新抓。
3. **系统 prompt 的版本差异**：25KB 和 32KB 两个说法没有核对。`subagent_spawn` 和子 agent 的 prompt 也只抓到开头的 "Role: reviewer …"。
4. **没抓到的 TUI 画面**：
   - Ask me 档位下的编辑/diff 审批界面
   - 模型报错和重试的显示
   - `/tasks` 和 `/workflows` 控制室
   - max effort 的金色动画
   - 状态行里的 reasoning 摘要
   - 亮色主题的真实 hex
5. **会话日志的实际路径**：`~/.local/share/muse/sessions` 还是 `~/.muse/sessions`，装一次看看就知道。
6. **Hook 事件**：`PostToolBatch` 和 `StopFailure` 是否已经正式支持。
7. **Todo 状态的写法**：模型侧的 `in_progress` 和 MSP 侧的 `inProgress`。
8. **JS workflow 引擎的 API**：看 https://dev.meta.ai/docs/muse-code/workflows 。
9. **`/plan`、`/grill`、`/taste` 这几个内置技能的正文**：可以在二进制字符串里找，或者在会话中让 agent `read_skill` 出来。
10. **TUI 是不是直接在 crossterm 上自研的**：属于推测。
11. **Muse Code 与 Codex 设计上的继承关系**：属于推测。
12. **消费级 Muse**：
    - App 内的实际配色、字体、间距、圆角，以及每一屏的布局。只有营销页 CSS 和 7 张官方截图，需要你在真机上截图。
    - 定价档（Free 约 100M tokens/周，Power $20，Maximum $100）只有第三方来源。
13. **其他**：Muse Code 订阅档（Everyday、High、Power）的价格；Glimmer 30B 的许可证；`rome-os/rome` 到底是什么。

---

## 7. 参考来源

**官方**
- https://research.meta.ai/blog/introducing-muse-code-and-muse-spark-1-2
- https://dev.meta.ai/docs/muse-code （子页 interactive、configuration、permissions、extending、workflows、rewind、session-messaging、changelog）
- https://dev.meta.ai/docs/coding-agents 、 https://dev.meta.ai/docs/muse-glimmer
- https://github.com/meta-models/muse-code-sdk 、 https://meta-models.github.io/muse-code-sdk
- https://dev.meta.ai/install.sh 、 https://api.meta.ai/muse-launcher.sh 、 https://api.meta.ai/muse-code/channels/muse-stable
- https://about.fb.com/news/2026/09/introducing-muse-personal-ai-agent/
- https://introducing.muse.ai （设计文章）、 https://www.youtube.com/watch?v=wHn0hTjvFoo
- https://research.meta.ai/blog/security-and-safety-for-ai-agents-our-approach-with-muse （即 security.muse.ai）

**媒体**
- https://techcrunch.com/2026/08/05/meta-launches-muse-code-an-ai-agent-for-large-code-bases/
- https://techcrunch.com/2026/09/23/everything-new-coming-to-metas-ai-agent-muse/
- https://simonwillison.net/2026/Aug/5/muse-code-and-muse-spark-12/
- https://tech-insider.org/meta-muse-personal-ai-agent-launch-2026/ （定价，第三方）
- https://eu.36kr.com/en/p/3977498968144642

**社区**
- https://github.com/obra/superpowers/pull/2317
- https://github.com/xhluca/session-migrate 、 https://github.com/xhluca/muse-code-openrouter
- https://github.com/luckeyfaraday/muse-shim 、 https://github.com/BrokkAi/muse-acp 、 https://github.com/bex-co/muse-code-acp
- https://github.com/HarjjotSinghh/helicon 、 https://github.com/ibchouti9/openmuse 、 https://github.com/EtienneLescot/muse-desktop
- https://github.com/RandyNorthrup/muse-spark-code 、 https://github.com/wch887292/feihong-code
- https://github.com/xai-org/grok-build 、 https://github.com/openai/codex

**本地资料（`/tmp` 下的会被清理，重要的请先拷走）**
- 长期保存：
  - `/Users/shawn/Documents/workdir/muse-research/`：`sysprompt.txt`、`docs/*.txt`、`sdk/`、`install.sh`、`launcher.sh`、`m.json`
  - `/Users/shawn/.claude/plugins/cache/claude-plugins-official/superpowers/6.4.1/`：`.muse-plugin/plugin.json`、`skills/using-superpowers/references/muse-tools.md`、`hooks/session-start`
- 临时文件：
  - `/tmp/muse/`：`strings.txt`、`cap_*.ansi`、`cap_*.txt`、`an.py`、`mock.py`、`script.json`、`settings.json`、`tools.txt`、`system_prompt.txt`
  - `/tmp/muse_reminder_roster.json`
  - `/tmp/msp.d.ts`、`/tmp/mcsdk/`
  - `/tmp/xhluca_session-migrate/…/muse/0.2.1/…/session.jsonl`
  - `/tmp/museimg/`：消费级 App 的官方截图