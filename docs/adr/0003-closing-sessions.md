# 0003 关闭会话的行为

- 日期：2026-09-26
- 状态：已接受

## 背景

M1+M2 没有关闭会话的功能，spec 里也没有定义。会话只能靠 claude 自己退出（`/exit`），结束后那一行一直留在侧边栏。
⌘W 执行的是系统默认的关闭窗口：窗口没了，所有 claude 会话却还在后台运行。
另外，每个会话的配置目录 `sessions/<id>/` 从来没有清理过（这是 M3 待办之一）。

## 决策

- 入口有三个：
  - ⌘W：主窗口中有选中会话时，关闭该会话；没有会话，或者按键窗口不是主窗口（比如 Settings），则照常关闭窗口。
    判断是否为主窗口的依据是 SwiftUI 给 `Window(id: "main")` 设置的 `frameAutosaveName == "main"`。
  - 侧边栏行：鼠标悬停时显示的 `×`。
  - 侧边栏行的右键菜单：「Close Session」。
- 确认规则：
  - 状态为 ◈ 工作中或 ◆ 等待审批时，先弹 NSAlert 确认（`SessionStatus.needsCloseConfirmation`）。
  - 启动中、◇ 空闲、✓ 已结束时直接关闭。
  - 这是用户在三种方案中选定的：工作中才确认、总是确认、从不确认。
- 关闭时依次执行：
  1. 用 SwiftTerm 的 `terminate()` 给 claude 发 SIGTERM，并关闭 PTY。
  2. 从侧边栏移除这个会话。
  3. 选中相邻会话：优先同一分组里的下一个，其次上一个，否则选第一个剩余会话（`SessionGrouping.selectionAfterClosing`）。
  4. 立即删除 `sessions/<id>/`。claude 只在启动时读取 settings.json，所以进程收到信号之后就可以删。
- 已结束（✓）的会话仍然留在侧边栏，由用户手动关闭。
- 转录由 claude 自己保存，之后可以用 `claude --resume` 继续。

## 后果

- 顺带解决了 M3 待办里"配置目录从不清理"的问题，但只限于通过关闭操作结束的会话。app 退出时仍然不会清理。
- 退出 app 时有会话正在运行的确认（`applicationShouldTerminate`）仍然留在 M4。
- 需要观察：退出 app 后曾经残留一个 claude 自己的 `--bg-pty-host` 后台进程。关闭会话会不会留下同样的进程，要在验证时检查。
