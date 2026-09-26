# 0005 启动时恢复上次的会话

- 日期：2026-09-26
- 状态：已接受（2026-09-26）。详细设计见 `docs/superpowers/specs/2026-09-26-agent-abstraction-design.md` 第 8 节。

## 背景

退出或重启 AgentMaster 会结束全部 claude 会话，重新打开后侧边栏是空的，要手动在终端里 `claude --resume`。
主 spec 把"恢复会话"放在 M4。用户希望现在就能在启动时自动恢复。

## 决策

- Settings 的 General 分组里有一个开关「Restore sessions on launch」，默认打开。
  另外两个选项是"启动时询问"和"恢复成占位、点击时才启动"，用户没有选。
- 恢复范围是退出或崩溃时还没结束的会话。用户主动关闭（ADR 0003）或 `/exit` 结束的会话不恢复。
- 记录写在 `open-sessions.json`，实时写入，所以崩溃之后也能恢复。退出时先冻结记录，再结束进程。
  否则 SIGTERM 会把所有会话标成已结束，记录就被清空了。
- 用 agent 自己的恢复机制（Claude 是 `--resume <session_id>`），并使用**当前**的 agent 设置。
- 恢复能力放在 `AgentKind` 上（`supportsResume`、`resumeId(from:)`），所以排在 ADR 0004 之后实现。

## 后果

- 启动时会同时拉起多个 claude 进程。会话多的时候启动会比较重，这是用户接受的取舍。
- 恢复出来的会话用的是新的 AgentMaster 会话 id，但侧边栏的顺序和选中项保持不变。
- 会话最初创建时用的模型和权限模式不会保留。如果以后需要按会话保留设置，再单独写一条决策。
- M4 里"恢复会话"这一项的一部分提前到了这里完成；历史会话浏览（TranscriptReader、⌘K）仍留在 M4。
