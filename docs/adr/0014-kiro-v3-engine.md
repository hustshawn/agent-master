# 0014 支持 Kiro CLI 的 V3 引擎

- 日期：2026-11-01
- 状态：已接受（2026-11-01）
- 前置：ADR 0012（Kiro）、0013（跨端协作）

## 背景

kiro-cli 2.30 起会问用户要不要切到 V3 引擎，选了就把 `chat.agentEngine` 存成 `v3`，之后 `kiro-cli chat` 都用 V3；
CLI 3.0 会把 V3 作为默认。ADR 0012 记过"v3 引擎下 hook 不生效"，那时 V3 还要用 `--v3` 才会启动。用户反馈 v0.6.3 在
V3 下侧边栏一直停在 starting / Needs you，终端里对话却正常。这次在 kiro-cli 2.37 上实测（用临时的 `KIRO_HOME`，
不碰真的 `~/.kiro`）：

- V3 不认 `KIRO_AGENT_CONFIG_DIR`，日志是 `hooks.reload.loaded {"read":0,"registered":0}`。
- V3 的 hook 只从三处读：`<配置目录>/hooks/*.json`、受信任项目的 `.kiro/hooks/*.json`、agent 配置里内联的 hooks。
  配置目录是 `KIRO_HOME`，没设就是 `~/.kiro`。`KIRO_HOME` 替换的是整个 `~/.kiro`（agents、设置、会话、工作区信任都在里面），
  不能按会话设。没有别的变量或参数能多加一个 hooks 目录。
- V2 不读 hooks 文件夹：同一个文件放着，V2 会话不会多收一遍事件。
- hooks 文件是 `{"version": "v1", "hooks": [...]}`，每项有 `name`、`trigger`（就是 Claude 的事件名）和
  `action: {"type": "command", "command": ...}`。Kiro 用 `sh` 执行命令，会话的环境变量能传进去。工具类 hook 不写 matcher
  就对每个工具生效。
- 事件内容已经是 Claude 的形状：`session_id`（`sess_` 开头）、`hook_event_name`、`cwd`、`prompt`、`tool_name`、
  `tool_input`、`tool_response`。没有 `tool_use_id`，Stop 里没有最后一条回复。
- SessionStart 要等第一条 prompt 才发；`--resume-id` 恢复的会话不发 SessionStart。SessionEnd 只在进程退出时发。
  还有任务和文件事件，没有"等用户批准"的事件。
- hook 里的工具名和参数：`read_file`（`path`）、`fs_write`（`path`、`text`）、`str_replace`（`path`、`oldStr`、`newStr`）、
  `fs_append`（`path`、`text`）、`execute_bash`（`command`、`description`）、`grep_search`（`query`）、`file_search`（`query`）、
  `delete_file`（`targetFile`）。
- 会话存在 `<配置目录>/sessions/<工作区真实路径 SHA-256 的前 16 位>/<session id>/messages.jsonl`，每行一个 `payload`：
  `user`、`assistant`（`operationType` 为 `Reasoning` 的是思考过程）、`tool_call`、`tool_result`，以及批准、轮次等记录。
- `kiro-cli chat --v2` / `--v3` 能在单次启动里盖过 `chat.agentEngine`；`KIRO_AGENT_ENGINE` 环境变量不管用。
- V3 启动时会问是否信任工作区（2.33 起），底栏和 V2 的菜单一样是 `↑↓ to navigate`，服务端的 StartupMenuWatch 认得出。

## 决策

- **新增设置项 Agent engine**：跟随 Kiro（默认，不加参数）、V2、V3（分别加 `--v2`、`--v3`）。默认不加参数，老版本的
  kiro-cli 不会因为不认识这两个参数而启动失败。
- **两种 hook 一起注入**（"Show session activity in panels" 开着时）：
  - V2 照旧：会话目录里的 `kiro_default.json` 加 `KIRO_AGENT_CONFIG_DIR`。
  - 引擎不是 V2 时，确保 `<配置目录>/hooks/agentmaster.json` 存在，内容不对才重写。命令是
    `[ -z "$AGENTMASTER_KIRO_HOOK" ] || exec "$AGENTMASTER_KIRO_HOOK" hook`，每个会话把 `AGENTMASTER_KIRO_HOOK` 设成自己的
    hook 程序路径，Mac app 和服务端共用这一个文件。写不了就跳过，不挡会话启动。
  - 这是 AgentMaster 第一次往用户的全局配置里写东西，用户同意了；README 和设置项说明里写明了这个文件。
- **`KiroHookDialect`** 同时认 V2 的 camelCase 事件和 V3 的事件；V3 的 SessionStart 和 UserPromptSubmit 按 session id
  在 `sessions/*/` 下找对话记录，不自己算哈希；V3 的工具按上面的参数映射成 Read、Write、Edit、Bash、Grep、Glob，
  `fs_write`、`str_replace`、`fs_append` 照 Claude 的样子补 `tool_response`，CHANGES 就有内容。`delete_file` 保留原名。
  不订阅 SessionEnd，进程退出照旧结束会话。
- **`HookTranslator`**：一个会话的第一个 hook 如果不是 SessionStart，先补一个 SessionStart。只有 V3 恢复的会话会这样，
  Claude Code、Codex 和 Kiro V2 的第一个 hook 都是 SessionStart。
- **`TranscriptParser.kiroV3`** 读 `messages.jsonl`；`KiroAgent.transcript(at:)` 按文件名分辨 V2 和 V3。

## 后果

- V3 会话有状态、标题、正在运行的工具、CHANGES、web 的聊天视图和恢复，和 V2 一样。
- 和 Codex 一样，新的 V3 会话在第一条消息之前显示 starting，web 里第一条消息要在 Terminal 里发。
- `agentmaster.json` 不会被删掉。AgentMaster 之外的 V3 会话，每个事件多跑一个立刻退出的 `sh`。
- 找 V3 对话记录用的是 AgentMaster 进程自己的 `KIRO_HOME`：服务端是启动它的那个环境；Mac app 从 Finder 启动看不到
  shell 里的 `KIRO_HOME`，这时会去 `~/.kiro` 找，设了 `KIRO_HOME` 的人在 Mac app 里看不到 V3 的对话记录。
- V3 等用户批准时没有 hook，AgentMaster 不会显示 Needs you，和 V2 一样。
- ADR 0012 里"v3 引擎下 hook 不生效"那条由本 ADR 取代。
