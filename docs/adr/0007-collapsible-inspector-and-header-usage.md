# 0007 右侧面板按需展开、可收起，USAGE 移到页头

- 日期：2026-09-27
- 状态：已接受（2026-09-27）。详细设计见 `docs/superpowers/specs/2026-09-27-sidebar-and-panel-design.md` §3

## 背景

右侧面板固定占大约四分之一的窗口宽度，但大多数时候：
- TODO 和 CHANGES 是空的。
- USAGE 单独占一整块。
- 面板里的内容不能交互。

用户希望把这块空间省出来。后续还要往面板里加子 agent 详情、基于 git 的 CHANGES 和待处理收件箱。

## 决策

- **定位为按需打开的审查面板，默认收起。** 看过示例以后，用户认为面板现有的内容（TODO、AGENTS 名字、只覆盖 Edit/Write 的 CHANGES）价值不高。面板的价值要靠后续的 git diff 审查、子 agent 结论和收件箱来建立，路线图顺序因此调整为 C → B → D。另一个方案是"去掉右侧面板"，没有采用，因为以后的审批收件箱还需要一个固定的位置。
- **不为新模型打开任务工具。** 这一版 Claude Code 只给老模型（claude-3 到 opus-4-7、sonnet-4-6、haiku-4-5）默认提供 TaskCreate/TodoWrite，已用 haiku 实测证实。用户选择跟随 Claude 的默认，不注入 `CLAUDE_CODE_ENABLE_TASKS`。
- **空区块折成一行**，显示为 `TITLE —`。只有 `main` 一行的 AGENTS 也算空。
- **面板可以整体收起**，收起后变成一条 28pt 宽的徽标细栏，徽标包括：未完成的 TODO 数、正在运行或已完成的子 agent 数、改动的文件数。
  - **切换方式**：⌘⌥0（View ▸ Toggle Inspector）或页头按钮。
  - **收起状态**：保存在 UserDefaults 的 `panelCollapsed`，默认收起，重启后保留。
  - 用户选择手动切换，没有选自动收起。原因是自动收起会在切换会话时让终端宽度跳动，TUI 也会跟着重新排版。
- **USAGE 移到页头右侧**，格式为 `模型 · 模式 · ctx N% · $X.XX`。ctx 达到 80% 或以上时显示为 warning 色；鼠标悬停时显示输入和输出的 token 数。面板里删掉 USAGE 区块。
- **页头左侧**增加会话标题：`AgentMaster ▸ 项目 ▸ 会话`。

## 后果

- 用量信息始终可见，不再依赖面板是否展开。
- 面板的空间留给后续的子 agent 详情、git CHANGES 和收件箱。
- 顺带完成 M5 待办中"页头缺少会话名"和"面板不可折叠"两项。页头的 effort 仍未显示。
