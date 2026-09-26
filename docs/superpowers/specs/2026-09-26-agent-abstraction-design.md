# Agent 抽象（预留）设计文档

- 日期：2026-09-26
- 状态：已批准（2026-09-26）
- 决策记录：`docs/adr/0004-agent-abstraction.md`
- 前置：`2026-09-26-agent-master-design.md`（主 spec），ADR 0001–0003

## 1. 背景与目标

主 spec 假设底层只有 Claude Code。用户希望在 Settings 里为每个 agent 选择默认模型，
以后还可能用 AgentMaster 管理 Kiro CLI、Codex 等其他 agent。

本设计的目标是把"agent"抽象成一层，让设置按 agent 划分，并把 Claude 专用的启动逻辑从 AppModel 移到这一层之后；
以后接入新 agent 时只需新增一个实现，不用改界面或 AppModel。

### 1.1 范围

- 做：`AgentKind` 协议、声明式设置项 `AgentOption`、按 agent 存储的偏好设置、通用的 Settings 渲染。
  唯一实现是 `ClaudeCodeAgent`，包含新增的**默认模型**设置。
- 不做（另立项）：
  - Kiro CLI、Codex 等其他 agent 的实现。
  - 其他 agent 的事件、面板和审批适配。
  - 新建会话时选择 agent 的入口。
  - 按会话临时覆盖设置（M3 待办）。

### 1.2 成功标准

- Settings 里的 Claude Code 分组可以选择默认模型、默认权限模式、是否允许切换到 bypass。模型别名旁边显示实际解析出的 ID。
- 新会话的 claude 启动参数与设置一致（用 `ps` 核对），页头显示的模型与所选一致。
- `AppModel` 里不再出现 Claude 专用的类型：`ClaudeLocator`、`SessionSettingsBuilder`、`LaunchEnvironment`、`HookShim`。
- 现有行为不变：hook 注入、环境变量清理、ADR 0001–0003 的全部行为。

## 2. 类型

### 2.1 Core（纯数据，UI 可以依赖）

```swift
public struct AgentOption: Equatable, Sendable {
    public let id: String            // 同一个 agent 内唯一，例如 "model"
    public let title: String         // 界面上的标题
    public let kind: Kind
    public enum Kind: Equatable, Sendable {
        /// 一组可选值。"跟随 agent 自己的设置"由界面固定放在第一项，对应的值为空。
        /// allowsCustom 为 true 时还有一项「Custom…」，用户可以自由输入。
        case choice([AgentChoice], allowsCustom: Bool)
        case toggle(default: Bool)
    }
}

public struct AgentChoice: Equatable, Sendable {
    public let value: String         // 传给 agent 的值
    public let label: String         // 界面上显示的名称
    public let detail: String?       // 灰色小字，例如别名实际解析成的模型 ID
}

public struct AgentPreferences: Equatable, Sendable {
    public var values: [String: String]              // optionId → 值；缺失表示跟随或使用开关默认值
    public func string(_ id: String) -> String?      // 去掉首尾空白后为空则返回 nil
    public func bool(_ id: String, default: Bool) -> Bool
}
```

### 2.2 Bridge（行为）

```swift
public protocol AgentKind: Sendable {
    var id: String { get }           // 存储键里用到，一经发布不可修改，例如 "claude"
    var displayName: String { get }  // "Claude Code"
    func options(environment: [String: String]) -> [AgentOption]
    func launch(_ request: AgentLaunchRequest) throws -> AgentLaunch
}

public struct AgentLaunchRequest {
    public let sessionId: String
    public let preferences: AgentPreferences
    public let environment: [String: String]   // 登录 shell 的环境
    public let paths: AppPaths
}

public struct AgentLaunch: Equatable {
    public let executable: String
    public let args: [String]
    public let environment: [String: String]
}

public enum AgentRegistry {
    public static let all: [any AgentKind] = [ClaudeCodeAgent()]
    public static var defaultAgent: any AgentKind { all[0] }
    public static func agent(id: String) -> (any AgentKind)?
}

public struct AgentPreferenceStore {
    public init(defaults: UserDefaults)
    public static func key(agentId: String, optionId: String) -> String   // "agents.<agentId>.<optionId>"
    public func preferences(for agentId: String) -> AgentPreferences     // 读取该 agent 下所有已存的值
    public func set(_ value: String?, agentId: String, optionId: String) // nil 或空字符串会删除这个键
}
```

