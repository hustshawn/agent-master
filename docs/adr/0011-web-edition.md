# 0011 Web 版：agentmaster-server + 浏览器界面

- 日期：2026-09-29
- 状态：已接受（2026-09-29）
- 前置：ADR 0009（Codex）、0010（agent 适配层）

## 背景

用户希望把 AgentMaster 部署到一台远程服务器上，那台服务器已经装好了 Claude Code，用浏览器来管理会话。
要求是最终可用，同时不改变 macOS App 现有的逻辑。

按模块看，Core、Wire、`agentmaster-hook` 和 Bridge 只依赖 Foundation 和 POSIX，能复用；
TerminalKit（SwiftTerm 的 AppKit 视图）和 SwiftUI/AppKit 界面不能复用。

## 决策

- **同一个仓库，新增三个 target**，macOS App 的 target 不变：
  - `CPTY`：一个很小的 C 模块，用 `forkpty` 在新的伪终端里启动 agent。fork 之后到 exec 之前只做 async-signal-safe 的事，
    所以放在 C 里，不在 Swift 里 fork。
  - `AgentMasterServerKit`：服务端逻辑。`PTYProcess`（进程、滚动缓冲、多路订阅）、`ServerSession`、
    `SessionManager`（对应 App 里的 SessionController 和 AppModel），以及基于 Hummingbird 2 的 HTTP/WebSocket 接口。
    网页前端也放在这里，作为 SwiftPM 资源。
  - `agentmaster-server`：可执行程序入口。
- **复用 Bridge 的全部 agent 逻辑**：启动参数、hook 注入、HookServer、HookTranslator 和各家 dialect、恢复会话的日志。
  Claude 和 Codex 在 Web 版里的行为跟 App 一致，以后按 ADR 0010 接入的 agent 也自动支持。
- **会话属于服务端**：浏览器关掉了，agent 还在服务器上跑。每个会话保留 2 MB 终端输出，重新连接时先补发这些内容。
  服务端重启时，按 General 里的开关恢复会话，规则跟 App 一样。
- **接口**：REST 用于操作（agent 和设置、会话的增删改、最近项目、服务器上的目录浏览），WebSocket 用于推送
  （`/api/events` 推送会话状态，`/api/terminal` 传输终端字节流）。完整列表见 `WebServer.swift` 顶部的注释。
- **安全**：
  - 默认只监听 `127.0.0.1`，推荐通过 SSH 隧道访问，或者放在带 TLS 的反向代理后面。
  - 所有 `/api` 请求都要带 token，token 放在 `Authorization: Bearer` 头里。浏览器的 WebSocket 设置不了请求头，所以 WebSocket 放在 `?token=` 参数里。
  - token 默认随机生成，保存在数据目录的 `token` 文件里（权限 600）。启动时打印出来的链接用 `#token=` 带上 token。
    `#` 后面的部分不会发给服务器，也就不会出现在访问日志里。前端读到之后存进 localStorage，再把它从地址栏里去掉。
  - 用 constant-time 的方式比较 token。
- **和 App 互不干扰**：服务端有自己的数据目录（默认 `~/.agentmaster-server`），里面放 socket、每个会话的配置、恢复日志、`settings.json` 和 token。
  偏好设置写在 `settings.json` 里，不依赖 `UserDefaults` 能不能持久化（Linux 上靠不住）。
  App 和服务端可以同时在一台机器上运行。
- **支持 Linux**：`UnixSocket.swift`、`LaunchEnvironment.swift` 和 `agentmaster-hook` 里，平台相关的调用用 `#if` 分开。
  macOS 上走的还是原来的 `Darwin.*` 函数。Linux 上没有 `SO_NOSIGPIPE`，改为在服务端和 hook 进程里忽略 `SIGPIPE`。
- **前端**：纯 HTML/CSS/JS，不需要构建步骤。终端用 xterm.js 6，文件直接放进仓库，没有外网也能用。
  配色、侧边栏、状态符号、页头用量、右侧面板、新建会话窗口和 Settings 都照 App 的样子做。
  浏览器会占用 ⌘N，所以网页里用 Alt+N 新开一个同 agent 的会话，Alt+0 收起或展开面板。
- **顺带修复**：Codex 0.158 把 `apply_patch` 改成了一个单独的工具（有 PostToolUse，`command` 里是纯补丁文本）。
  `CodexHookDialect` 两种格式都支持，新格式只在 PostToolUse 时记录，也就是只记录已经成功应用的补丁。这个修复同样适用于 App。

## 后果

- 部署方式：
  - release workflow 用 `swift:6.2-noble` 镜像构建 x86_64 和 arm64 两个 Linux 包，都用 `--static-swift-stdlib`，所以服务器上不需要装 Swift。
    构建出来的包和 `install-server.sh` 一起挂到 Release 上。PR 也会跑一遍这两个构建和测试，只有打 tag 才会发布。
  - 在服务器上执行一条命令：`gh release download … -p install-server.sh -O - | bash`。
    脚本会识别架构，装到 `~/.local/share/agentmaster-server`，注册成 systemd 用户服务，并开启 linger，
    这样崩溃后会自动重启，退出登录后也会继续运行；没有 systemd 用户会话的环境退回用 `nohup`。
    重跑同一条命令就是升级，数据目录会保留。也支持 `--version`、`--from`、`--host`、`--port` 和 `--uninstall`。
  - 私有仓库需要鉴权：优先用 `gh`，没有的话用 `GITHUB_TOKEN` 调 GitHub API 下载。
  - 外部怎么访问（端口转发、负载均衡、TLS）由部署的人自己决定，不在本项目的范围内。
  - 也可以在目标机器上自己执行 `scripts/package-server.sh`，然后直接运行 `agentmaster-server`。
- 审批和提问还是在终端里处理，跟 App 现在一样（ROADMAP 第 3 项）。
- 只支持单用户：一个 token 对应一个服务端，服务端以启动它的系统用户身份运行 agent。
- 验证方式：
  - 服务端单元测试和 HTTP 测试（其中有一个替代 claude 的假脚本，走的是真实的 PTY 和 hook socket）
  - `scripts/web-smoke.py`：用真实的 Claude 和 Codex，只通过 API 来驱动
  - 用无头 Chromium 驱动完整的网页流程
  - 在 Linux 容器（swift:6.2-noble）里编译并跑测试
