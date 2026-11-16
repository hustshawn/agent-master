# 0016 会话标题在第一轮后由 AI 起

- 日期：2026-11-16
- 状态：已接受（2026-11-16）
- 前置：ADR 0006（会话标题）、0011（Web 版）

## 背景

ADR 0006 定下会话标题取第一条提问的第一行。提问常常很长，开头一句不一定说到点子上，侧边栏里几个会话看着差不多。
Summarize 已经在后台用 `claude -p` 读 transcript 写报告，同样的办法可以给会话起一个短标题。

在 Bedrock 上的 Claude Code 实测：首个提问加 agent 的回复交给 haiku，起出的标题如"Agent Master 键盘监听修复"
"Fix flaky SessionManagerTests"，跟着提问的语言走。`claude -p` 默认要先启动用户配置的 MCP server，一次约 16 秒；
加 `--strict-mcp-config`（不给 `--mcp-config`，也就不启动任何 MCP server）约 7–10 秒。`--bare` 也约 7 秒，但它不读
OAuth 登录，用订阅登录的人会失败，所以不用。

## 决策

- **时机和输入**：会话的第一轮结束（Stop）后起一次，用完整的首个提问（`SessionState.firstPromptText`，截到 2000 字）
  加 agent 最后的回复（截到 2000 字）。不读 transcript 文件，三个 agent、Mac 版和 Web 版都走同一条路。
- **模型和调用**：`SessionTitler` 跑 `claude -p --model haiku`，不开工具、不启动 MCP server、不保存会话，60 秒超时，在
  AgentMaster 的支持目录里运行（不读项目的 CLAUDE.md）。和 Summarize 共用这段调用；Summarize 也因此不再启动 MCP server。
  只取回答的第一行，去掉引号、标题符号和句末句号，最长 80 字。需要装 Claude Code，用哪个 agent 跑的会话都一样。
- **存成自定义名称**：起好的标题写进会话的自定义名称，于是和 ADR 0006 里的标题一样写进恢复记录、跨重启保留，用户改名
  直接覆盖。会话在这之前已经有名字（用户改过名，或是从恢复记录带回来的）就不起；标题还没回来时用户改了名，以用户的为准。
  每个会话只试一次，失败了不在后面的回合里重试。
- **开关**：General 里的 "AI session titles"，默认开。Mac 版存在 UserDefaults 的 `aiSessionTitles`；服务器存在
  `settings.json`，字段可选，旧文件照常解码；`PUT /api/general` 两个字段都改为可选，只改请求里给出的那个。

## 后果

- 新会话的第一轮结束后约 10 秒，标题从第一条提问换成 AI 起的标题。之前已经开着的会话，标题照旧。
- 每个新会话多一次 haiku 调用，并把首个提问和回复发给 Claude；关掉开关就回到第一条提问。
- 用户的 hooks 和全局 CLAUDE.md 仍会在这次 `claude -p` 里生效（不用 `--bare` 的代价）。