`launch` 可能抛出的错误：沿用现有的"找不到 claude"和"hook 辅助程序缺失"两种。这两个错误从 App target 的
`AppError` 移到 Bridge，新名字是 `AgentLaunchError`，提示文案不变。

### 2.3 ClaudeCodeAgent

**设置项**（顺序即界面顺序）：

| id | 标题 | 类型 | 选项 |
|---|---|---|---|
| `model` | Default model | choice，允许自定义 | `opus`、`sonnet`、`haiku`、`fable`。detail 取 `environment["ANTHROPIC_DEFAULT_<别名大写>_MODEL"]`，变量不存在时为 nil |
| `permissionMode` | Default permission mode | choice，不允许自定义 | `manual`（标签为 "manual (default)"）、`acceptEdits`、`plan`、`auto`、`dontAsk`、`bypassPermissions` |
| `allowBypass` | Allow switching to bypass permissions in a session | toggle，默认 true | — |

**`launch` 的步骤**：
1. 找 claude 可执行文件：`ClaudeLocator.locate(environment:)`。
2. 找 hook 辅助程序：`paths.hookExecutable()`。
3. 写每个会话的 settings：`paths.writeSettings(SessionSettingsBuilder(hookExecutable:).data(), sessionId:)`。
4. 生成环境变量：`LaunchEnvironment.sessionEnvironment(base:sessionId:socketPath:)`。
5. 生成启动参数，顺序固定：
   ```
   --settings <path>
   [--model <值>]                              model 有值时
   [--permission-mode <值>]                    permissionMode 是已知值时
   [--allow-dangerously-skip-permissions]      allowBypass 为真，或 permissionMode == bypassPermissions 时
   ```

参数生成单独做成一个纯函数 `ClaudeCodeAgent.arguments(settingsPath:preferences:) -> [String]`，方便测试。

## 3. 界面

Settings 窗口（⌘,）用 `Form(.grouped)`，每个 agent 一个 Section，Section 标题是 `displayName`。
Section 里的控件由通用视图 `AgentOptionsView(agent:options:store:)` 按 `AgentOption` 渲染：

- **choice**：一个 Picker，选项依次是：
  - `Follow <displayName> settings`（对应空值）
  - 分隔线
  - 各个 `AgentChoice`：显示 `label`；有 `detail` 时在后面用 secondary 样式显示 detail
  - 允许自定义时，最后一项是 `Custom…`
  - 选中 `Custom…`，或者存的值不在列表里时，Picker 下面出现一个 TextField，编辑后立即保存。
- **toggle**：一个 Toggle。Claude 专有规则：`permissionMode == bypassPermissions` 时，`allowBypass` 显示为开启且不可操作。
  这条规则用 `AgentOption` 表达不了，所以只作为 Claude 专用的一个小扩展点（`AgentKind` 的可选方法
  `isForcedOn(optionId:preferences:) -> Bool`，默认返回 false），不引入通用的依赖规则引擎。
- Form 底部固定一行说明："Applies to new sessions. Running sessions keep their settings."

**别名解析结果用的环境**：`AppModel` 暴露已经抓到的登录 shell 环境（`capturedEnvironment: [String: String]?`，
`@Observable`）。SettingsView 改为接收 `AppModel`；环境还没抓到时，`options(environment: [:])` 返回的 detail 都是 nil，
抓到后界面自动刷新。

**会话**：`SessionController` 增加 `agentId`。页头和 USAGE 继续显示 statusline 或 hook 上报的模型名，不需要改。

## 4. 数据流

```
Settings UI ──set──▶ AgentPreferenceStore（UserDefaults：agents.claude.model …）
                               │
New session ─▶ AppModel.startSession(in:)
                 agent = AgentRegistry.defaultAgent
                 prefs = store.preferences(for: agent.id)
                 launch = try agent.launch(.init(sessionId, prefs, environment, paths))
                 SessionController(id, agentId: agent.id, projectPath,
                                   TerminalLaunch(launch.executable, launch.args, launch.environment, cwd))
```

hook 服务器、`HookTranslator` 和路由都不改。不是 Claude 的会话收不到 hook 消息，面板保持为空。

## 5. 出错处理

| 情况 | 处理 |
|---|---|
| 偏好值为空或只有空白 | 按跟随处理，不传对应参数 |
| `permissionMode` 存了未知值 | 忽略，不传 `--permission-mode`，避免 claude 因参数非法而启动失败 |
| `model` 存了不在别名列表里的值 | 当作自定义值原样传出，界面显示为 Custom 并带出这个值 |
| 登录 shell 环境还没抓到或抓取失败 | detail 为 nil；启动时的环境处理与现在一致 |
| `launch` 抛出错误 | 用 `errorMessage` 展示，与现在一致 |
| 旧版本存的键 `defaultPermissionMode`、`allowBypassPermissions` | 不迁移，也不读取（只在开发机上用过） |

## 6. 代码改动

- 新增：`Sources/AgentMasterCore/AgentOption.swift`
- 新增：`Sources/AgentMasterBridge/AgentKind.swift`（协议、`AgentLaunchRequest`、`AgentLaunch`、`AgentLaunchError`、`AgentRegistry`）
- 新增：`Sources/AgentMasterBridge/AgentPreferenceStore.swift`
- 新增：`Sources/AgentMasterBridge/ClaudeCodeAgent.swift`
- 新增：`Sources/AgentMasterUI/AgentOptionsView.swift`
- 删除：`Sources/AgentMasterBridge/LaunchPreferences.swift` 和 `Tests/AgentMasterBridgeTests/LaunchPreferencesTests.swift`
- 修改：
  - `AppModel.swift`：`startSession` 改为走 agent；删除 `AppError`；暴露 `capturedEnvironment`。
  - `SessionController.swift`：增加 `agentId`。
  - `SettingsView.swift`：改为按 agent 渲染。
  - `AgentMasterApp.swift`：把 model 传给 SettingsView。

## 7. 测试

- `ClaudeCodeAgentTests`：
  - 参数：跟随时只有 `--settings`；传别名；传自定义值；只有空白的值按跟随；各种权限模式；未知模式被忽略；
    allowBypass 开和关；bypass 模式隐含 allowBypass 且不重复加参数；几种参数同时存在时顺序固定。
  - 选项：3 个设置项的 id 和顺序；在带 `ANTHROPIC_DEFAULT_OPUS_MODEL` 的环境里 opus 的 detail 等于该值；没有这个变量时为 nil。
  - `launch`：使用临时的 `AppPaths` 和一个假的 claude 可执行文件，检查写出的 settings.json、args、环境变量中的 `AGENTMASTER_SESSION_ID`；
    找不到 claude 时抛出 `claudeNotFound`。
- `AgentPreferenceStoreTests`：键名格式；不同 agent 互相隔离；`set(nil)` 和 `set("")` 删除键；读取时去掉空白。
- Core 测试：`AgentPreferences.string`（去掉空白、空值返回 nil）和 `bool`（缺失时返回默认值，能解析 "true"/"false"）。
- 手工验证：打包后打开 Settings 截图，确认分组、别名的 detail、Custom 输入框；新建会话后用 `ps` 核对参数，并确认页头显示的模型。

## 8. 启动时恢复会话

决策记录：`docs/adr/0005-restore-sessions-on-launch.md`。依赖第 2 节的 `AgentKind`，在 agent 抽象完成之后实现。

### 8.1 行为

- Settings 新增 **General** 分组，只有一个开关「Restore sessions on launch」，默认打开（键 `restoreSessionsOnLaunch`）。它不属于任何 agent。
- 恢复范围：上次退出或崩溃时，侧边栏中状态不是 ✓ 的会话。用 ⌘W 或 × 关闭的、`/exit` 结束的都不恢复。
- 启动时按原来的 `createdAt` 顺序逐个启动这些会话，并恢复原来的选中项。
  每个会话使用新的 AgentMaster 会话 id（也就是新的配置目录），再用 `resumeId` 接上原来的对话。
- 启动参数使用**当前**的 agent 设置，比如当前的默认模型和权限模式，而不是会话最初创建时的设置。
- 以下情况跳过：
  - 没有 `resumeId`：会话还没收到 `SessionStart` 就退出了。
  - 项目目录已经不存在。
  - 记录里的 agent 已不在 `AgentRegistry` 中，或者该 agent 不支持恢复。
- 恢复失败（比如转录已被删除）时，claude 报错退出，会话显示为 ✓，由用户手动关闭，不另做处理。

### 8.2 类型与协议改动

```swift
// Core：恢复记录里的一项
public struct OpenSessionRecord: Codable, Equatable, Sendable {
    public let agentId: String
    public let projectPath: String
    public let createdAt: Date
    public let resumeId: String
    public let selected: Bool
}

// Bridge
extension AgentKind {
    var supportsResume: Bool { get }            // Claude 为 true
    /// 从会话状态里取出恢复用的 id。Claude 取 SessionState.claudeSessionId；/clear 之后是新的 id。
    func resumeId(from state: SessionState) -> String?
}
public struct AgentLaunchRequest { …; public let resumeId: String? }   // Claude：追加 `--resume <id>`

public final class OpenSessionJournal {        // 读写 Application Support/AgentMaster/open-sessions.json
    public init(fileURL: URL)
    public func load() -> [OpenSessionRecord]  // 文件不存在或已损坏时返回 []
    public func save(_ records: [OpenSessionRecord])   // 原子写入；冻结后调用无效
    public func freeze()                       // 退出流程开始时调用
}
```

参数顺序：`--resume <id>` 追加在第 2.3 节列出的参数之后。

### 8.3 数据流

- **记录**：`AppModel` 在会话列表或选中项变化时，以及任一会话的 `status`、`claudeSessionId` 变化时，重新计算记录并调用 `journal.save`。
  - 只记录状态不是 `.ended`、`supportsResume` 为真、且 `resumeId` 不为 nil 的会话。
  - 为避免频繁写盘，内容与上次相同时跳过。
- **退出**：`applicationWillTerminate` 先调用 `journal.freeze()`，再 `shutdown()` 结束所有会话。
  这样 SIGTERM 让会话变成 ✓ 之后，不会覆盖掉记录。
- **启动**：`AppModel.init` 完成 hook 服务器准备、并等到登录 shell 环境抓取结束后，
  如果开关打开，就 `load()`，按第 8.1 节的跳过规则过滤，然后逐个调用 `startSession(in:agent:resumeId:)`，最后恢复选中项。
  开关关闭时不读取记录，但仍然照常写入。这样关闭后再打开，也能恢复最近一次的状态。

### 8.4 出错处理

| 情况 | 处理 |
|---|---|
| `open-sessions.json` 不存在或无法解析 | 当作空列表，不报错；下次保存时覆盖 |
| 某个会话恢复时 `launch` 抛出错误 | 跳过这个会话，其余照常恢复；`errorMessage` 显示第一个错误 |
| app 崩溃 | 记录是实时写入的，下次启动照常恢复 |

### 8.5 测试

- `OpenSessionJournalTests`：保存后读出结果一致；文件损坏时返回 []；`freeze()` 之后 `save` 无效；原子写入（不会留下写了一半的文件）。
- `ClaudeCodeAgentTests`：有 `resumeId` 时参数末尾是 `--resume <id>`；`resumeId(from:)` 返回 `claudeSessionId`。
- 恢复计划做成纯函数 `RestorePlan.make(records:agents:directoryExists:) -> [OpenSessionRecord]`，分别测试每条跳过规则和排序。
- 手工验证：开两个会话并各发一句话，退出后重开，两个会话都恢复并能看到之前的对话；关掉 General 开关后重开，不再恢复。

## 9. 以后接入新 agent 要做的事（仅作说明，本期不实现）

1. 新增一个 `XxxAgent: AgentKind`，写好设置项声明和 `launch`。
2. 加入 `AgentRegistry.all`。
3. 在新建会话的入口加上 agent 选择，也就是 ADR 0002 里的那些入口。
4. 事件和面板适配另外设计：hook 机制、Translator 或其他事件来源。
