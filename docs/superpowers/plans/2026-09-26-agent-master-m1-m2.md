# AgentMaster M1+M2 Implementation Plan (Plan 1 of 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS app that runs the original interactive Claude Code TUI in an embedded terminal with Muse colors (M1). Hook events stream into native TODO / AGENTS / CHANGES / USAGE panels in real time (M2).

**Architecture:** There is one SwiftPM package at the repo root, and its layers depend on each other in one direction:

- `AgentMasterCore` holds pure models, the `SessionState` reducer, and theme tokens.
- `AgentMasterWire` holds the NDJSON protocol, POSIX Unix sockets, the hook shim logic, and the session settings builder.
- `AgentMasterBridge` holds the translator from Claude Code hook JSON to `SessionEvent`, the HookServer, the launch environment, and path helpers.
- `TerminalKit` wraps SwiftTerm.
- `AgentMasterUI` holds the SwiftUI panels.
- Two executables sit on top: the `AgentMaster` app, and `agentmaster-hook`, the tiny CLI that Claude Code invokes as a hook and as its statusLine.

Every session launches `claude --settings <generated file>`. That file points every hook at `agentmaster-hook`, which forwards each hook JSON over `~/Library/Application Support/AgentMaster/agentmaster.sock`.

**Tech Stack:** Swift 5.10 (Xcode 15.4) with swift-tools-version 5.9, macOS 14+, SwiftUI with the Observation framework, SwiftTerm 1.18.0 (exact), and XCTest. Python 3 is used only for the manual end-to-end smoke script.

**Spec:** `docs/superpowers/specs/2026-09-26-agent-master-design.md`

**Scope:** This plan delivers M1 and M2 from spec §10. It does not include these:

- The native approval and question overlays (M3). In this plan, every decision request is answered "handle in terminal" immediately.
- Session history, `--resume`, and ⌘K (M4).
- Spinner animation, syntax-highlighted diffs, spinnerVerbs, and the settings page (M5).

The sidebar already lists several sessions, because the controller design supports that at no extra cost.

**Pre-verified (2026-09-26):** every Swift file in this plan was compiled with `swiftc` 5.9, including TerminalKit against SwiftTerm 1.18.0 and the full app target. Every test was run through a minimal XCTest stand-in: 91 tests, all passing, three runs in a row for the socket and server suites. `scripts/smoke.py` passed twice against real Claude Code 2.1.283. If a step fails for you, suspect a toolchain difference (Xcode 15.4 / Swift 5.10) before suspecting the logic, and fix it inline.

## Prerequisites (once, before Task 1)

- [ ] Xcode 15.4 is installed at `/Applications/Xcode.app`. Run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
- [ ] `xcodebuild -version` prints `Xcode 15.4`. `swift --version` prints `Swift version 5.10`.
- [ ] `ls ~/.local/bin/claude` exists. This is the real Claude Code binary. The `claude` on PATH may be the cmux wrapper.
- [ ] The real hook fixtures are already committed in `Tests/AgentMasterBridgeTests/Fixtures/`. They were recorded from Claude Code 2.1.283:
  - `basic-session.jsonl`
  - `ask-user-question.jsonl`
  - `permission-request.jsonl`
  - `session-tasks-edit-agent.jsonl`
  - `statusline.json`

## Global Constraints

- Platform: macOS 14.0 minimum (`platforms: [.macOS(.v14)]`). The manifest uses `// swift-tools-version:5.9`.
- The only third-party dependency is `.package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.18.0")`. It is the last SwiftTerm release with swift-tools 5.9.
- Claude Code is never forked or modified. AgentMaster only launches `claude --settings <file>` interactively. `-p` mode lacks AskUserQuestion and the Task tools.
- The hook shim must never hang Claude Code. It exits 0 with empty stdout whenever the socket is missing, the app does not answer, 590 s pass, or the input is malformed.
- The environment passed to `claude` removes these session markers:
  - `CLAUDECODE`
  - `CLAUDE_CODE_CHILD_SESSION`
  - `CLAUDE_CODE_SESSION_ID`
  - `CLAUDE_CODE_ENTRYPOINT`
  - `CLAUDE_CODE_EXECPATH`
  - `CLAUDE_CODE_MESSAGING_SOCKET`
  - `CLAUDE_CODE_MESSAGING_TOKEN`
  - `CLAUDE_CODE_SESSION_ATTENDED`
  - `CLAUDE_PID`
  - `CLAUDE_JOB_DIR`
  - `CLAUDE_EFFORT`
  - `TERM_PROGRAM`
  - `TERM_PROGRAM_VERSION`
  - every key with the prefix `CMUX_` or `AGENTMASTER_`
- The environment must keep `CLAUDE_CODE_USE_BEDROCK`, `ANTHROPIC_*`, `AWS_*`, and everything else. It is based on the user's login-shell environment.
- The socket lives at `~/Library/Application Support/AgentMaster/agentmaster.sock` with mode 0600, inside a 0700 directory. Per-session settings go to `~/Library/Application Support/AgentMaster/sessions/<uuid>/settings.json`.
- The wire protocol is NDJSON: one JSON object per `\n`-terminated line.
  - Messages look like `{"id","sessionId","kind":"event"|"request"|"statusline","payload"}`.
  - Replies look like `{"id","output"?}`.
- The Translator (`AgentMasterBridge/HookTranslator.swift` plus `ToolClassifier`, `PatchParser`, `UsageParser`) is the only code that knows Claude Code's JSON shapes. UI code depends only on `AgentMasterCore`.
- Theme tokens are copied verbatim from spec §4.6:

  | Token | Value |
  |---|---|
  | bg | #1e1e22 |
  | text | #ccd3db |
  | muted | #8a9098 |
  | faint | #676c74 |
  | accent | #5aa0ff |
  | selection | #263854 |
  | teal | #8abeb7 |
  | success | #a6e3a1 |
  | error | #f38ba8 |
  | warning | #ffe14a |
  | diffDelBg | #4a221d |
  | diffDelFg | #cc6666 |
  | diffAddBg | #213a2b |
  | diffAddFg | #b5bd68 |

- Font: SF Mono (`.system(design: .monospaced)` / `NSFont.monospacedSystemFont`), sizes 13 and 11 only. Corner radius 6. Lines are 1 px faint.
- Glyphs: `◆ ◈ ◇ ✓ ✗ ⎿ └ • ❯ ›`.
- The window defaults to 1440×900 with a hidden title bar and a dark color scheme.
- Swift 5 language mode. Do not enable strict concurrency. Never mutate a captured `var` inside a `DispatchQueue` closure; use the test `Box` class instead.

## Review Focus

1. **AgentMaster not running, or the socket file is stale or missing.** `claude` must behave exactly as in a plain terminal: every hook returns immediately with empty output, and the status line still renders. Pinned in Task 5 (connect refused → nil or fallback text) and Task 9 (a stale file at the socket path is replaced).
2. **The install path contains spaces or quotes.** `Application Support` and `Agent Master.app` are real examples. The hook command must still resolve. Pinned in Task 6: the generated command runs through `/bin/sh -c` from a directory named `am dir's …`.
3. **The login shell hangs or prints noise.** Examples are a slow `.zshrc` or a motd. The app must still start sessions within about 5 s, falling back to its own environment, and noise must never leak into the parsed variables. Pinned in Task 8 by a sleeping-shell timeout test and a noisy-shell parse test.
4. **`/clear` inside Claude Code.** Claude Code fires `SessionEnd(reason: clear)` and then `SessionStart` with a new session id in the same process. Panels must reset, and the session must not be marked ended. Pinned in Task 2 (the reducer resets on a new id) and Task 7 (the translator drops the clear SessionEnd and resets todos).
5. **Replies after the other side is gone.** Cases include a shim that timed out, the server stopping, or a reply arriving twice. There must be no crash, no SIGPIPE, and no write to a reused fd; pending shims must be released immediately when the server stops. Pinned in Task 4 (write after close throws `.closed`) and Task 9 (stop releases pending shims; late and double replies are ignored).

---

## File Structure

```
agent-master/
├─ Package.swift                              grows task by task; final form in Task 12
├─ Sources/
│  ├─ AgentMasterCore/
│  │  ├─ JSONValue.swift                      generic JSON tree + literals + accessors
│  │  ├─ Models.swift                         ToolKind/ToolCall/FileChange/Todo/Subagent/Usage
│  │  ├─ SessionEvent.swift                   the app-internal event vocabulary
│  │  ├─ SessionState.swift                   reducer: apply(SessionEvent)
│  │  ├─ Formatting.swift                     TokenFormat, DurationFormat
│  │  └─ Theme.swift                          Muse color tokens + ANSI palette
│  ├─ AgentMasterWire/
│  │  ├─ WireMessage.swift                    WireKind/WireMessage/WireReply/WireCodec/LineBuffer
│  │  ├─ UnixSocket.swift                     POSIX client/listener/connection
│  │  ├─ WireConnection.swift                 WireConnector/WireConnection protocols + Unix impl
│  │  ├─ HookShim.swift                       shim decision logic (pure, injectable)
│  │  ├─ StatusLineFormatter.swift            ANSI Muse status line
│  │  └─ SessionSettingsBuilder.swift         --settings JSON (hooks + statusLine)
│  ├─ agentmaster-hook/main.swift             CLI entry: hook | statusline | settings
│  ├─ AgentMasterBridge/
│  │  ├─ ToolClassifier.swift                 tool_name + tool_input → ToolKind
│  │  ├─ PatchParser.swift                    tool_response.structuredPatch → FileChange
│  │  ├─ UsageParser.swift                    statusLine JSON → Usage
│  │  ├─ HookTranslator.swift                 hook JSON → [SessionEvent]
│  │  ├─ LaunchEnvironment.swift              login-shell env capture + sanitizing
│  │  ├─ ClaudeLocator.swift                  find the real claude binary
│  │  ├─ AppPaths.swift                       support dir, socket, settings, hook exe
│  │  └─ HookServer.swift                     socket accept loop, ordered delivery, replies
│  ├─ TerminalKit/
│  │  ├─ TerminalLaunch.swift                 launch description
│  │  ├─ TerminalPalette.swift                NSColor(hex:), Muse palette for SwiftTerm
│  │  ├─ TerminalSession.swift                owns LocalProcessTerminalView + process
│  │  └─ TerminalHost.swift                   NSViewRepresentable embedding a session
│  ├─ AgentMasterUI/
│  │  ├─ Style.swift                          Color(hex:), Palette, MuseFont, HairLine, EmptyHint
│  │  ├─ StatusGlyph.swift
│  │  ├─ PanelSection.swift
│  │  ├─ TodoPanel.swift
│  │  ├─ AgentsPanel.swift
│  │  ├─ ChangesPanel.swift                   + DiffView
│  │  ├─ UsagePanel.swift
│  │  ├─ SidePanel.swift
│  │  ├─ SessionSidebar.swift                 + SessionRow
│  │  ├─ SessionHeader.swift
│  │  └─ PreviewData.swift
│  └─ AgentMaster/
│     ├─ AgentMasterApp.swift                 @main
│     ├─ AppModel.swift                       server, sessions, routing
│     ├─ SessionController.swift              one PTY session + its state
│     └─ MainWindow.swift
├─ Tests/
│  ├─ AgentMasterCoreTests/{JSONValueTests,ModelsTests,SessionStateTests}.swift
│  ├─ AgentMasterWireTests/{WireCodecTests,UnixSocketTests,HookShimTests,SessionSettingsBuilderTests,TestSupport}.swift
│  ├─ AgentMasterBridgeTests/{Fixtures/,TestSupport,HookTranslatorTests,PatchParserTests,LaunchEnvironmentTests,ClaudeLocatorTests,AppPathsTests,HookServerTests}.swift
│  ├─ TerminalKitTests/TerminalKitTests.swift
│  └─ AgentMasterUITests/AgentMasterUITests.swift
└─ scripts/{bundle.sh,smoke.py}
```

---

### Task 1: Package scaffold and Core models

**Files:**
- Create: `Package.swift`
- Create: `Sources/AgentMasterCore/JSONValue.swift`, `Models.swift`, `SessionEvent.swift`, `Formatting.swift`, `Theme.swift`
- Test: `Tests/AgentMasterCoreTests/JSONValueTests.swift`, `Tests/AgentMasterCoreTests/ModelsTests.swift`
- Modify: `.gitignore` (add `build/`)

**Interfaces:**
- Consumes: nothing.
- Produces, for all later tasks:
  - `enum JSONValue: Codable, Equatable, Sendable`, with the cases `null`, `bool(Bool)`, `number(Double)`, `string(String)`, `array([JSONValue])`, `object([String: JSONValue])`.
  - JSONValue has `subscript(String) -> JSONValue?` and `subscript(Int) -> JSONValue?`.
  - JSONValue accessors: `stringValue`, `doubleValue`, `intValue`, `boolValue`, `arrayValue`, `objectValue`.
  - JSONValue also has `static func parse(_ data: Data) throws -> JSONValue`, `func encoded() throws -> Data`, and all `ExpressibleBy…Literal` conformances.
  - `ToolKind`, with a `title` property; `ToolCall(id:name:kind:)`; `ToolOutcome`.
  - `DiffLine(kind:text:)`; `DiffHunk(oldStart:oldLines:newStart:newLines:lines:)`; `FileChange(path:hunks:)`, with `added` and `removed` counts.
  - `TodoStatus` (`pending`, `inProgress = "in_progress"`, `completed`) and `TodoItem(id:subject:status:)`.
  - `SubagentInfo(id:type:description:startedAt:finishedAt:)`, with `finished` and `elapsed(at:)`.
  - `Usage(modelName:contextUsedPercent:inputTokens:outputTokens:costUSD:)`.
  - `SessionEvent`; the cases are listed in Step 3.
  - `TokenFormat.short(Int)` and `DurationFormat.short(TimeInterval)`.
  - `Theme`: string constants plus `Theme.ansi: [String]` (16 entries) and `Theme.rgb(String) -> (r: UInt8, g: UInt8, b: UInt8)?`.

- [ ] **Step 1: Create the package manifest and gitignore entry**

`Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentMaster",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AgentMasterCore"),
        .testTarget(name: "AgentMasterCoreTests", dependencies: ["AgentMasterCore"]),
    ]
)
```

Append a line `build/` to `.gitignore`.

- [ ] **Step 2: Write the failing tests**

`Tests/AgentMasterCoreTests/JSONValueTests.swift`:

```swift
import XCTest
@testable import AgentMasterCore

final class JSONValueTests: XCTestCase {
    func testDecodesAllKindsAndKeepsBoolsDistinctFromNumbers() throws {
        let value = try JSONValue.parse(Data(#"{"a":1,"b":true,"c":"x","d":[null,2.5],"e":{"f":false}}"#.utf8))
        XCTAssertEqual(value, ["a": 1, "b": true, "c": "x", "d": [nil, 2.5], "e": ["f": false]])
    }

    func testAccessorsReturnNilOnKindMismatch() throws {
        let value: JSONValue = ["a": 1, "b": true, "c": "x", "d": [nil, 2.5]]
        XCTAssertEqual(value["a"]?.intValue, 1)
        XCTAssertEqual(value["b"]?.boolValue, true)
        XCTAssertNil(value["b"]?.intValue)
        XCTAssertEqual(value["c"]?.stringValue, "x")
        XCTAssertNil(value["c"]?["nested"])
        XCTAssertEqual(value["d"]?[1]?.doubleValue, 2.5)
        XCTAssertNil(value["d"]?[5])
        XCTAssertEqual(value["d"]?.arrayValue?.count, 2)
        XCTAssertEqual(value.objectValue?.count, 4)
        XCTAssertNil(value["missing"])
    }

    func testRoundTripsThroughEncoding() throws {
        let value: JSONValue = ["s": "a/b \"q\"\n", "n": 1674, "f": 0.03296375, "z": nil, "arr": [true, "x"]]
        XCTAssertEqual(try JSONValue.parse(value.encoded()), value)
    }
}
```

`Tests/AgentMasterCoreTests/ModelsTests.swift`:

```swift
import XCTest
@testable import AgentMasterCore

final class ModelsTests: XCTestCase {
    func testToolTitles() {
        XCTAssertEqual(ToolKind.read(path: "/p/app.py").title, "Read app.py")
        XCTAssertEqual(ToolKind.search(pattern: "TODO").title, "Search TODO")
        XCTAssertEqual(ToolKind.edit(path: "/p/app.py").title, "Edit app.py")
        XCTAssertEqual(ToolKind.write(path: "/p/notes.txt").title, "Write notes.txt")
        XCTAssertEqual(ToolKind.shell(command: "echo hi", description: nil).title, "$ echo hi")
        XCTAssertEqual(ToolKind.web(target: "https://x.dev").title, "Fetch https://x.dev")
        XCTAssertEqual(ToolKind.agent(description: "Review").title, "Agent Review")
        XCTAssertEqual(ToolKind.other(name: "ToolSearch").title, "ToolSearch")
        XCTAssertEqual(ToolKind.read(path: "").title, "Read")
    }

    func testFileChangeCountsAddedAndRemovedAcrossHunks() {
        let change = FileChange(path: "a", hunks: [
            DiffHunk(oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, lines: [
                DiffLine(kind: .context, text: "x"), DiffLine(kind: .removed, text: "y"), DiffLine(kind: .added, text: "z"),
            ]),
            DiffHunk(oldStart: 9, oldLines: 0, newStart: 9, newLines: 1, lines: [DiffLine(kind: .added, text: "w")]),
        ])
        XCTAssertEqual(change.added, 2)
        XCTAssertEqual(change.removed, 1)
        XCTAssertEqual(change.id, "a")
    }

    func testTokenFormat() {
        XCTAssertEqual(TokenFormat.short(753), "753")
        XCTAssertEqual(TokenFormat.short(1000), "1k")
        XCTAssertEqual(TokenFormat.short(1600), "1.6k")
        XCTAssertEqual(TokenFormat.short(23361), "23.4k")
        XCTAssertEqual(TokenFormat.short(1_250_000), "1.2M")
    }

    func testDurationFormat() {
        XCTAssertEqual(DurationFormat.short(3.7), "3s")
        XCTAssertEqual(DurationFormat.short(65), "1m 5s")
        XCTAssertEqual(DurationFormat.short(3720), "1h 2m")
    }

    func testSubagentElapsedStopsAtFinish() {
        let start = Date(timeIntervalSince1970: 100)
        var agent = SubagentInfo(id: "a", type: "general-purpose", startedAt: start)
        XCTAssertEqual(agent.elapsed(at: start.addingTimeInterval(4)), 4)
        XCTAssertFalse(agent.finished)
        agent.finishedAt = start.addingTimeInterval(2)
        XCTAssertTrue(agent.finished)
        XCTAssertEqual(agent.elapsed(at: start.addingTimeInterval(60)), 2)
    }

    func testThemeHexParsingAndPalette() {
        let accent = Theme.rgb(Theme.accent)
        XCTAssertEqual(accent?.r, 90)
        XCTAssertEqual(accent?.g, 160)
        XCTAssertEqual(accent?.b, 255)
        XCTAssertNil(Theme.rgb("#12345"))
        XCTAssertNil(Theme.rgb("zzzzzz"))
        XCTAssertEqual(Theme.ansi.count, 16)
        XCTAssertTrue(Theme.ansi.allSatisfy { Theme.rgb($0) != nil })
    }
}
```

- [ ] **Step 3: Run the tests and verify they fail**

Run: `swift test --filter AgentMasterCoreTests`
Expected: the build fails with errors like `cannot find 'JSONValue' in scope`.

- [ ] **Step 4: Implement the Core models**

`Sources/AgentMasterCore/JSONValue.swift`:

```swift
import Foundation

/// A loosely typed JSON tree. Claude Code hook payloads are open-ended, so the
/// translator reads them through this instead of rigid Codable structs.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? { doubleValue.map { Int($0) } }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            // Bool must be tried before Double so `true` never becomes 1.
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
```

`Sources/AgentMasterCore/Models.swift`:

```swift
import Foundation

public enum ToolKind: Equatable, Sendable {
    case read(path: String)
    case search(pattern: String)
    case edit(path: String)
    case write(path: String)
    case shell(command: String, description: String?)
    case web(target: String)
    case agent(description: String)
    case other(name: String)

    /// One-line label, e.g. "Read app.py" or "$ echo hi".
    public var title: String {
        switch self {
        case .read(let path): return Self.join("Read", Self.basename(path))
        case .search(let pattern): return Self.join("Search", pattern)
        case .edit(let path): return Self.join("Edit", Self.basename(path))
        case .write(let path): return Self.join("Write", Self.basename(path))
        case .shell(let command, _): return "$ " + command
        case .web(let target): return Self.join("Fetch", target)
        case .agent(let description): return Self.join("Agent", description)
        case .other(let name): return name
        }
    }

    private static func basename(_ path: String) -> String {
        path.isEmpty ? "" : (path as NSString).lastPathComponent
    }

    private static func join(_ verb: String, _ detail: String) -> String {
        detail.isEmpty ? verb : verb + " " + detail
    }
}

public struct ToolCall: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let kind: ToolKind

    public init(id: String, name: String, kind: ToolKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public enum ToolOutcome: Equatable, Sendable {
    case success
    case failure(message: String)
}

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case context, added, removed }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct DiffHunk: Equatable, Sendable {
    public let oldStart: Int
    public let oldLines: Int
    public let newStart: Int
    public let newLines: Int
    public let lines: [DiffLine]

    public init(oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.lines = lines
    }
}

public struct FileChange: Equatable, Sendable, Identifiable {
    public let path: String
    public var hunks: [DiffHunk]

    public init(path: String, hunks: [DiffHunk]) {
        self.path = path
        self.hunks = hunks
    }

    public var id: String { path }
    public var added: Int { hunks.flatMap(\.lines).filter { $0.kind == .added }.count }
    public var removed: Int { hunks.flatMap(\.lines).filter { $0.kind == .removed }.count }
}

public enum TodoStatus: String, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
}

public struct TodoItem: Equatable, Sendable, Identifiable {
    public let id: String
    public var subject: String
    public var status: TodoStatus

    public init(id: String, subject: String, status: TodoStatus) {
        self.id = id
        self.subject = subject
        self.status = status
    }
}

public struct SubagentInfo: Equatable, Sendable, Identifiable {
    public let id: String
    public var type: String
    public var description: String?
    public var startedAt: Date
    public var finishedAt: Date?

    public init(id: String, type: String, description: String? = nil, startedAt: Date, finishedAt: Date? = nil) {
        self.id = id
        self.type = type
        self.description = description
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var finished: Bool { finishedAt != nil }

    public func elapsed(at now: Date) -> TimeInterval {
        max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
    }
}

public struct Usage: Equatable, Sendable {
    public let modelName: String
    public let contextUsedPercent: Int?
    public let inputTokens: Int
    public let outputTokens: Int
    public let costUSD: Double

    public init(modelName: String, contextUsedPercent: Int?, inputTokens: Int, outputTokens: Int, costUSD: Double) {
        self.modelName = modelName
        self.contextUsedPercent = contextUsedPercent
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
    }
}
```

`Sources/AgentMasterCore/SessionEvent.swift`:

```swift
import Foundation

/// The only vocabulary the UI understands. Produced by the Bridge's HookTranslator.
public enum SessionEvent: Equatable, Sendable {
    case sessionStarted(claudeSessionId: String, cwd: String, transcriptPath: String?)
    case promptSubmitted(text: String)
    case toolStarted(ToolCall)
    case toolFinished(toolUseId: String, outcome: ToolOutcome, durationMs: Int?)
    case fileChanged(FileChange)
    case todosChanged([TodoItem])
    case subagentStarted(agentId: String, agentType: String)
    case subagentDescribed(agentId: String, description: String, agentType: String?)
    case subagentFinished(agentId: String)
    case permissionModeChanged(String)
    case usageUpdated(Usage)
    case needsAttention(message: String)
    case turnFinished(lastMessage: String?)
    case sessionEnded(reason: String?)
}
```

`Sources/AgentMasterCore/Formatting.swift`:

```swift
import Foundation

public enum TokenFormat {
    /// 753 → "753", 1600 → "1.6k", 1_250_000 → "1.2M".
    public static func short(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        if count < 1_000_000 { return trimmed(Double(count) / 1000) + "k" }
        return trimmed(Double(count) / 1_000_000) + "M"
    }

    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}

public enum DurationFormat {
    /// 3.7 → "3s", 65 → "1m 5s", 3720 → "1h 2m".
    public static func short(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
```

`Sources/AgentMasterCore/Theme.swift`:

```swift
import Foundation

/// Muse dark theme tokens (spec §4.6). Hex strings so every layer (ANSI, AppKit, SwiftUI) can use them.
public enum Theme {
    public static let bg = "#1e1e22"
    public static let text = "#ccd3db"
    public static let muted = "#8a9098"
    public static let faint = "#676c74"
    public static let accent = "#5aa0ff"
    public static let selection = "#263854"
    public static let teal = "#8abeb7"
    public static let success = "#a6e3a1"
    public static let error = "#f38ba8"
    public static let warning = "#ffe14a"
    public static let diffDelBg = "#4a221d"
    public static let diffDelFg = "#cc6666"
    public static let diffAddBg = "#213a2b"
    public static let diffAddFg = "#b5bd68"
    public static let shimmer = ["#676c74", "#767b83", "#9aa0a8", "#bdc4cc", "#ccd3db"]

    /// ANSI 0–15 for the embedded terminal, derived from the tokens above.
    public static let ansi: [String] = [
        "#2a2a30", "#f38ba8", "#a6e3a1", "#ffe14a", "#5aa0ff", "#c5a3ff", "#8abeb7", "#ccd3db",
        "#676c74", "#ff9eb8", "#b5e8b0", "#fff08a", "#8cbcff", "#d7bfff", "#a8d8d2", "#ffffff",
    ]

    public static func rgb(_ hex: String) -> (r: UInt8, g: UInt8, b: UInt8)? {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        return (UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff))
    }
}
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `swift test --filter AgentMasterCoreTests`
Expected: all tests in `JSONValueTests` and `ModelsTests` PASS.

- [ ] **Step 6: Commit**

```bash
git add Package.swift .gitignore Sources/AgentMasterCore Tests/AgentMasterCoreTests
git commit -m "feat(core): add package scaffold, JSONValue, models, theme tokens"
```

---

### Task 2: SessionState reducer

**Files:**
- Create: `Sources/AgentMasterCore/SessionState.swift`
- Test: `Tests/AgentMasterCoreTests/SessionStateTests.swift`

**Interfaces:**
- Consumes: `SessionEvent` and all the models from Task 1.
- Produces:
  - `enum SessionStatus { starting, idle, running, needsAttention, ended }`.
  - `struct SessionState: Equatable`, with the properties `status`, `claudeSessionId`, `cwd`, `transcriptPath`, `todos`, `subagents`, `changes`, `runningTools`, `lastTool`, `usage`, `permissionMode`, `attentionMessage`, `lastMessage`, and `endReason`.
  - `mutating func apply(_ event: SessionEvent, at now: Date = Date())`.

Rules the tests pin:

- A `sessionStarted` with a *different* id resets todos, subagents, changes, and running tools. This covers `/clear`.
- `ended` is sticky. Only `sessionStarted` revives the session.
- `turnFinished` clears running tools. Tools denied by a hook never get a PostToolUse.
- `toolFinished` clears a pending attention state. A user approving in the terminal means work is continuing.
- File changes merge per path, and path order is preserved.

- [ ] **Step 1: Write the failing test**

`Tests/AgentMasterCoreTests/SessionStateTests.swift`:

```swift
import XCTest
@testable import AgentMasterCore

final class SessionStateTests: XCTestCase {
    private let bash = ToolCall(id: "t1", name: "Bash", kind: .shell(command: "echo hi", description: nil))
    private let t0 = Date(timeIntervalSince1970: 1000)

    func testTurnLifecycle() {
        var state = SessionState()
        XCTAssertEqual(state.status, .starting)
        state.apply(.sessionStarted(claudeSessionId: "s1", cwd: "/p", transcriptPath: "/t.jsonl"))
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.claudeSessionId, "s1")
        XCTAssertEqual(state.transcriptPath, "/t.jsonl")
        state.apply(.promptSubmitted(text: "hi"))
        XCTAssertEqual(state.status, .running)
        state.apply(.toolStarted(bash))
        XCTAssertEqual(state.runningTools, [bash])
        XCTAssertEqual(state.lastTool, bash)
        state.apply(.toolFinished(toolUseId: "t1", outcome: .success, durationMs: 5))
        XCTAssertEqual(state.runningTools, [])
        state.apply(.turnFinished(lastMessage: "done"))
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.lastMessage, "done")
    }

    func testTurnFinishedClearsToolsThatNeverFinished() {
        var state = SessionState()
        state.apply(.toolStarted(bash))
        state.apply(.turnFinished(lastMessage: nil))
        XCTAssertEqual(state.runningTools, [])
        state.apply(.turnFinished(lastMessage: nil))
        XCTAssertEqual(state.status, .idle)
    }

    func testAttentionIsSetAndClearedByProgress() {
        var state = SessionState()
        state.apply(.toolStarted(bash))
        state.apply(.needsAttention(message: "Permission needed: $ echo hi"))
        XCTAssertEqual(state.status, .needsAttention)
        XCTAssertEqual(state.attentionMessage, "Permission needed: $ echo hi")
        state.apply(.toolFinished(toolUseId: "t1", outcome: .success, durationMs: nil))
        XCTAssertEqual(state.status, .running)
        XCTAssertNil(state.attentionMessage)
        state.apply(.needsAttention(message: "again"))
        state.apply(.promptSubmitted(text: "go"))
        XCTAssertEqual(state.status, .running)
        XCTAssertNil(state.attentionMessage)
    }

    func testFileChangesMergePerPathInFirstSeenOrder() {
        var state = SessionState()
        let hunkA = DiffHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 1, lines: [DiffLine(kind: .added, text: "a")])
        let hunkB = DiffHunk(oldStart: 5, oldLines: 1, newStart: 5, newLines: 0, lines: [DiffLine(kind: .removed, text: "b")])
        state.apply(.fileChanged(FileChange(path: "/p/x", hunks: [hunkA])))
        state.apply(.fileChanged(FileChange(path: "/p/y", hunks: [hunkA])))
        state.apply(.fileChanged(FileChange(path: "/p/x", hunks: [hunkB])))
        XCTAssertEqual(state.changes.map(\.path), ["/p/x", "/p/y"])
        XCTAssertEqual(state.changes[0].hunks, [hunkA, hunkB])
    }

    func testSubagentLifecycleInAnyOrder() {
        var state = SessionState()
        state.apply(.subagentStarted(agentId: "a1", agentType: "general-purpose"), at: t0)
        state.apply(.subagentDescribed(agentId: "a1", description: "Review", agentType: nil), at: t0.addingTimeInterval(1))
        state.apply(.subagentFinished(agentId: "a1"), at: t0.addingTimeInterval(3))
        state.apply(.subagentFinished(agentId: "a1"), at: t0.addingTimeInterval(9))
        XCTAssertEqual(state.subagents, [SubagentInfo(id: "a1", type: "general-purpose", description: "Review",
                                                      startedAt: t0, finishedAt: t0.addingTimeInterval(3))])

        state.apply(.subagentDescribed(agentId: "a2", description: "Late", agentType: "Explore"), at: t0)
        state.apply(.subagentFinished(agentId: "a3"), at: t0)
        XCTAssertEqual(state.subagents[1], SubagentInfo(id: "a2", type: "Explore", description: "Late", startedAt: t0))
        XCTAssertEqual(state.subagents[2], SubagentInfo(id: "a3", type: "agent", startedAt: t0, finishedAt: t0))
    }

    func testNewClaudeSessionIdResetsPanelsButSameIdDoesNot() {
        var state = SessionState()
        state.apply(.sessionStarted(claudeSessionId: "s1", cwd: "/p", transcriptPath: nil))
        state.apply(.todosChanged([TodoItem(id: "1", subject: "x", status: .pending)]))
        state.apply(.sessionStarted(claudeSessionId: "s1", cwd: "/p", transcriptPath: nil))
        XCTAssertEqual(state.todos.count, 1)
        state.apply(.subagentStarted(agentId: "a", agentType: "t"))
        state.apply(.fileChanged(FileChange(path: "f", hunks: [])))
        state.apply(.sessionStarted(claudeSessionId: "s2", cwd: "/p", transcriptPath: nil))
        XCTAssertEqual(state.todos, [])
        XCTAssertEqual(state.subagents, [])
        XCTAssertEqual(state.changes, [])
        XCTAssertEqual(state.claudeSessionId, "s2")
        XCTAssertEqual(state.status, .idle)
    }

    func testEndedIsStickyUntilSessionStarts() {
        var state = SessionState()
        state.apply(.toolStarted(bash))
        state.apply(.sessionEnded(reason: "prompt_input_exit"))
        XCTAssertEqual(state.status, .ended)
        XCTAssertEqual(state.endReason, "prompt_input_exit")
        XCTAssertEqual(state.runningTools, [])
        state.apply(.turnFinished(lastMessage: nil))
        state.apply(.needsAttention(message: "x"))
        XCTAssertEqual(state.status, .ended)
        state.apply(.sessionStarted(claudeSessionId: "s9", cwd: "/p", transcriptPath: nil))
        XCTAssertEqual(state.status, .idle)
        XCTAssertNil(state.endReason)
    }

    func testUsageAndPermissionMode() {
        var state = SessionState()
        let usage = Usage(modelName: "Haiku 4.5", contextUsedPercent: 12, inputTokens: 1, outputTokens: 2, costUSD: 0.5)
        state.apply(.usageUpdated(usage))
        state.apply(.permissionModeChanged("plan"))
        XCTAssertEqual(state.usage, usage)
        XCTAssertEqual(state.permissionMode, "plan")
    }
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `swift test --filter SessionStateTests`
Expected: the build fails with `cannot find 'SessionState' in scope`.

- [ ] **Step 3: Implement the reducer**

`Sources/AgentMasterCore/SessionState.swift`:

```swift
import Foundation

public enum SessionStatus: Equatable, Sendable {
    case starting, idle, running, needsAttention, ended
}

/// Everything the panels show for one session. Pure value type; only `apply` mutates it.
public struct SessionState: Equatable, Sendable {
    public var status: SessionStatus = .starting
    public var claudeSessionId: String?
    public var cwd: String?
    public var transcriptPath: String?
    public var todos: [TodoItem] = []
    public var subagents: [SubagentInfo] = []
    public var changes: [FileChange] = []
    public var runningTools: [ToolCall] = []
    public var lastTool: ToolCall?
    public var usage: Usage?
    public var permissionMode: String?
    public var attentionMessage: String?
    public var lastMessage: String?
    public var endReason: String?

    public init() {}

    public mutating func apply(_ event: SessionEvent, at now: Date = Date()) {
        switch event {
        case let .sessionStarted(claudeSessionId, cwd, transcriptPath):
            if let current = self.claudeSessionId, current != claudeSessionId {
                // A new conversation in the same process (e.g. /clear): start the panels over.
                todos = []
                subagents = []
                changes = []
                runningTools = []
                lastTool = nil
                lastMessage = nil
            }
            self.claudeSessionId = claudeSessionId
            self.cwd = cwd
            self.transcriptPath = transcriptPath
            status = .idle
            attentionMessage = nil
            endReason = nil

        case .promptSubmitted:
            setStatus(.running)
            attentionMessage = nil

        case .toolStarted(let call):
            runningTools.removeAll { $0.id == call.id }
            runningTools.append(call)
            lastTool = call
            setStatus(.running)
            attentionMessage = nil

        case let .toolFinished(toolUseId, _, _):
            runningTools.removeAll { $0.id == toolUseId }
            if status == .needsAttention {
                setStatus(.running)
                attentionMessage = nil
            }

        case .fileChanged(let change):
            if let index = changes.firstIndex(where: { $0.path == change.path }) {
                changes[index].hunks += change.hunks
            } else {
                changes.append(change)
            }

        case .todosChanged(let items):
            todos = items

        case let .subagentStarted(agentId, agentType):
            if let index = subagentIndex(agentId) {
                subagents[index].type = agentType
            } else {
                subagents.append(SubagentInfo(id: agentId, type: agentType, startedAt: now))
            }

        case let .subagentDescribed(agentId, description, agentType):
            if let index = subagentIndex(agentId) {
                subagents[index].description = description
                if let agentType { subagents[index].type = agentType }
            } else {
                subagents.append(SubagentInfo(id: agentId, type: agentType ?? "agent", description: description, startedAt: now))
            }

        case .subagentFinished(let agentId):
            if let index = subagentIndex(agentId) {
                if subagents[index].finishedAt == nil { subagents[index].finishedAt = now }
            } else {
                subagents.append(SubagentInfo(id: agentId, type: "agent", startedAt: now, finishedAt: now))
            }

        case .permissionModeChanged(let mode):
            permissionMode = mode

        case .usageUpdated(let usage):
            self.usage = usage

        case .needsAttention(let message):
            setStatus(.needsAttention)
            attentionMessage = message

        case .turnFinished(let lastMessage):
            runningTools = []
            attentionMessage = nil
            if let lastMessage { self.lastMessage = lastMessage }
            setStatus(.idle)

        case .sessionEnded(let reason):
            runningTools = []
            attentionMessage = nil
            endReason = reason
            status = .ended
        }
    }

    /// `ended` is sticky; only `sessionStarted` (which assigns `status` directly) revives a session.
    private mutating func setStatus(_ newStatus: SessionStatus) {
        if status != .ended { status = newStatus }
    }

    private func subagentIndex(_ id: String) -> Int? {
        subagents.firstIndex { $0.id == id }
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `swift test --filter AgentMasterCoreTests`
Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentMasterCore/SessionState.swift Tests/AgentMasterCoreTests/SessionStateTests.swift
git commit -m "feat(core): add SessionState reducer"
```

---

### Task 3: Wire messages, codec, and line buffer

**Files:**
- Modify: `Package.swift`
- Create: `Sources/AgentMasterWire/WireMessage.swift`
- Test: `Tests/AgentMasterWireTests/WireCodecTests.swift`

**Interfaces:**
- Consumes: `JSONValue` (Task 1).
- Produces:
  - `enum WireKind: String, Codable { event, request, statusline }`.
  - `struct WireMessage: Codable, Equatable { id, sessionId, kind, payload: JSONValue }`.
  - `struct WireReply: Codable, Equatable { id: String; output: String? }`.
  - `WireCodec.encodeLine(_:) throws -> Data`. The output is exactly one trailing `\n`.
  - `WireCodec.decode(_:line:) throws -> T`.
  - `struct LineBuffer { mutating func append(_ chunk: Data) -> [Data] }`. It returns complete non-empty lines without the `\n`.

- [ ] **Step 1: Add the Wire targets to Package.swift**

Replace `Package.swift` with:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentMaster",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "AgentMasterCore"),
        .target(name: "AgentMasterWire", dependencies: ["AgentMasterCore"]),
        .testTarget(name: "AgentMasterCoreTests", dependencies: ["AgentMasterCore"]),
        .testTarget(name: "AgentMasterWireTests", dependencies: ["AgentMasterWire"]),
    ]
)
```

- [ ] **Step 2: Write the failing test**

`Tests/AgentMasterWireTests/WireCodecTests.swift`:

```swift
import XCTest
import AgentMasterCore
@testable import AgentMasterWire

final class WireCodecTests: XCTestCase {
    func testMessageRoundTripsAsASingleLine() throws {
        let message = WireMessage(id: "m1", sessionId: "S1", kind: .request,
                                  payload: ["hook_event_name": "PreToolUse", "prompt": "line1\nline2"])
        let line = try WireCodec.encodeLine(message)
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1)
        XCTAssertEqual(try WireCodec.decode(WireMessage.self, line: line.dropLast()), message)
    }

    func testReplyWithoutOutputRoundTrips() throws {
        let reply = WireReply(id: "m1", output: nil)
        let line = try WireCodec.encodeLine(reply)
        XCTAssertEqual(String(decoding: line, as: UTF8.self), "{\"id\":\"m1\"}\n")
        XCTAssertEqual(try WireCodec.decode(WireReply.self, line: line.dropLast()), reply)
        XCTAssertEqual(try WireCodec.decode(WireReply.self, line: Data(#"{"id":"m2","output":"{}"}"#.utf8)),
                       WireReply(id: "m2", output: "{}"))
    }

    func testLineBufferSplitsAcrossChunksAndSkipsBlankLines() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data("ab".utf8)), [])
        XCTAssertEqual(buffer.append(Data("c\n\nde\nf".utf8)), [Data("abc".utf8), Data("de".utf8)])
        XCTAssertEqual(buffer.append(Data("g\n".utf8)), [Data("fg".utf8)])
    }
}
```

- [ ] **Step 3: Run the test and verify it fails**

Run: `swift test --filter WireCodecTests`
Expected: the build fails with `cannot find 'WireMessage' in scope`.

- [ ] **Step 4: Implement the codec**

`Sources/AgentMasterWire/WireMessage.swift`:

```swift
import Foundation
import AgentMasterCore

public enum WireKind: String, Codable, Sendable {
    /// Fire-and-forget hook notification.
    case event
    /// The shim blocks until the app replies (PermissionRequest, PreToolUse/AskUserQuestion).
    case request
    /// statusLine JSON; fire-and-forget.
    case statusline
}

public struct WireMessage: Codable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let kind: WireKind
    public let payload: JSONValue

    public init(id: String, sessionId: String, kind: WireKind, payload: JSONValue) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.payload = payload
    }
}

/// `output == nil` means "print nothing": Claude Code then falls back to its own terminal UI.
public struct WireReply: Codable, Equatable, Sendable {
    public let id: String
    public let output: String?

    public init(id: String, output: String?) {
        self.id = id
        self.output = output
    }
}

public enum WireCodec {
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}

/// Accumulates socket reads and yields complete, non-empty lines (without the newline).
public struct LineBuffer {
    private var data = Data()

    public init() {}

    public mutating func append(_ chunk: Data) -> [Data] {
        data.append(chunk)
        var lines: [Data] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let line = Data(data[data.startIndex..<newline])
            data = Data(data[data.index(after: newline)...])
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `swift test --filter AgentMasterWireTests`
Expected: 3 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/AgentMasterWire Tests/AgentMasterWireTests
git commit -m "feat(wire): add NDJSON wire messages, codec and line buffer"
```

---

### Task 4: POSIX Unix domain sockets

**Files:**
- Create: `Sources/AgentMasterWire/UnixSocket.swift`
- Test: `Tests/AgentMasterWireTests/UnixSocketTests.swift`

**Interfaces:**
- Consumes: `LineBuffer` (Task 3).
- Produces:
  - `enum UnixSocketError: Error, Equatable { pathTooLong, system(String, Int32), timeout, closed }`.
  - `enum UnixSocket { static func connect(path: String) throws -> UnixSocketConnection }`.
  - `final class UnixSocketConnection`, with these methods:
    - `write(_ data: Data) throws` is thread-safe. It throws `.closed` after `close()`.
    - `readLine(timeout: TimeInterval?) throws -> Data` throws `.timeout` or `.closed`. Only one reader thread may call it.
    - `close()` is idempotent.
  - `final class UnixSocketListener`, with these methods:
    - `init(path:) throws` unlinks any stale file first and applies chmod 0600.
    - `accept(timeout: TimeInterval) throws -> UnixSocketConnection?` returns nil on timeout.
    - `close()` also unlinks the socket file.

- [ ] **Step 1: Write the failing test**

`Tests/AgentMasterWireTests/UnixSocketTests.swift`:

```swift
import XCTest
@testable import AgentMasterWire

final class UnixSocketTests: XCTestCase {
    private var path: String!

    override func setUp() {
        path = "/tmp/am-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        unlink(path)
    }

    func testRoundTripsLinesInBothDirections() throws {
        let listener = try UnixSocketListener(path: path)
        defer { listener.close() }
        let client = try UnixSocket.connect(path: path)
        let server = try XCTUnwrap(try listener.accept(timeout: 1))
        try client.write(Data("hello\nwor".utf8))
        try client.write(Data("ld\n".utf8))
        XCTAssertEqual(try server.readLine(timeout: 1), Data("hello".utf8))
        XCTAssertEqual(try server.readLine(timeout: 1), Data("world".utf8))
        try server.write(Data("back\n".utf8))
        XCTAssertEqual(try client.readLine(timeout: 1), Data("back".utf8))
    }

    func testSocketFileIsOwnerOnly() throws {
        let listener = try UnixSocketListener(path: path)
        defer { listener.close() }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testStaleFileAtPathIsReplaced() throws {
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let listener = try UnixSocketListener(path: path)
        defer { listener.close() }
        XCTAssertNoThrow(try UnixSocket.connect(path: path))
    }

    func testAcceptReturnsNilOnTimeout() throws {
        let listener = try UnixSocketListener(path: path)
        defer { listener.close() }
        XCTAssertNil(try listener.accept(timeout: 0.1))
    }

    func testReadLineTimesOut() throws {
        let listener = try UnixSocketListener(path: path)
        defer { listener.close() }
        let client = try UnixSocket.connect(path: path)
        _ = client
        let server = try XCTUnwrap(try listener.accept(timeout: 1))
        XCTAssertThrowsError(try server.readLine(timeout: 0.2)) { XCTAssertEqual($0 as? UnixSocketError, .timeout) }
    }

    func testPeerCloseSurfacesAsClosed() throws {
        let listener = try UnixSocketListener(path: path)
        defer { listener.close() }
        let client = try UnixSocket.connect(path: path)
        let server = try XCTUnwrap(try listener.accept(timeout: 1))
        client.close()
        XCTAssertThrowsError(try server.readLine(timeout: 1)) { XCTAssertEqual($0 as? UnixSocketError, .closed) }
    }

    func testWriteAfterCloseThrowsInsteadOfTouchingTheFd() throws {
        let listener = try UnixSocketListener(path: path)
        defer { listener.close() }
        let client = try UnixSocket.connect(path: path)
        client.close()
        client.close()
        XCTAssertThrowsError(try client.write(Data("x\n".utf8))) { XCTAssertEqual($0 as? UnixSocketError, .closed) }
    }

    func testWriteToDeadPeerThrowsWithoutSIGPIPE() throws {
        let listener = try UnixSocketListener(path: path)
        defer { listener.close() }
        let client = try UnixSocket.connect(path: path)
        let server = try XCTUnwrap(try listener.accept(timeout: 1))
        client.close()
        XCTAssertThrowsError(try (0..<64).forEach { _ in try server.write(Data(repeating: 0x41, count: 65536)) })
    }

    func testConnectWithoutListenerFails() {
        XCTAssertThrowsError(try UnixSocket.connect(path: path))
    }

    func testRejectsPathsLongerThanSunPath() {
        XCTAssertThrowsError(try UnixSocket.connect(path: "/tmp/" + String(repeating: "a", count: 200))) {
            XCTAssertEqual($0 as? UnixSocketError, .pathTooLong)
        }
    }
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `swift test --filter UnixSocketTests`
Expected: the build fails with `cannot find 'UnixSocketListener' in scope`.

- [ ] **Step 3: Implement the sockets**

`Sources/AgentMasterWire/UnixSocket.swift`:

```swift
import Foundation

public enum UnixSocketError: Error, Equatable {
    case pathTooLong
    case system(String, Int32)
    case timeout
    case closed
}

func makeSocketAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw UnixSocketError.pathTooLong }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)   // the rest is already zero, so the path is NUL-terminated
    }
    return address
}

private func withSockaddr<T>(_ address: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

public enum UnixSocket {
    public static func connect(path: String) throws -> UnixSocketConnection {
        let address = try makeSocketAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.system("socket", errno) }
        let result = withSockaddr(address) { Darwin.connect(fd, $0, $1) }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.system("connect", code)
        }
        return UnixSocketConnection(fd: fd)
    }
}

/// One connected stream. `write`/`close` may be called from any thread; `readLine` from one reader.
public final class UnixSocketConnection {
    private let fd: Int32
    private let lock = NSLock()
    private var isClosed = false
    private var buffer = LineBuffer()
    private var lines: [Data] = []

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        close()
    }

    public func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        // Checked under the lock so a late writer can never hit a closed-and-reused fd.
        guard !isClosed else { throw UnixSocketError.closed }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw UnixSocketError.system("write", errno)
                }
                offset += written
            }
        }
    }

    public func readLine(timeout: TimeInterval? = nil) throws -> Data {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            if !lines.isEmpty { return lines.removeFirst() }
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { throw UnixSocketError.timeout }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, Int32(max(1, min(remaining * 1000, 60_000))))
                if ready == 0 { continue }
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw UnixSocketError.system("poll", errno)
                }
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw UnixSocketError.system("read", errno)
            }
            if count == 0 { throw UnixSocketError.closed }
            lines.append(contentsOf: buffer.append(Data(chunk[0..<count])))
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fd)
    }
}

public final class UnixSocketListener {
    public let path: String
    private let fd: Int32
    private let lock = NSLock()
    private var isClosed = false

    public init(path: String) throws {
        let address = try makeSocketAddress(path)
        unlink(path)   // a crashed previous run may have left the file behind
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.system("socket", errno) }
        guard withSockaddr(address, { bind(fd, $0, $1) }) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.system("bind", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(path)
            throw UnixSocketError.system("listen", code)
        }
        self.path = path
        self.fd = fd
    }

    deinit {
        close()
    }

    /// Returns nil when nothing connected within `timeout`.
    public func accept(timeout: TimeInterval) throws -> UnixSocketConnection? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, Int32(timeout * 1000))
        if ready == 0 { return nil }
        if ready < 0 {
            if errno == EINTR { return nil }
            throw UnixSocketError.system("poll", errno)
        }
        let client = Darwin.accept(fd, nil, nil)
        if client < 0 {
            if errno == EINTR || errno == ECONNABORTED || errno == EAGAIN { return nil }
            throw UnixSocketError.system("accept", errno)
        }
        return UnixSocketConnection(fd: client)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fd)
        unlink(path)
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `swift test --filter UnixSocketTests`
Expected: 10 tests PASS. The dead-peer test must not crash the test process with SIGPIPE.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentMasterWire/UnixSocket.swift Tests/AgentMasterWireTests/UnixSocketTests.swift
git commit -m "feat(wire): add POSIX unix socket client and listener"
```

---

### Task 5: Hook shim logic and status line formatter

**Files:**
- Create: `Sources/AgentMasterWire/WireConnection.swift`, `Sources/AgentMasterWire/HookShim.swift`, `Sources/AgentMasterWire/StatusLineFormatter.swift`
- Test: `Tests/AgentMasterWireTests/TestSupport.swift`, `Tests/AgentMasterWireTests/HookShimTests.swift`

**Interfaces:**
- Consumes: `WireMessage`, `WireReply`, `WireCodec` (Task 3); `UnixSocket` (Task 4); `Theme` and `JSONValue` (Task 1).
- Produces:
  - `protocol WireConnection: AnyObject { send(_:) throws; receiveReply(timeout:) throws -> WireReply; close() }`.
  - `protocol WireConnector { func connect() throws -> WireConnection }`.
  - `struct UnixWireConnector(path:)`.
  - `enum ShimMode: String { hook, statusline }`.
  - `HookShim.defaultDecisionTimeout = 590` and `HookShim.isDecision(_ payload: JSONValue) -> Bool`.
  - `HookShim.run(mode:input:environment:connector:decisionTimeout:makeId:) -> String?`. The return value is what goes to stdout; nil means print nothing.
  - `StatusLineFormatter.format(_ payload: JSONValue) -> String`.

- [ ] **Step 1: Write the failing tests**

`Tests/AgentMasterWireTests/TestSupport.swift`:

```swift
import Foundation
@testable import AgentMasterWire

final class FakeConnection: WireConnection {
    var sent: [WireMessage] = []
    var reply: Result<WireReply, Error> = .failure(UnixSocketError.timeout)
    var receiveTimeout: TimeInterval?
    var closed = false

    func send(_ message: WireMessage) throws { sent.append(message) }

    func receiveReply(timeout: TimeInterval) throws -> WireReply {
        receiveTimeout = timeout
        return try reply.get()
    }

    func close() { closed = true }
}

struct FakeConnector: WireConnector {
    let connection: FakeConnection?

    func connect() throws -> WireConnection {
        guard let connection else { throw UnixSocketError.system("connect", ECONNREFUSED) }
        return connection
    }
}
```

`Tests/AgentMasterWireTests/HookShimTests.swift`:

```swift
import XCTest
import AgentMasterCore
@testable import AgentMasterWire

final class HookShimTests: XCTestCase {
    private let env = ["AGENTMASTER_SESSION_ID": "S1"]

    private func run(_ json: String, mode: ShimMode = .hook, connection: FakeConnection?,
                     env: [String: String]? = nil) -> String? {
        HookShim.run(mode: mode, input: Data(json.utf8), environment: env ?? self.env,
                     connector: FakeConnector(connection: connection), makeId: { "M1" })
    }

    func testNotificationEventIsForwardedWithoutWaiting() {
        let connection = FakeConnection()
        XCTAssertNil(run(#"{"hook_event_name":"PostToolUse","tool_name":"Bash"}"#, connection: connection))
        XCTAssertEqual(connection.sent, [WireMessage(id: "M1", sessionId: "S1", kind: .event,
                                                     payload: ["hook_event_name": "PostToolUse", "tool_name": "Bash"])])
        XCTAssertNil(connection.receiveTimeout)
        XCTAssertTrue(connection.closed)
    }

    func testPermissionRequestWaitsAndPrintsReply() {
        let connection = FakeConnection()
        connection.reply = .success(WireReply(id: "M1", output: #"{"decision":1}"#))
        XCTAssertEqual(run(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#, connection: connection),
                       #"{"decision":1}"#)
        XCTAssertEqual(connection.sent.first?.kind, .request)
        XCTAssertEqual(connection.receiveTimeout, HookShim.defaultDecisionTimeout)
        XCTAssertEqual(HookShim.defaultDecisionTimeout, 590)
    }

    func testOnlyAskUserQuestionPreToolUseIsADecision() {
        XCTAssertTrue(HookShim.isDecision(["hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion"]))
        XCTAssertTrue(HookShim.isDecision(["hook_event_name": "PermissionRequest", "tool_name": "Bash"]))
        XCTAssertFalse(HookShim.isDecision(["hook_event_name": "PreToolUse", "tool_name": "Bash"]))
        XCTAssertFalse(HookShim.isDecision(["hook_event_name": "PostToolUse", "tool_name": "AskUserQuestion"]))
    }

    func testMismatchedReplyIdPrintsNothing() {
        let connection = FakeConnection()
        connection.reply = .success(WireReply(id: "OTHER", output: "x"))
        XCTAssertNil(run(#"{"hook_event_name":"PermissionRequest"}"#, connection: connection))
    }

    func testReplyTimeoutPrintsNothing() {
        let connection = FakeConnection()
        XCTAssertNil(run(#"{"hook_event_name":"PermissionRequest"}"#, connection: connection))
        XCTAssertTrue(connection.closed)
    }

    func testAppNotRunningPrintsNothing() {
        XCTAssertNil(run(#"{"hook_event_name":"PermissionRequest"}"#, connection: nil))
        XCTAssertNil(run(#"{"hook_event_name":"Stop"}"#, connection: nil))
    }

    func testMissingSessionIdOrBadJSONNeverConnects() {
        let connection = FakeConnection()
        XCTAssertNil(run(#"{"hook_event_name":"Stop"}"#, connection: connection, env: [:]))
        XCTAssertNil(run("not json", connection: connection))
        XCTAssertEqual(connection.sent, [])
    }

    func testStatusLineIsForwardedAndAlwaysPrinted() {
        let json = #"{"model":{"display_name":"Haiku 4.5"},"cwd":"/tmp/p"}"#
        let payload = try! JSONValue.parse(Data(json.utf8))
        let connection = FakeConnection()
        XCTAssertEqual(run(json, mode: .statusline, connection: connection), StatusLineFormatter.format(payload))
        XCTAssertEqual(connection.sent.first?.kind, .statusline)
        XCTAssertNil(connection.receiveTimeout)
        XCTAssertEqual(run(json, mode: .statusline, connection: nil), StatusLineFormatter.format(payload))
    }

    func testStatusLineFormat() throws {
        let payload = try JSONValue.parse(Data(#"{"model":{"display_name":"Haiku 4.5"},"workspace":{"current_dir":"/tmp/my proj"},"context_window":{"used_percentage":12}}"#.utf8))
        XCTAssertEqual(StatusLineFormatter.format(payload),
                       "\u{1B}[38;2;90;160;255mHaiku 4.5\u{1B}[0m"
                       + "\u{1B}[38;2;138;144;152m · \u{1B}[0m"
                       + "\u{1B}[38;2;204;211;219mmy proj\u{1B}[0m"
                       + "\u{1B}[38;2;138;144;152m · \u{1B}[0m"
                       + "\u{1B}[38;2;138;144;152mctx 12%\u{1B}[0m")
        XCTAssertEqual(StatusLineFormatter.format(.null), "\u{1B}[38;2;90;160;255mclaude\u{1B}[0m")
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `swift test --filter HookShimTests`
Expected: the build fails with `cannot find type 'WireConnection' in scope`.

- [ ] **Step 3: Implement the connection, shim, and formatter**

`Sources/AgentMasterWire/WireConnection.swift`:

```swift
import Foundation

public protocol WireConnection: AnyObject {
    func send(_ message: WireMessage) throws
    func receiveReply(timeout: TimeInterval) throws -> WireReply
    func close()
}

public protocol WireConnector {
    func connect() throws -> WireConnection
}

public struct UnixWireConnector: WireConnector {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func connect() throws -> WireConnection {
        UnixWireConnection(socket: try UnixSocket.connect(path: path))
    }
}

final class UnixWireConnection: WireConnection {
    private let socket: UnixSocketConnection

    init(socket: UnixSocketConnection) {
        self.socket = socket
    }

    func send(_ message: WireMessage) throws {
        try socket.write(WireCodec.encodeLine(message))
    }

    func receiveReply(timeout: TimeInterval) throws -> WireReply {
        try WireCodec.decode(WireReply.self, line: socket.readLine(timeout: timeout))
    }

    func close() {
        socket.close()
    }
}
```

`Sources/AgentMasterWire/HookShim.swift`:

```swift
import Foundation
import AgentMasterCore

public enum ShimMode: String {
    case hook
    case statusline
}

/// Everything `agentmaster-hook` does, minus process I/O, so it can be unit tested.
/// Contract: never hang Claude Code; any failure prints nothing (hook) or the local status line.
public enum HookShim {
    /// Below the 600 s hook timeout written into the session settings.
    public static let defaultDecisionTimeout: TimeInterval = 590

    public static func isDecision(_ payload: JSONValue) -> Bool {
        switch payload["hook_event_name"]?.stringValue {
        case "PermissionRequest": return true
        case "PreToolUse": return payload["tool_name"]?.stringValue == "AskUserQuestion"
        default: return false
        }
    }

    public static func run(
        mode: ShimMode,
        input: Data,
        environment: [String: String],
        connector: WireConnector?,
        decisionTimeout: TimeInterval = defaultDecisionTimeout,
        makeId: () -> String = { UUID().uuidString }
    ) -> String? {
        let payload = try? JSONValue.parse(input)
        let fallback = mode == .statusline ? StatusLineFormatter.format(payload ?? .null) : nil
        guard let payload, let sessionId = environment["AGENTMASTER_SESSION_ID"], let connector else { return fallback }

        let kind: WireKind = mode == .statusline ? .statusline : (isDecision(payload) ? .request : .event)
        let message = WireMessage(id: makeId(), sessionId: sessionId, kind: kind, payload: payload)
        do {
            let connection = try connector.connect()
            defer { connection.close() }
            try connection.send(message)
            guard kind == .request else { return fallback }
            let reply = try connection.receiveReply(timeout: decisionTimeout)
            return reply.id == message.id ? reply.output : nil
        } catch {
            return fallback
        }
    }
}
```

`Sources/AgentMasterWire/StatusLineFormatter.swift`:

```swift
import Foundation
import AgentMasterCore

/// Muse-style bottom bar printed by Claude Code's statusLine: `model · folder · ctx N%`.
public enum StatusLineFormatter {
    public static func format(_ payload: JSONValue) -> String {
        var parts = [paint(payload["model"]?["display_name"]?.stringValue ?? "claude", Theme.accent)]
        let directory = payload["workspace"]?["current_dir"]?.stringValue ?? payload["cwd"]?.stringValue ?? ""
        if !directory.isEmpty {
            parts.append(paint((directory as NSString).lastPathComponent, Theme.text))
        }
        if let percent = payload["context_window"]?["used_percentage"]?.intValue {
            parts.append(paint("ctx \(percent)%", Theme.muted))
        }
        return parts.joined(separator: paint(" · ", Theme.muted))
    }

    static func paint(_ text: String, _ hex: String) -> String {
        guard let color = Theme.rgb(hex) else { return text }
        return "\u{1B}[38;2;\(color.r);\(color.g);\(color.b)m\(text)\u{1B}[0m"
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `swift test --filter AgentMasterWireTests`
Expected: all Wire tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentMasterWire Tests/AgentMasterWireTests
git commit -m "feat(wire): add hook shim decision logic and Muse status line"
```

---

### Task 6: Session settings builder and the `agentmaster-hook` executable

**Files:**
- Modify: `Package.swift`
- Create: `Sources/AgentMasterWire/SessionSettingsBuilder.swift`, `Sources/agentmaster-hook/main.swift`
- Test: `Tests/AgentMasterWireTests/SessionSettingsBuilderTests.swift`

**Interfaces:**
- Consumes: `HookShim`, `ShimMode`, and `UnixWireConnector` (Task 5); `JSONValue` (Task 1).
- Produces:
  - `SessionSettingsBuilder(hookExecutable:)`, with `settings() -> JSONValue`, `data() throws -> Data`, `command(_ subcommand: String) -> String`, `static shellQuote(_:)`, and `static hookEvents: [String]`.
  - The executable `agentmaster-hook`, run as `agentmaster-hook [hook|statusline|settings]`. `settings` prints the settings JSON for its own path; the smoke test uses it.

- [ ] **Step 1: Add the executable target**

Replace `Package.swift` with:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentMaster",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agentmaster-hook", targets: ["agentmaster-hook"]),
    ],
    targets: [
        .target(name: "AgentMasterCore"),
        .target(name: "AgentMasterWire", dependencies: ["AgentMasterCore"]),
        .executableTarget(name: "agentmaster-hook", dependencies: ["AgentMasterWire"]),
        .testTarget(name: "AgentMasterCoreTests", dependencies: ["AgentMasterCore"]),
        .testTarget(name: "AgentMasterWireTests", dependencies: ["AgentMasterWire"]),
    ]
)
```

- [ ] **Step 2: Write the failing test**

`Tests/AgentMasterWireTests/SessionSettingsBuilderTests.swift`:

```swift
import XCTest
import AgentMasterCore
@testable import AgentMasterWire

final class SessionSettingsBuilderTests: XCTestCase {
    private let exe = "/Applications/Agent Master.app/Contents/Helpers/agentmaster-hook"

    func testEveryEventRoutesToTheShimAndDecisionsGetLongTimeouts() throws {
        let settings = SessionSettingsBuilder(hookExecutable: exe).settings()
        let hooks = try XCTUnwrap(settings["hooks"])
        XCTAssertEqual(Set(try XCTUnwrap(hooks.objectValue).keys), Set(SessionSettingsBuilder.hookEvents))
        XCTAssertEqual(Set(SessionSettingsBuilder.hookEvents), [
            "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
            "PermissionRequest", "Notification", "Stop", "SubagentStart", "SubagentStop",
        ])

        let pre = try XCTUnwrap(hooks["PreToolUse"]?[0])
        XCTAssertEqual(pre["matcher"], "*")
        XCTAssertEqual(pre["hooks"]?[0]?["type"], "command")
        XCTAssertEqual(pre["hooks"]?[0]?["command"], .string("'\(exe)' hook"))
        XCTAssertEqual(pre["hooks"]?[0]?["timeout"], 600)
        XCTAssertEqual(hooks["PermissionRequest"]?[0]?["hooks"]?[0]?["timeout"], 600)
        XCTAssertEqual(hooks["PostToolUse"]?[0]?["matcher"], "*")
        XCTAssertNil(hooks["PostToolUse"]?[0]?["hooks"]?[0]?["timeout"])

        let stop = try XCTUnwrap(hooks["Stop"]?[0])
        XCTAssertNil(stop["matcher"])
        XCTAssertNil(stop["hooks"]?[0]?["timeout"])

        XCTAssertEqual(settings["statusLine"]?["type"], "command")
        XCTAssertEqual(settings["statusLine"]?["command"], .string("'\(exe)' statusline"))
    }

    func testDataIsValidJSON() throws {
        let data = try SessionSettingsBuilder(hookExecutable: exe).data()
        XCTAssertEqual(try JSONValue.parse(data), SessionSettingsBuilder(hookExecutable: exe).settings())
    }

    func testShellQuote() {
        XCTAssertEqual(SessionSettingsBuilder.shellQuote("/a b/c"), "'/a b/c'")
        XCTAssertEqual(SessionSettingsBuilder.shellQuote("it's"), "'it'\\''s'")
    }

    func testCommandSurvivesAShellWithSpacesAndQuotesInThePath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am dir's \(UUID().uuidString.prefix(4))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("agentmaster-hook")
        try "#!/bin/sh\necho \"ok $1\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SessionSettingsBuilder(hookExecutable: script.path).command("hook")]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "ok hook\n")
    }
}
```

- [ ] **Step 3: Run the test and verify it fails**

Run: `swift test --filter SessionSettingsBuilderTests`
Expected: the build fails. The first error is `cannot find 'SessionSettingsBuilder' in scope`; `Sources/agentmaster-hook` has no sources yet either.

- [ ] **Step 4: Implement the builder and the executable**

`Sources/AgentMasterWire/SessionSettingsBuilder.swift`:

```swift
import Foundation
import AgentMasterCore

/// The per-session `--settings` file. Claude Code merges it with the user's own settings
/// (verified on 2.1.283: user/project hooks keep firing alongside these).
public struct SessionSettingsBuilder {
    public static let hookEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "PermissionRequest", "Notification", "Stop", "SubagentStart", "SubagentStop",
    ]
    static let toolEvents: Set<String> = ["PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest"]
    static let decisionEvents: Set<String> = ["PreToolUse", "PermissionRequest"]
    /// Seconds. The shim gives up at 590 so it always answers before Claude Code kills it.
    static let decisionTimeout = 600

    public let hookExecutable: String

    public init(hookExecutable: String) {
        self.hookExecutable = hookExecutable
    }

    public func command(_ subcommand: String) -> String {
        Self.shellQuote(hookExecutable) + " " + subcommand
    }

    public func settings() -> JSONValue {
        var hooks: [String: JSONValue] = [:]
        for event in Self.hookEvents {
            var hook: [String: JSONValue] = ["type": "command", "command": .string(command("hook"))]
            if Self.decisionEvents.contains(event) { hook["timeout"] = .number(Double(Self.decisionTimeout)) }
            var group: [String: JSONValue] = ["hooks": .array([.object(hook)])]
            if Self.toolEvents.contains(event) { group["matcher"] = "*" }
            hooks[event] = .array([.object(group)])
        }
        return [
            "hooks": .object(hooks),
            "statusLine": ["type": "command", "command": .string(command("statusline")), "padding": 0],
        ]
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(settings())
    }

    public static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
```

`Sources/agentmaster-hook/main.swift`:

```swift
import Foundation
import AgentMasterWire

// Invoked by Claude Code as a hook (`hook`) and as the statusLine command (`statusline`).
// Always exits 0: a failing hook must never disturb the user's session.
let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment

if arguments.first == "settings" {
    let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let data = (try? SessionSettingsBuilder(hookExecutable: executable).data()) ?? Data()
    FileHandle.standardOutput.write(data)
    exit(0)
}

let mode = arguments.first.flatMap(ShimMode.init(rawValue:)) ?? .hook
let input = FileHandle.standardInput.readDataToEndOfFile()
let connector: WireConnector? = environment["AGENTMASTER_SOCKET"].map { UnixWireConnector(path: $0) }
if let output = HookShim.run(mode: mode, input: input, environment: environment, connector: connector) {
    FileHandle.standardOutput.write(Data(output.utf8))
}
exit(0)
```

- [ ] **Step 5: Run the tests, then exercise the binary by hand**

Run: `swift test --filter AgentMasterWireTests`
Expected: all Wire tests PASS.

Run:
```bash
swift build --product agentmaster-hook
BIN="$(swift build --show-bin-path)/agentmaster-hook"
echo '{"hook_event_name":"Stop"}' | "$BIN" hook; echo "exit=$?"
echo '{"model":{"display_name":"Haiku 4.5"},"cwd":"/tmp/x"}' | "$BIN" statusline | cat -v; echo
"$BIN" settings | head -5
```
Expected:
- The first command prints nothing, then `exit=0`. No socket env is set, so it returns immediately.
- The second prints `^[[38;2;90;160;255mHaiku 4.5^[[0m...x...`.
- The third prints the start of the pretty JSON with `"hooks"`.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/AgentMasterWire/SessionSettingsBuilder.swift Sources/agentmaster-hook Tests/AgentMasterWireTests/SessionSettingsBuilderTests.swift
git commit -m "feat(hook): add session settings builder and agentmaster-hook executable"
```

---

### Task 7: HookTranslator (Claude Code hook JSON → SessionEvent)

**Files:**
- Modify: `Package.swift`
- Create: `Sources/AgentMasterBridge/ToolClassifier.swift`, `PatchParser.swift`, `UsageParser.swift`, `HookTranslator.swift`
- Test: `Tests/AgentMasterBridgeTests/TestSupport.swift`, `PatchParserTests.swift`, `HookTranslatorTests.swift`
- The fixtures already exist in `Tests/AgentMasterBridgeTests/Fixtures/`. Do not edit them; they are recordings of real Claude Code 2.1.283 hook input.

**Interfaces:**
- Consumes: `JSONValue`, `SessionEvent`, all models, and `SessionState` (Tasks 1–2).
- Produces:
  - `ToolClassifier.kind(name: String, input: JSONValue) -> ToolKind`
  - `PatchParser.change(fromToolResponse: JSONValue) -> FileChange?`
  - `UsageParser.usage(from: JSONValue) -> Usage?`
  - `struct HookTranslator`, with `init()`, `mutating func translate(_ payload: JSONValue) -> [SessionEvent]`, and `func translate(statusLine: JSONValue) -> [SessionEvent]`

Mapping rules:

| Hook | Events emitted (in order) |
|---|---|
| any payload whose `permission_mode` differs from the last one seen | `permissionModeChanged(mode)` first |
| `SessionStart` | `sessionStarted(session_id, cwd, transcript_path)` |
| `UserPromptSubmit` | `promptSubmitted(prompt)` |
| `PreToolUse` | `toolStarted(ToolCall(tool_use_id, tool_name, ToolClassifier.kind))` |
| `PostToolUse` | tool-specific events (todos / file change / subagent description), then `toolFinished(.success, duration_ms)` |
| `PostToolUseFailure` | `toolFinished(.failure(error), duration_ms)` |
| `PermissionRequest` | `needsAttention("Permission needed: " + kind.title)` |
| `Notification` | `needsAttention(message)`, except `notification_type == "idle_prompt"`, which is ignored |
| `Stop` | `turnFinished(last_assistant_message)` |
| `SubagentStart` / `SubagentStop` | `subagentStarted(agent_id, agent_type)` / `subagentFinished(agent_id)` |
| `SessionEnd` | `sessionEnded(reason)`, except `reason == "clear"`, which is dropped because a new `SessionStart` follows |

The translator keeps the todo list for each Claude session, because TaskCreate and TaskUpdate are deltas. It resets the list when `session_id` changes.

- [ ] **Step 1: Add the Bridge targets**

Replace `Package.swift` with:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentMaster",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agentmaster-hook", targets: ["agentmaster-hook"]),
    ],
    targets: [
        .target(name: "AgentMasterCore"),
        .target(name: "AgentMasterWire", dependencies: ["AgentMasterCore"]),
        .executableTarget(name: "agentmaster-hook", dependencies: ["AgentMasterWire"]),
        .target(name: "AgentMasterBridge", dependencies: ["AgentMasterCore", "AgentMasterWire"]),
        .testTarget(name: "AgentMasterCoreTests", dependencies: ["AgentMasterCore"]),
        .testTarget(name: "AgentMasterWireTests", dependencies: ["AgentMasterWire"]),
        .testTarget(name: "AgentMasterBridgeTests", dependencies: ["AgentMasterBridge"],
                    resources: [.copy("Fixtures")]),
    ]
)
```

- [ ] **Step 2: Write the failing tests**

`Tests/AgentMasterBridgeTests/TestSupport.swift`:

```swift
import Foundation
import XCTest
import AgentMasterCore
@testable import AgentMasterBridge

enum Fixtures {
    /// One hook payload per line, exactly as Claude Code wrote it to the hook's stdin.
    static func payloads(_ name: String) throws -> [JSONValue] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONValue.parse(Data($0.utf8)) }
    }

    static func json(_ name: String) throws -> JSONValue {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONValue.parse(Data(contentsOf: url))
    }

    static func translate(_ name: String) throws -> [SessionEvent] {
        var translator = HookTranslator()
        return try payloads(name).flatMap { translator.translate($0) }
    }
}

/// Thread-safe mutable cell for values shared with background threads in tests.
final class Box<Value> {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&stored)
        lock.unlock()
    }
}

func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}
```

`Tests/AgentMasterBridgeTests/PatchParserTests.swift`:

```swift
import XCTest
import AgentMasterCore
@testable import AgentMasterBridge

final class PatchParserTests: XCTestCase {
    func testParsesStructuredPatchHunks() {
        let response: JSONValue = [
            "filePath": "/p/app.py",
            "structuredPatch": [
                ["oldStart": 1, "oldLines": 2, "newStart": 1, "newLines": 2,
                 "lines": [" def add(a, b):", "-    return a - b", "+    return a + b", "\\ No newline at end of file"]],
                ["oldStart": 10, "oldLines": 0, "newStart": 10, "newLines": 1, "lines": ["+x"]],
            ],
        ]
        XCTAssertEqual(PatchParser.change(fromToolResponse: response), FileChange(path: "/p/app.py", hunks: [
            DiffHunk(oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, lines: [
                DiffLine(kind: .context, text: "def add(a, b):"),
                DiffLine(kind: .removed, text: "    return a - b"),
                DiffLine(kind: .added, text: "    return a + b"),
            ]),
            DiffHunk(oldStart: 10, oldLines: 0, newStart: 10, newLines: 1, lines: [DiffLine(kind: .added, text: "x")]),
        ]))
    }

    func testNewFileBecomesOneAddedHunk() {
        let response: JSONValue = ["type": "create", "filePath": "/p/n.txt", "content": "a\nb\n", "structuredPatch": []]
        XCTAssertEqual(PatchParser.change(fromToolResponse: response), FileChange(path: "/p/n.txt", hunks: [
            DiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 2,
                     lines: [DiffLine(kind: .added, text: "a"), DiffLine(kind: .added, text: "b")]),
        ]))
        let empty: JSONValue = ["type": "create", "filePath": "/p/e.txt", "content": "", "structuredPatch": []]
        XCTAssertEqual(PatchParser.change(fromToolResponse: empty), FileChange(path: "/p/e.txt", hunks: []))
    }

    func testNoPathOrNoOpEditYieldsNothing() {
        XCTAssertNil(PatchParser.change(fromToolResponse: ["structuredPatch": []]))
        XCTAssertNil(PatchParser.change(fromToolResponse: ["type": "update", "filePath": "/p/x", "structuredPatch": []]))
        XCTAssertNil(PatchParser.change(fromToolResponse: "Error: file not found"))
    }
}
```

`Tests/AgentMasterBridgeTests/HookTranslatorTests.swift`:

```swift
import XCTest
import AgentMasterCore
@testable import AgentMasterBridge

final class HookTranslatorTests: XCTestCase {
    // MARK: Recorded sessions

    func testBasicSession() throws {
        let events = try Fixtures.translate("basic-session")
        XCTAssertEqual(Array(events.prefix(6)), [
            .sessionStarted(claudeSessionId: "4235ee52-bbf1-433c-92ef-f861de1d754b", cwd: "/private/tmp/ccspike",
                            transcriptPath: "/Users/shawn/.claude/projects/-private-tmp-ccspike/4235ee52-bbf1-433c-92ef-f861de1d754b.jsonl"),
            .permissionModeChanged("default"),
            .promptSubmitted(text: "Run exactly these two bash commands one after another: 'echo hello' and 'echo forbidden'. Then report what happened."),
            .toolStarted(ToolCall(id: "toolu_bdrk_01SBnNd6wSooPxSFmSyBp6iB", name: "Bash",
                                  kind: .shell(command: "echo hello", description: "Run first command"))),
            .toolFinished(toolUseId: "toolu_bdrk_01SBnNd6wSooPxSFmSyBp6iB", outcome: .success, durationMs: 1674),
            .toolStarted(ToolCall(id: "toolu_bdrk_017ZztthcE5TmhJdqnrZpLoj", name: "Bash",
                                  kind: .shell(command: "echo forbidden", description: "Run second command"))),
        ])
        XCTAssertEqual(events.count, 7)
        guard case .turnFinished(let message) = events.last else { return XCTFail("expected turnFinished") }
        XCTAssertTrue(message?.hasPrefix("**What happened:**") == true)

        var state = SessionState()
        events.forEach { state.apply($0) }
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.runningTools, [], "the hook-denied command never gets a PostToolUse")
    }

    func testTasksEditsFailureAndSubagentSession() throws {
        let start = Date(timeIntervalSince1970: 0)
        let events = try Fixtures.translate("session-tasks-edit-agent")

        let todoLists = events.compactMap { event -> [TodoItem]? in
            if case .todosChanged(let items) = event { return items }
            return nil
        }
        XCTAssertEqual(todoLists, [
            [TodoItem(id: "1", subject: "Fix add", status: .pending)],
            [TodoItem(id: "1", subject: "Fix add", status: .pending), TodoItem(id: "2", subject: "Write notes", status: .pending)],
            [TodoItem(id: "1", subject: "Fix add", status: .inProgress), TodoItem(id: "2", subject: "Write notes", status: .pending)],
            [TodoItem(id: "1", subject: "Fix add", status: .completed), TodoItem(id: "2", subject: "Write notes", status: .pending)],
        ])

        let changes = events.compactMap { event -> FileChange? in
            if case .fileChanged(let change) = event { return change }
            return nil
        }
        XCTAssertEqual(changes, [
            FileChange(path: "/private/tmp/ccspike/app.py", hunks: [
                DiffHunk(oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, lines: [
                    DiffLine(kind: .context, text: "def add(a, b):"),
                    DiffLine(kind: .removed, text: "    return a - b"),
                    DiffLine(kind: .added, text: "    return a + b"),
                ]),
            ]),
            FileChange(path: "/private/tmp/ccspike/notes.txt", hunks: [
                DiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: 1, lines: [DiffLine(kind: .added, text: "done")]),
            ]),
        ])

        XCTAssertTrue(events.contains(.toolFinished(toolUseId: "toolu_bdrk_01BuRwtxFnbdrPTYub8cNnsy",
                                                    outcome: .failure(message: "Exit code 1"), durationMs: 1250)))

        let subagentEvents = events.filter {
            switch $0 {
            case .subagentStarted, .subagentDescribed, .subagentFinished: return true
            default: return false
            }
        }
        XCTAssertEqual(subagentEvents, [
            .subagentStarted(agentId: "abbe8c2524e79903d", agentType: "general-purpose"),
            .subagentDescribed(agentId: "abbe8c2524e79903d", description: "Reply with OK", agentType: nil),
            .subagentFinished(agentId: "abbe8c2524e79903d"),
        ])

        XCTAssertEqual(events.filter { if case .toolStarted = $0 { return true }; return false }.count, 10)
        XCTAssertEqual(events.filter { if case .toolFinished = $0 { return true }; return false }.count, 10)
        XCTAssertEqual(events.filter { if case .permissionModeChanged = $0 { return true }; return false }.count, 1)
        XCTAssertFalse(events.contains { if case .needsAttention = $0 { return true }; return false },
                       "idle_prompt notifications are not attention requests")
        XCTAssertEqual(events.last, .sessionEnded(reason: "prompt_input_exit"))

        var state = SessionState()
        events.forEach { state.apply($0, at: start) }
        XCTAssertEqual(state.status, .ended)
        XCTAssertEqual(state.todos.map(\.status), [.completed, .pending])
        XCTAssertEqual(state.changes.map(\.path), ["/private/tmp/ccspike/app.py", "/private/tmp/ccspike/notes.txt"])
        XCTAssertEqual(state.subagents.count, 1)
        XCTAssertEqual(state.subagents.first?.description, "Reply with OK")
        XCTAssertEqual(state.subagents.first?.finished, true)
        XCTAssertEqual(state.lastTool?.kind, .agent(description: "Reply with OK"))
        XCTAssertEqual(state.lastMessage, "Finished.")
    }

    func testAskUserQuestionSession() throws {
        let events = try Fixtures.translate("ask-user-question")
        let started = events.compactMap { event -> ToolCall? in
            if case .toolStarted(let call) = event { return call }
            return nil
        }
        XCTAssertEqual(started.map(\.name), ["AskUserQuestion", "ToolSearch", "TaskCreate", "Agent"])
        XCTAssertEqual(started[0].kind, .other(name: "AskUserQuestion"))
        XCTAssertEqual(started[3].kind, .agent(description: "Confirm task creation"))
        XCTAssertTrue(events.contains(.todosChanged([TodoItem(id: "1", subject: "Paint in chosen color", status: .pending)])))
        XCTAssertTrue(events.contains(.subagentDescribed(agentId: "aeb5bb9a1a27b5900", description: "Confirm task creation", agentType: nil)))
        XCTAssertEqual(events.last, .subagentFinished(agentId: "aeb5bb9a1a27b5900"))

        var state = SessionState()
        events.forEach { state.apply($0) }
        XCTAssertEqual(state.subagents.map(\.id), ["aeb5bb9a1a27b5900"], "SubagentStop without SubagentStart still lists the agent")
    }

    func testPermissionRequestsBecomeAttention() throws {
        let events = try Fixtures.translate("permission-request")
        let messages = events.compactMap { event -> String? in
            if case .needsAttention(let message) = event { return message }
            return nil
        }
        XCTAssertEqual(messages, ["Permission needed: $ touch /tmp/ccspike/made.txt",
                                  "Permission needed: $ echo forbidden > /tmp/ccspike/f.txt"])
        var state = SessionState()
        events.forEach { state.apply($0) }
        XCTAssertEqual(state.status, .needsAttention)
        XCTAssertEqual(state.attentionMessage, "Permission needed: $ echo forbidden > /tmp/ccspike/f.txt")
    }

    func testStatusLine() throws {
        let translator = HookTranslator()
        XCTAssertEqual(translator.translate(statusLine: try Fixtures.json("statusline")), [
            .usageUpdated(Usage(modelName: "Haiku 4.5", contextUsedPercent: 12, inputTokens: 23361,
                                outputTokens: 753, costUSD: 0.03296375)),
        ])
        XCTAssertEqual(translator.translate(statusLine: ["model": ["display_name": "Opus 5.5"]]), [
            .usageUpdated(Usage(modelName: "Opus 5.5", contextUsedPercent: nil, inputTokens: 0, outputTokens: 0, costUSD: 0)),
        ])
        XCTAssertEqual(translator.translate(statusLine: .null), [])
    }

    // MARK: Rules not covered by the recordings

    func testClearDropsSessionEndAndResetsTodosForTheNewConversation() {
        var translator = HookTranslator()
        var state = SessionState()
        let payloads: [JSONValue] = [
            ["hook_event_name": "SessionStart", "session_id": "A", "cwd": "/p"],
            ["hook_event_name": "PostToolUse", "session_id": "A", "tool_name": "TaskCreate", "tool_use_id": "t1",
             "tool_input": ["subject": "Old"], "tool_response": ["task": ["id": "1", "subject": "Old"]]],
            ["hook_event_name": "SessionEnd", "session_id": "A", "reason": "clear"],
            ["hook_event_name": "SessionStart", "session_id": "B", "cwd": "/p", "source": "clear"],
            ["hook_event_name": "PostToolUse", "session_id": "B", "tool_name": "TaskCreate", "tool_use_id": "t2",
             "tool_input": ["subject": "New"], "tool_response": ["task": ["id": "1", "subject": "New"]]],
        ]
        let perPayload = payloads.map { translator.translate($0) }
        XCTAssertEqual(perPayload[2], [])
        XCTAssertEqual(perPayload[3], [.sessionStarted(claudeSessionId: "B", cwd: "/p", transcriptPath: nil)])
        XCTAssertEqual(perPayload[4].first, .todosChanged([TodoItem(id: "1", subject: "New", status: .pending)]))
        perPayload.joined().forEach { state.apply($0) }
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.claudeSessionId, "B")
        XCTAssertEqual(state.todos, [TodoItem(id: "1", subject: "New", status: .pending)])
    }

    func testOtherSessionEndReasonsEndTheSession() {
        var translator = HookTranslator()
        XCTAssertEqual(translator.translate(["hook_event_name": "SessionEnd", "reason": "logout"]), [.sessionEnded(reason: "logout")])
    }

    func testPermissionModeIsReportedOnlyWhenItChanges() {
        var translator = HookTranslator()
        let prompt: JSONValue = ["hook_event_name": "UserPromptSubmit", "permission_mode": "default", "prompt": "a"]
        XCTAssertEqual(translator.translate(prompt), [.permissionModeChanged("default"), .promptSubmitted(text: "a")])
        XCTAssertEqual(translator.translate(prompt), [.promptSubmitted(text: "a")])
        XCTAssertEqual(translator.translate(["hook_event_name": "UserPromptSubmit", "permission_mode": "plan", "prompt": "b"]),
                       [.permissionModeChanged("plan"), .promptSubmitted(text: "b")])
    }

    func testLegacyTodoWriteReplacesTheList() {
        var translator = HookTranslator()
        let events = translator.translate([
            "hook_event_name": "PostToolUse", "tool_name": "TodoWrite", "tool_use_id": "t1",
            "tool_input": ["todos": [
                ["content": "Read", "status": "completed", "activeForm": "Reading"],
                ["content": "Fix", "status": "in_progress", "activeForm": "Fixing"],
                ["content": "Ship", "status": "pending", "activeForm": "Shipping"],
            ]],
        ])
        XCTAssertEqual(events, [
            .todosChanged([TodoItem(id: "1", subject: "Read", status: .completed),
                           TodoItem(id: "2", subject: "Fix", status: .inProgress),
                           TodoItem(id: "3", subject: "Ship", status: .pending)]),
            .toolFinished(toolUseId: "t1", outcome: .success, durationMs: nil),
        ])
    }

    func testTaskUpdateDeleteSubjectAndUnknownIds() {
        var translator = HookTranslator()
        _ = translator.translate(["hook_event_name": "PostToolUse", "tool_name": "TaskCreate", "tool_use_id": "t1",
                                  "tool_response": ["task": ["id": 1, "subject": "A"]]])
        XCTAssertEqual(translator.translate(["hook_event_name": "PostToolUse", "tool_name": "TaskUpdate", "tool_use_id": "t2",
                                             "tool_input": ["taskId": "1", "subject": "A2"]]).first,
                       .todosChanged([TodoItem(id: "1", subject: "A2", status: .pending)]))
        XCTAssertEqual(translator.translate(["hook_event_name": "PostToolUse", "tool_name": "TaskUpdate", "tool_use_id": "t3",
                                             "tool_input": ["taskId": "7", "status": "in_progress"]]).first,
                       .todosChanged([TodoItem(id: "1", subject: "A2", status: .pending),
                                      TodoItem(id: "7", subject: "Task 7", status: .inProgress)]))
        XCTAssertEqual(translator.translate(["hook_event_name": "PostToolUse", "tool_name": "TaskUpdate", "tool_use_id": "t4",
                                             "tool_input": ["taskId": "1", "status": "deleted"]]).first,
                       .todosChanged([TodoItem(id: "7", subject: "Task 7", status: .inProgress)]))
    }

    func testNonIdleNotificationNeedsAttention() {
        var translator = HookTranslator()
        XCTAssertEqual(translator.translate(["hook_event_name": "Notification", "notification_type": "permission_prompt",
                                             "message": "Claude needs your permission to use Bash"]),
                       [.needsAttention(message: "Claude needs your permission to use Bash")])
        XCTAssertEqual(translator.translate(["hook_event_name": "Notification", "notification_type": "idle_prompt",
                                             "message": "Claude is waiting for your input"]), [])
    }

    func testUnknownEventsAndMalformedPayloadsAreIgnored() {
        var translator = HookTranslator()
        XCTAssertEqual(translator.translate(["hook_event_name": "PreCompact"]), [])
        XCTAssertEqual(translator.translate(["no_event": true]), [])
        XCTAssertEqual(translator.translate("garbage"), [])
        XCTAssertEqual(translator.translate(["hook_event_name": "PreToolUse", "tool_name": "Bash"]), [],
                       "no tool_use_id → nothing to track")
    }

    func testToolClassifier() {
        XCTAssertEqual(ToolClassifier.kind(name: "Read", input: ["file_path": "/a/b.swift"]), .read(path: "/a/b.swift"))
        XCTAssertEqual(ToolClassifier.kind(name: "Grep", input: ["pattern": "TODO"]), .search(pattern: "TODO"))
        XCTAssertEqual(ToolClassifier.kind(name: "Glob", input: ["pattern": "**/*.py"]), .search(pattern: "**/*.py"))
        XCTAssertEqual(ToolClassifier.kind(name: "Edit", input: ["file_path": "/a"]), .edit(path: "/a"))
        XCTAssertEqual(ToolClassifier.kind(name: "MultiEdit", input: ["file_path": "/a"]), .edit(path: "/a"))
        XCTAssertEqual(ToolClassifier.kind(name: "NotebookEdit", input: ["notebook_path": "/n.ipynb"]), .edit(path: "/n.ipynb"))
        XCTAssertEqual(ToolClassifier.kind(name: "Write", input: ["file_path": "/a"]), .write(path: "/a"))
        XCTAssertEqual(ToolClassifier.kind(name: "Bash", input: ["command": "ls"]), .shell(command: "ls", description: nil))
        XCTAssertEqual(ToolClassifier.kind(name: "WebFetch", input: ["url": "https://x.dev"]), .web(target: "https://x.dev"))
        XCTAssertEqual(ToolClassifier.kind(name: "WebSearch", input: ["query": "swift"]), .web(target: "swift"))
        XCTAssertEqual(ToolClassifier.kind(name: "Task", input: ["description": "Review"]), .agent(description: "Review"))
        XCTAssertEqual(ToolClassifier.kind(name: "mcp__x__y", input: nil), .other(name: "mcp__x__y"))
    }
}
```

- [ ] **Step 3: Run the tests and verify they fail**

Run: `swift test --filter AgentMasterBridgeTests`
Expected: the build fails with `cannot find 'HookTranslator' in scope`.

- [ ] **Step 4: Implement the translator pieces**

`Sources/AgentMasterBridge/ToolClassifier.swift`:

```swift
import Foundation
import AgentMasterCore

/// Maps Claude Code tool names to display kinds. Claude Code renames tools occasionally; fix it here only.
public enum ToolClassifier {
    public static func kind(name: String, input: JSONValue) -> ToolKind {
        func string(_ key: String) -> String { input[key]?.stringValue ?? "" }
        switch name {
        case "Read": return .read(path: string("file_path"))
        case "Grep", "Glob": return .search(pattern: string("pattern"))
        case "Edit", "MultiEdit": return .edit(path: string("file_path"))
        case "NotebookEdit": return .edit(path: string("notebook_path"))
        case "Write": return .write(path: string("file_path"))
        case "Bash": return .shell(command: string("command"), description: input["description"]?.stringValue)
        case "WebFetch": return .web(target: string("url"))
        case "WebSearch": return .web(target: string("query"))
        case "Agent", "Task": return .agent(description: string("description"))
        default: return .other(name: name)
        }
    }
}
```

`Sources/AgentMasterBridge/PatchParser.swift`:

```swift
import Foundation
import AgentMasterCore

/// Reads the `structuredPatch` that Edit/MultiEdit/Write report in PostToolUse `tool_response`.
public enum PatchParser {
    public static func change(fromToolResponse response: JSONValue) -> FileChange? {
        guard let path = response["filePath"]?.stringValue else { return nil }
        let hunks = (response["structuredPatch"]?.arrayValue ?? []).compactMap(hunk)
        if !hunks.isEmpty { return FileChange(path: path, hunks: hunks) }
        guard response["type"]?.stringValue == "create" else { return nil }
        let lines = splitLines(response["content"]?.stringValue ?? "")
        guard !lines.isEmpty else { return FileChange(path: path, hunks: []) }
        return FileChange(path: path, hunks: [
            DiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: lines.count,
                     lines: lines.map { DiffLine(kind: .added, text: $0) }),
        ])
    }

    private static func hunk(_ value: JSONValue) -> DiffHunk? {
        guard let rawLines = value["lines"]?.arrayValue else { return nil }
        let lines = rawLines.compactMap { raw -> DiffLine? in
            guard let text = raw.stringValue, let marker = text.first else { return nil }
            let body = String(text.dropFirst())
            switch marker {
            case "+": return DiffLine(kind: .added, text: body)
            case "-": return DiffLine(kind: .removed, text: body)
            case " ": return DiffLine(kind: .context, text: body)
            default: return nil   // "\ No newline at end of file"
            }
        }
        return DiffHunk(oldStart: value["oldStart"]?.intValue ?? 0, oldLines: value["oldLines"]?.intValue ?? 0,
                        newStart: value["newStart"]?.intValue ?? 0, newLines: value["newLines"]?.intValue ?? 0,
                        lines: lines)
    }

    private static func splitLines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
```

`Sources/AgentMasterBridge/UsageParser.swift`:

```swift
import Foundation
import AgentMasterCore

/// Reads the statusLine JSON Claude Code pipes to the statusLine command.
public enum UsageParser {
    public static func usage(from payload: JSONValue) -> Usage? {
        guard payload.objectValue != nil else { return nil }
        let context = payload["context_window"]
        return Usage(
            modelName: payload["model"]?["display_name"]?.stringValue ?? "claude",
            contextUsedPercent: context?["used_percentage"]?.intValue,
            inputTokens: context?["total_input_tokens"]?.intValue ?? 0,
            outputTokens: context?["total_output_tokens"]?.intValue ?? 0,
            costUSD: payload["cost"]?["total_cost_usd"]?.doubleValue ?? 0
        )
    }
}
```

`Sources/AgentMasterBridge/HookTranslator.swift`:

```swift
import Foundation
import AgentMasterCore

/// The only place that understands Claude Code hook payloads. One instance per AgentMaster session.
public struct HookTranslator {
    private var sessionId: String?
    private var permissionMode: String?
    /// TaskCreate/TaskUpdate are deltas, so the full list is rebuilt here.
    private var todos: [TodoItem] = []

    public init() {}

    public mutating func translate(_ payload: JSONValue) -> [SessionEvent] {
        guard let event = payload["hook_event_name"]?.stringValue else { return [] }
        if let id = payload["session_id"]?.stringValue, id != sessionId {
            if sessionId != nil { todos = [] }   // new conversation in the same process (/clear)
            sessionId = id
        }

        var events: [SessionEvent] = []
        if let mode = payload["permission_mode"]?.stringValue, mode != permissionMode {
            permissionMode = mode
            events.append(.permissionModeChanged(mode))
        }

        switch event {
        case "SessionStart":
            events.append(.sessionStarted(claudeSessionId: sessionId ?? "", cwd: payload["cwd"]?.stringValue ?? "",
                                          transcriptPath: payload["transcript_path"]?.stringValue))
        case "UserPromptSubmit":
            events.append(.promptSubmitted(text: payload["prompt"]?.stringValue ?? ""))
        case "PreToolUse":
            if let id = payload["tool_use_id"]?.stringValue, let name = payload["tool_name"]?.stringValue {
                events.append(.toolStarted(ToolCall(id: id, name: name,
                                                    kind: ToolClassifier.kind(name: name, input: payload["tool_input"] ?? .null))))
            }
        case "PostToolUse":
            events += toolResultEvents(payload)
            if let id = payload["tool_use_id"]?.stringValue {
                events.append(.toolFinished(toolUseId: id, outcome: .success, durationMs: payload["duration_ms"]?.intValue))
            }
        case "PostToolUseFailure":
            if let id = payload["tool_use_id"]?.stringValue {
                events.append(.toolFinished(toolUseId: id, outcome: .failure(message: payload["error"]?.stringValue ?? "Failed"),
                                            durationMs: payload["duration_ms"]?.intValue))
            }
        case "PermissionRequest":
            let kind = ToolClassifier.kind(name: payload["tool_name"]?.stringValue ?? "tool", input: payload["tool_input"] ?? .null)
            events.append(.needsAttention(message: "Permission needed: " + kind.title))
        case "Notification":
            if payload["notification_type"]?.stringValue != "idle_prompt" {
                events.append(.needsAttention(message: payload["message"]?.stringValue ?? "Claude needs your attention"))
            }
        case "Stop":
            events.append(.turnFinished(lastMessage: payload["last_assistant_message"]?.stringValue))
        case "SubagentStart":
            if let id = payload["agent_id"]?.stringValue {
                events.append(.subagentStarted(agentId: id, agentType: payload["agent_type"]?.stringValue ?? "agent"))
            }
        case "SubagentStop":
            if let id = payload["agent_id"]?.stringValue {
                events.append(.subagentFinished(agentId: id))
            }
        case "SessionEnd":
            let reason = payload["reason"]?.stringValue
            if reason != "clear" { events.append(.sessionEnded(reason: reason)) }
        default:
            break
        }
        return events
    }

    public func translate(statusLine payload: JSONValue) -> [SessionEvent] {
        UsageParser.usage(from: payload).map { [.usageUpdated($0)] } ?? []
    }

    private mutating func toolResultEvents(_ payload: JSONValue) -> [SessionEvent] {
        let input = payload["tool_input"] ?? .null
        let response = payload["tool_response"] ?? .null
        switch payload["tool_name"]?.stringValue {
        case "TaskCreate":
            guard let id = Self.idString(response["task"]?["id"]) else { return [] }
            let subject = response["task"]?["subject"]?.stringValue ?? input["subject"]?.stringValue ?? ""
            todos.removeAll { $0.id == id }
            todos.append(TodoItem(id: id, subject: subject, status: .pending))
            return [.todosChanged(todos)]

        case "TaskUpdate":
            guard let id = Self.idString(input["taskId"]) ?? Self.idString(response["taskId"]) else { return [] }
            let rawStatus = input["status"]?.stringValue
            let status = rawStatus.flatMap(TodoStatus.init(rawValue:))
            if rawStatus == "deleted" {
                todos.removeAll { $0.id == id }
            } else if let index = todos.firstIndex(where: { $0.id == id }) {
                if let status { todos[index].status = status }
                if let subject = input["subject"]?.stringValue { todos[index].subject = subject }
            } else {
                // Created before AgentMaster was listening; keep a placeholder so progress still shows.
                todos.append(TodoItem(id: id, subject: input["subject"]?.stringValue ?? "Task \(id)", status: status ?? .pending))
            }
            return [.todosChanged(todos)]

        case "TodoWrite":
            let items = input["todos"]?.arrayValue ?? []
            todos = items.enumerated().map { index, item in
                TodoItem(id: "\(index + 1)", subject: item["content"]?.stringValue ?? "",
                         status: item["status"]?.stringValue.flatMap(TodoStatus.init(rawValue:)) ?? .pending)
            }
            return [.todosChanged(todos)]

        case "Edit", "MultiEdit", "Write":
            return PatchParser.change(fromToolResponse: response).map { [.fileChanged($0)] } ?? []

        case "Agent", "Task":
            guard let agentId = response["agentId"]?.stringValue else { return [] }
            let description = response["description"]?.stringValue ?? input["description"]?.stringValue ?? ""
            return [.subagentDescribed(agentId: agentId, description: description, agentType: input["subagent_type"]?.stringValue)]

        default:
            return []
        }
    }

    private static func idString(_ value: JSONValue?) -> String? {
        value?.stringValue ?? value?.intValue.map(String.init)
    }
}
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `swift test --filter AgentMasterBridgeTests`
Expected: all `PatchParserTests` and `HookTranslatorTests` PASS. If a fixture test fails, the recording is the source of truth: fix the translator, never the fixture.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/AgentMasterBridge Tests/AgentMasterBridgeTests
git commit -m "feat(bridge): translate Claude Code hook payloads into SessionEvents"
```

---

### Task 8: Launch environment, claude locator, app paths

**Files:**
- Create: `Sources/AgentMasterBridge/LaunchEnvironment.swift`, `ClaudeLocator.swift`, `AppPaths.swift`
- Test: `Tests/AgentMasterBridgeTests/LaunchEnvironmentTests.swift`, `ClaudeLocatorTests.swift`, `AppPathsTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `LaunchEnvironment` with these members:
    - `static let strippedKeys: Set<String>`
    - `static func sessionEnvironment(base: [String: String], sessionId: String, socketPath: String) -> [String: String]`
    - `static func parseEnvDump(_ data: Data, marker: String) -> [String: String]?`
    - `static func captureLoginShell(shell: String = userShell, timeout: TimeInterval = 5) -> [String: String]?`
    - `static var userShell: String`
  - `ClaudeLocator.locate(environment: [String: String], home: String = NSHomeDirectory(), isExecutable: (String) -> Bool = …) -> String?`
  - `struct AppPaths(supportDirectory:bundleURL:executableURL:)`, with:
    - `static var standard`
    - `var socketPath: String`
    - `func prepare() throws`
    - `func writeSettings(_ data: Data, sessionId: String) throws -> URL`
    - `func hookExecutable(isExecutable: (String) -> Bool = …) -> String?`

- [ ] **Step 1: Write the failing tests**

`Tests/AgentMasterBridgeTests/LaunchEnvironmentTests.swift`:

```swift
import XCTest
@testable import AgentMasterBridge

final class LaunchEnvironmentTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("am-env-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeShell(_ body: String) throws -> String {
        let url = scratch.appendingPathComponent("fake-shell")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testSessionEnvironmentStripsSessionMarkersAndKeepsCredentials() {
        var base = Dictionary(uniqueKeysWithValues: LaunchEnvironment.strippedKeys.map { ($0, "x") })
        base["CMUX_SOCKET_PATH"] = "/tmp/cmux"
        base["AGENTMASTER_SESSION_ID"] = "stale"
        base["AGENTMASTER_EXTRA"] = "stale"
        base["CLAUDE_CODE_USE_BEDROCK"] = "1"
        base["ANTHROPIC_MODEL"] = "opus"
        base["AWS_PROFILE"] = "dev"
        base["AWS_REGION"] = "us-west-2"
        base["PATH"] = "/usr/bin:/bin"
        base["TERM"] = "dumb"

        let env = LaunchEnvironment.sessionEnvironment(base: base, sessionId: "S1", socketPath: "/tmp/a.sock")

        for key in LaunchEnvironment.strippedKeys { XCTAssertNil(env[key], key) }
        XCTAssertNil(env["CMUX_SOCKET_PATH"])
        XCTAssertNil(env["AGENTMASTER_EXTRA"])
        XCTAssertEqual(env["CLAUDE_CODE_USE_BEDROCK"], "1")
        XCTAssertEqual(env["ANTHROPIC_MODEL"], "opus")
        XCTAssertEqual(env["AWS_PROFILE"], "dev")
        XCTAssertEqual(env["AWS_REGION"], "us-west-2")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["AGENTMASTER_SESSION_ID"], "S1")
        XCTAssertEqual(env["AGENTMASTER_SOCKET"], "/tmp/a.sock")
    }

    func testStrippedKeysCoverTheKnownSessionMarkers() {
        XCTAssertTrue(LaunchEnvironment.strippedKeys.isSuperset(of: [
            "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT",
            "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
            "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_PID", "CLAUDE_JOB_DIR", "CLAUDE_EFFORT",
            "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
        ]))
        XCTAssertFalse(LaunchEnvironment.strippedKeys.contains("CLAUDE_CODE_USE_BEDROCK"))
    }

    func testExistingLangIsKept() {
        let env = LaunchEnvironment.sessionEnvironment(base: ["LANG": "zh_CN.UTF-8"], sessionId: "S", socketPath: "/s")
        XCTAssertEqual(env["LANG"], "zh_CN.UTF-8")
    }

    func testParseEnvDumpDropsNoiseBeforeMarkerAndKeepsMultilineValues() {
        let data = Data("Last login: Fri\nA=noise\nMARKA=1\u{0}B=x=y\nz\u{0}junk\u{0}=bad\u{0}".utf8)
        XCTAssertEqual(LaunchEnvironment.parseEnvDump(data, marker: "MARK"), ["A": "1", "B": "x=y\nz"])
        XCTAssertNil(LaunchEnvironment.parseEnvDump(Data("A=1\u{0}".utf8), marker: "MARK"))
    }

    func testCaptureLoginShellIgnoresStartupNoise() throws {
        let shell = try makeShell("""
        echo "Welcome! motd NOISE=1"
        export AM_CAPTURE_PROBE=works
        exec /bin/sh -c "$4"
        """)
        let env = try XCTUnwrap(LaunchEnvironment.captureLoginShell(shell: shell, timeout: 5))
        XCTAssertEqual(env["AM_CAPTURE_PROBE"], "works")
        XCTAssertFalse(env.keys.contains { $0.contains("Welcome") || $0.contains("NOISE") })
    }

    func testCaptureLoginShellGivesUpOnAHangingShell() throws {
        let shell = try makeShell("sleep 20\n")
        let start = Date()
        XCTAssertNil(LaunchEnvironment.captureLoginShell(shell: shell, timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testCaptureRealLoginShell() {
        let env = LaunchEnvironment.captureLoginShell(timeout: 10)
        XCTAssertNotNil(env?["PATH"], "the user's login shell (\(LaunchEnvironment.userShell)) should produce a PATH")
    }
}
```

`Tests/AgentMasterBridgeTests/ClaudeLocatorTests.swift`:

```swift
import XCTest
@testable import AgentMasterBridge

final class ClaudeLocatorTests: XCTestCase {
    func testOverrideWins() {
        let found = ClaudeLocator.locate(environment: ["AGENTMASTER_CLAUDE_PATH": "/opt/claude"], home: "/Users/me",
                                         isExecutable: { _ in true })
        XCTAssertEqual(found, "/opt/claude")
    }

    func testPrefersLocalBinOverPath() {
        let found = ClaudeLocator.locate(environment: ["PATH": "/usr/bin"], home: "/Users/me", isExecutable: {
            ["/Users/me/.local/bin/claude", "/usr/bin/claude"].contains($0)
        })
        XCTAssertEqual(found, "/Users/me/.local/bin/claude")
    }

    func testSkipsTheCmuxWrapper() {
        let found = ClaudeLocator.locate(environment: ["PATH": "/Applications/cmux.app/Contents/Resources/bin:/usr/bin"],
                                         home: "/Users/me", isExecutable: {
            ["/Applications/cmux.app/Contents/Resources/bin/claude", "/usr/bin/claude"].contains($0)
        })
        XCTAssertEqual(found, "/usr/bin/claude")
    }

    func testReturnsNilWhenMissing() {
        XCTAssertNil(ClaudeLocator.locate(environment: ["PATH": "/usr/bin"], home: "/Users/me", isExecutable: { _ in false }))
    }
}
```

`Tests/AgentMasterBridgeTests/AppPathsTests.swift`:

```swift
import XCTest
@testable import AgentMasterBridge

final class AppPathsTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("am-paths-\(UUID().uuidString.prefix(8))")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func paths() -> AppPaths {
        AppPaths(supportDirectory: root.appendingPathComponent("Support Dir"),
                 bundleURL: root.appendingPathComponent("Agent Master.app"),
                 executableURL: root.appendingPathComponent("Agent Master.app/Contents/MacOS/AgentMaster"))
    }

    func testPrepareCreatesAnOwnerOnlyDirectory() throws {
        try paths().prepare()
        let attributes = try FileManager.default.attributesOfItem(atPath: paths().supportDirectory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(paths().socketPath, root.appendingPathComponent("Support Dir/agentmaster.sock").path)
    }

    func testWriteSettingsUsesOneDirectoryPerSession() throws {
        let url = try paths().writeSettings(Data("{}".utf8), sessionId: "S1")
        XCTAssertEqual(url.path, root.appendingPathComponent("Support Dir/sessions/S1/settings.json").path)
        XCTAssertEqual(try Data(contentsOf: url), Data("{}".utf8))
    }

    func testHookExecutablePrefersTheBundledHelper() {
        let helper = root.appendingPathComponent("Agent Master.app/Contents/Helpers/agentmaster-hook").path
        let sibling = root.appendingPathComponent("Agent Master.app/Contents/MacOS/agentmaster-hook").path
        XCTAssertEqual(paths().hookExecutable(isExecutable: { $0 == helper || $0 == sibling }), helper)
        XCTAssertEqual(paths().hookExecutable(isExecutable: { $0 == sibling }), sibling)
        XCTAssertNil(paths().hookExecutable(isExecutable: { _ in false }))
    }

    func testStandardSocketPathFitsInSunPath() {
        XCTAssertLessThan(AppPaths.standard.socketPath.utf8.count, 104)
        XCTAssertTrue(AppPaths.standard.socketPath.hasSuffix("Application Support/AgentMaster/agentmaster.sock"))
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `swift test --filter "LaunchEnvironmentTests|ClaudeLocatorTests|AppPathsTests"`
Expected: the build fails with `cannot find 'LaunchEnvironment' in scope`.

- [ ] **Step 3: Implement**

`Sources/AgentMasterBridge/LaunchEnvironment.swift`:

```swift
import Foundation

public enum LaunchEnvironment {
    /// Markers a parent Claude Code / cmux session leaves behind. Inheriting them makes the child
    /// claude think it is a nested session (e.g. CLAUDE_CODE_CHILD_SESSION stops transcripts being saved).
    public static let strippedKeys: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_PID", "CLAUDE_JOB_DIR", "CLAUDE_EFFORT",
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
    ]
    static let strippedPrefixes = ["CMUX_", "AGENTMASTER_"]

    public static func sessionEnvironment(base: [String: String], sessionId: String, socketPath: String) -> [String: String] {
        var env = base.filter { key, _ in
            !strippedKeys.contains(key) && !strippedPrefixes.contains { key.hasPrefix($0) }
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["AGENTMASTER_SESSION_ID"] = sessionId
        env["AGENTMASTER_SOCKET"] = socketPath
        return env
    }

    /// Parses `env -0` output, ignoring anything the shell printed before `marker`.
    public static func parseEnvDump(_ data: Data, marker: String) -> [String: String]? {
        guard let range = data.range(of: Data(marker.utf8)) else { return nil }
        var env: [String: String] = [:]
        for entry in data[range.upperBound...].split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
            env[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return env
    }

    /// The environment a Terminal window would have (PATH, credentials, proxies…). GUI apps
    /// launched from Finder do not get it. Returns nil if the shell fails or exceeds `timeout`.
    public static func captureLoginShell(shell: String = userShell, timeout: TimeInterval = 5) -> [String: String]? {
        let marker = "__AGENTMASTER_ENV_\(UUID().uuidString)__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '%s' '\(marker)'; /usr/bin/env -0"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return nil
        }

        let output = DataBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard let env = parseEnvDump(output.data, marker: marker), !env.isEmpty else { return nil }
        return env
    }

    public static var userShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}

/// Written by the reader thread before `done.signal()`, read after `done.wait()`.
private final class DataBox {
    var data = Data()
}
```

`Sources/AgentMasterBridge/ClaudeLocator.swift`:

```swift
import Foundation

public enum ClaudeLocator {
    /// Finds the real Claude Code binary. The cmux app ships a same-named wrapper that must be skipped.
    public static func locate(
        environment: [String: String],
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        var candidates: [String] = []
        if let override = environment["AGENTMASTER_CLAUDE_PATH"], !override.isEmpty { candidates.append(override) }
        candidates += [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" }
        return candidates.first { !$0.contains("cmux.app") && isExecutable($0) }
    }
}
```

`Sources/AgentMasterBridge/AppPaths.swift`:

```swift
import Foundation

public struct AppPaths {
    public let supportDirectory: URL
    public let bundleURL: URL
    public let executableURL: URL

    public init(supportDirectory: URL, bundleURL: URL, executableURL: URL) {
        self.supportDirectory = supportDirectory
        self.bundleURL = bundleURL
        self.executableURL = executableURL
    }

    public static var standard: AppPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentMaster")
        return AppPaths(supportDirectory: support, bundleURL: Bundle.main.bundleURL,
                        executableURL: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
    }

    public var socketPath: String {
        supportDirectory.appendingPathComponent("agentmaster.sock").path
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
    }

    public func writeSettings(_ data: Data, sessionId: String) throws -> URL {
        let directory = supportDirectory.appendingPathComponent("sessions").appendingPathComponent(sessionId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// `.app/Contents/Helpers/agentmaster-hook` when bundled; next to the executable under `swift run`.
    public func hookExecutable(isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        [
            bundleURL.appendingPathComponent("Contents/Helpers/agentmaster-hook").path,
            executableURL.deletingLastPathComponent().appendingPathComponent("agentmaster-hook").path,
        ].first(where: isExecutable)
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `swift test --filter "LaunchEnvironmentTests|ClaudeLocatorTests|AppPathsTests"`
Expected: all PASS. `testCaptureRealLoginShell` needs a working login shell. If it fails, run `zsh -l -i -c 'echo ok'` by hand to see what the shell is doing.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentMasterBridge Tests/AgentMasterBridgeTests
git commit -m "feat(bridge): add launch environment capture, claude locator and app paths"
```

---

### Task 9: HookServer

**Files:**
- Create: `Sources/AgentMasterBridge/HookServer.swift`
- Test: `Tests/AgentMasterBridgeTests/HookServerTests.swift`

**Interfaces:**
- Consumes: `UnixSocketListener`, `UnixSocketConnection`, `UnixSocket` (Task 4); `WireCodec`, `WireMessage`, `WireReply` (Task 3); `HookShim` and `UnixWireConnector` (Task 5); `Box` and `waitUntil` (Task 7 TestSupport).
- Produces:
  - `final class HookServer`, with:
    - `typealias Reply = (String?) -> Void`
    - `typealias Handler = (WireMessage, @escaping Reply) -> Void`
    - `init(socketPath:handler:)`, `start() throws`, `stop()`, and `var pendingCount: Int`
  - The handler runs on the server's accept thread, one message at a time, in arrival order. It must not block; hop to the main queue.
  - For `.event` and `.statusline`, calling `Reply` is a no-op. For a `.request`, the first `Reply` call answers the shim; later calls do nothing.

- [ ] **Step 1: Write the failing test**

`Tests/AgentMasterBridgeTests/HookServerTests.swift`:

```swift
import XCTest
import AgentMasterCore
import AgentMasterWire
@testable import AgentMasterBridge

final class HookServerTests: XCTestCase {
    private var path: String!
    private var server: HookServer?

    override func setUp() {
        path = "/tmp/amhs-\(UUID().uuidString.prefix(8)).sock"
    }

    override func tearDown() {
        server?.stop()
        unlink(path)
    }

    private func startServer(_ handler: @escaping HookServer.Handler) throws -> HookServer {
        let server = HookServer(socketPath: path, handler: handler)
        try server.start()
        self.server = server
        return server
    }

    private func shim(_ json: String, timeout: TimeInterval = 5, id: String = UUID().uuidString) -> String? {
        HookShim.run(mode: .hook, input: Data(json.utf8), environment: ["AGENTMASTER_SESSION_ID": "S1"],
                     connector: UnixWireConnector(path: path), decisionTimeout: timeout, makeId: { id })
    }

    func testEventsAreDeliveredInOrder() throws {
        let received = Box<[String]>([])
        _ = try startServer { message, _ in received.mutate { $0.append(message.id) } }
        let ids = (0..<50).map { "e\($0)" }
        for id in ids { XCTAssertNil(shim(#"{"hook_event_name":"PostToolUse"}"#, id: id)) }
        XCTAssertTrue(waitUntil { received.value.count == 50 })
        XCTAssertEqual(received.value, ids)
    }

    func testRequestRoundTripReturnsTheAppsOutput() throws {
        let kinds = Box<[WireKind]>([])
        _ = try startServer { message, reply in
            kinds.mutate { $0.append(message.kind) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { reply(#"{"ok":true}"#) }
        }
        XCTAssertEqual(shim(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#), #"{"ok":true}"#)
        XCTAssertEqual(kinds.value, [.request])
        XCTAssertEqual(server?.pendingCount, 0)
    }

    func testNilReplyMeansHandleInTerminal() throws {
        _ = try startServer { _, reply in reply(nil) }
        XCTAssertNil(shim(#"{"hook_event_name":"PermissionRequest"}"#))
    }

    func testStopReleasesPendingRequestsImmediately() throws {
        let server = try startServer { _, _ in }
        let output = Box<String?>("unset")
        let returned = expectation(description: "shim returned")
        DispatchQueue.global().async {
            output.value = self.shim(#"{"hook_event_name":"PermissionRequest"}"#, timeout: 30)
            returned.fulfill()
        }
        XCTAssertTrue(waitUntil { server.pendingCount == 1 })
        let start = Date()
        server.stop()
        wait(for: [returned], timeout: 3)
        XCTAssertNil(output.value)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(server.pendingCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "stop removes the socket file")
    }

    func testLateAndDuplicateRepliesAreIgnored() throws {
        let saved = Box<HookServer.Reply?>(nil)
        let server = try startServer { _, reply in saved.value = reply }
        XCTAssertNil(shim(#"{"hook_event_name":"PermissionRequest"}"#, timeout: 0.3), "the shim gave up waiting")
        let reply = try XCTUnwrap(saved.value)
        XCTAssertEqual(server.pendingCount, 1)
        reply("late")
        reply("again")
        XCTAssertEqual(server.pendingCount, 0)
        server.stop()
        reply("after stop")
    }

    func testGarbageAndSilentClientsDoNotStopDelivery() throws {
        let received = Box<[String]>([])
        _ = try startServer { message, _ in received.mutate { $0.append(message.id) } }
        let garbage = try UnixSocket.connect(path: path)
        try garbage.write(Data("not json\n".utf8))
        let silent = try UnixSocket.connect(path: path)
        XCTAssertNil(shim(#"{"hook_event_name":"Stop"}"#, id: "after"))
        XCTAssertTrue(waitUntil(timeout: 4) { received.value == ["after"] })
        silent.close()
        garbage.close()
    }

    func testStartReplacesAStaleSocketFile() throws {
        FileManager.default.createFile(atPath: path, contents: Data("stale".utf8))
        let received = Box(0)
        _ = try startServer { _, _ in received.mutate { $0 += 1 } }
        XCTAssertNil(shim(#"{"hook_event_name":"Stop"}"#))
        XCTAssertTrue(waitUntil { received.value == 1 })
    }

    func testShimReturnsImmediatelyWhenTheAppIsNotRunning() {
        let start = Date()
        XCTAssertNil(shim(#"{"hook_event_name":"PermissionRequest"}"#, timeout: 30))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `swift test --filter HookServerTests`
Expected: the build fails with `cannot find 'HookServer' in scope`.

- [ ] **Step 3: Implement the server**

`Sources/AgentMasterBridge/HookServer.swift`:

```swift
import Foundation
import AgentMasterWire

/// Accepts `agentmaster-hook` connections on the app socket. A single accept thread reads each
/// connection's one message itself, so the handler sees hook events in the order Claude Code sent them.
public final class HookServer {
    public typealias Reply = (String?) -> Void
    public typealias Handler = (WireMessage, @escaping Reply) -> Void

    public let socketPath: String
    private let handler: Handler
    private let lock = NSLock()
    private var running = false
    private var pending: [String: UnixSocketConnection] = [:]
    private var finished: DispatchSemaphore?

    public init(socketPath: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    public var pendingCount: Int {
        sync { pending.count }
    }

    public func start() throws {
        let listener = try UnixSocketListener(path: socketPath)
        let finished = DispatchSemaphore(value: 0)
        sync {
            running = true
            self.finished = finished
        }
        let thread = Thread { [self] in
            acceptLoop(listener)
            listener.close()   // closed on this thread so the fd is never closed under a poll()
            finished.signal()
        }
        thread.name = "AgentMaster.HookServer"
        thread.start()
    }

    /// Releases every waiting shim; each prints nothing, so Claude Code falls back to its own UI.
    public func stop() {
        let (connections, finished) = sync { () -> ([UnixSocketConnection], DispatchSemaphore?) in
            running = false
            let connections = Array(pending.values)
            pending = [:]
            let finished = self.finished
            self.finished = nil
            return (connections, finished)
        }
        connections.forEach { $0.close() }
        _ = finished?.wait(timeout: .now() + 2)
    }

    private func acceptLoop(_ listener: UnixSocketListener) {
        while sync({ running }) {
            let accepted: UnixSocketConnection?
            do {
                accepted = try listener.accept(timeout: 0.2)
            } catch {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            guard let connection = accepted else { continue }
            guard let line = try? connection.readLine(timeout: 1),
                  let message = try? WireCodec.decode(WireMessage.self, line: line) else {
                connection.close()
                continue
            }
            guard message.kind == .request else {
                connection.close()
                handler(message) { _ in }
                continue
            }
            let token = UUID().uuidString
            let registered = sync { () -> Bool in
                guard running else { return false }
                pending[token] = connection
                return true
            }
            guard registered else {
                connection.close()
                continue
            }
            handler(message) { [weak self] output in
                self?.reply(token: token, id: message.id, output: output)
            }
        }
    }

    private func reply(token: String, id: String, output: String?) {
        // removeValue makes a second reply, or one after stop(), a no-op.
        guard let connection = sync({ pending.removeValue(forKey: token) }) else { return }
        if let line = try? WireCodec.encodeLine(WireReply(id: id, output: output)) {
            try? connection.write(line)   // the shim may have timed out; SO_NOSIGPIPE makes this safe
        }
        connection.close()
    }

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `swift test --filter AgentMasterBridgeTests`
Expected: all Bridge tests PASS. Run `swift test --filter HookServerTests` three more times. They must pass every time: any flakiness here is a real ordering or locking bug.

- [ ] **Step 5: Commit**

```bash
git add Sources/AgentMasterBridge/HookServer.swift Tests/AgentMasterBridgeTests/HookServerTests.swift
git commit -m "feat(bridge): add HookServer with ordered delivery and safe replies"
```

---

### Task 10: TerminalKit (SwiftTerm wrapper)

**Files:**
- Modify: `Package.swift`
- Create: `Sources/TerminalKit/TerminalLaunch.swift`, `TerminalPalette.swift`, `TerminalSession.swift`, `TerminalHost.swift`
- Test: `Tests/TerminalKitTests/TerminalKitTests.swift`

**Interfaces:**
- Consumes: `Theme` (Task 1).
- Produces:
  - `struct TerminalLaunch(executable:args:environment:currentDirectory:)` with `var environmentStrings: [String]`, sorted `KEY=value`.
  - `extension NSColor { convenience init(hex: String) }`.
  - `enum TerminalPalette`, with `static var ansiColors: [SwiftTerm.Color]` (16 entries) and `@MainActor static func apply(to: TerminalView)`.
  - `@MainActor final class TerminalSession: NSObject`, with:
    - `init(launch: TerminalLaunch)`, which starts the process immediately.
    - `let view: LocalProcessTerminalView`
    - `var onExit: ((Int32?) -> Void)?`
    - `var onTitle: ((String) -> Void)?`
    - `private(set) var isRunning: Bool`
    - `func terminate()`
  - `struct TerminalHost: NSViewRepresentable`, with `init(session: TerminalSession)`.

SwiftTerm notes for 1.18.0, checked against the source:

- The delegate protocol is `LocalProcessTerminalViewDelegate`. `sizeChanged` and `setTerminalTitle` take `source: LocalProcessTerminalView`. `hostCurrentDirectoryUpdate` and `processTerminated` take `source: TerminalView`.
- `exitCode` can be a raw `waitpid` status, so never compare it to a shell exit code.
- SwiftTerm does not use `Bundle.module`. Its Metal shader bundle is optional, so the `.app` does not need it.

- [ ] **Step 1: Add SwiftTerm and the TerminalKit targets**

Replace `Package.swift` with:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentMaster",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "agentmaster-hook", targets: ["agentmaster-hook"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.18.0"),
    ],
    targets: [
        .target(name: "AgentMasterCore"),
        .target(name: "AgentMasterWire", dependencies: ["AgentMasterCore"]),
        .executableTarget(name: "agentmaster-hook", dependencies: ["AgentMasterWire"]),
        .target(name: "AgentMasterBridge", dependencies: ["AgentMasterCore", "AgentMasterWire"]),
        .target(name: "TerminalKit", dependencies: ["AgentMasterCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "AgentMasterCoreTests", dependencies: ["AgentMasterCore"]),
        .testTarget(name: "AgentMasterWireTests", dependencies: ["AgentMasterWire"]),
        .testTarget(name: "AgentMasterBridgeTests", dependencies: ["AgentMasterBridge"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "TerminalKitTests", dependencies: ["TerminalKit"]),
    ]
)
```

Run: `swift package resolve`
Expected: `Package.resolved` pins SwiftTerm at 1.18.0.

- [ ] **Step 2: Write the failing test**

`Tests/TerminalKitTests/TerminalKitTests.swift`:

```swift
import XCTest
import AppKit
import AgentMasterCore
@testable import TerminalKit

@MainActor
final class TerminalKitTests: XCTestCase {
    func testEnvironmentStringsAreSortedKeyValuePairs() {
        let launch = TerminalLaunch(executable: "/bin/sh", args: [], environment: ["B": "2", "A": "x=y"], currentDirectory: "/")
        XCTAssertEqual(launch.environmentStrings, ["A=x=y", "B=2"])
    }

    func testPaletteHasSixteenColorsAndMuseBackground() {
        XCTAssertEqual(TerminalPalette.ansiColors.count, 16)
        let bg = NSColor(hex: Theme.bg).usingColorSpace(.sRGB)!
        XCTAssertEqual(bg.redComponent * 255, 0x1e, accuracy: 0.5)
        XCTAssertEqual(bg.greenComponent * 255, 0x1e, accuracy: 0.5)
        XCTAssertEqual(bg.blueComponent * 255, 0x22, accuracy: 0.5)
    }

    func testSessionRunsTheProcessWithEnvironmentAndDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-term-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.txt")

        let session = TerminalSession(launch: TerminalLaunch(
            executable: "/bin/sh",
            args: ["-c", "printf '%s|%s' \"$AM_PROBE\" \"$(pwd -P)\" > '\(out.path)'"],
            environment: ["AM_PROBE": "hello", "PATH": "/usr/bin:/bin"],
            currentDirectory: dir.path))
        XCTAssertTrue(session.isRunning)
        let exited = expectation(description: "process exited")
        session.onExit = { _ in exited.fulfill() }
        wait(for: [exited], timeout: 10)

        XCTAssertFalse(session.isRunning)
        let real = try XCTUnwrap(realpath(dir.path, nil).map { path -> String in
            defer { free(path) }
            return String(cString: path)
        })
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "hello|\(real)")
    }
}
```

- [ ] **Step 3: Run the test and verify it fails**

Run: `swift test --filter TerminalKitTests`
Expected: the build fails with `cannot find 'TerminalLaunch' in scope`.

- [ ] **Step 4: Implement**

`Sources/TerminalKit/TerminalLaunch.swift`:

```swift
import Foundation

public struct TerminalLaunch: Equatable {
    public var executable: String
    public var args: [String]
    public var environment: [String: String]
    public var currentDirectory: String

    public init(executable: String, args: [String], environment: [String: String], currentDirectory: String) {
        self.executable = executable
        self.args = args
        self.environment = environment
        self.currentDirectory = currentDirectory
    }

    /// SwiftTerm takes the child environment as `KEY=value` strings; sorted for deterministic tests.
    public var environmentStrings: [String] {
        environment.map { "\($0.key)=\($0.value)" }.sorted()
    }
}
```

`Sources/TerminalKit/TerminalPalette.swift`:

```swift
import AppKit
import SwiftTerm
import AgentMasterCore

extension NSColor {
    public convenience init(hex: String) {
        let rgb = Theme.rgb(hex) ?? (r: 0, g: 0, b: 0)
        self.init(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}

public enum TerminalPalette {
    public static var ansiColors: [SwiftTerm.Color] {
        Theme.ansi.map { hex in
            let rgb = Theme.rgb(hex) ?? (r: 0, g: 0, b: 0)
            return SwiftTerm.Color(red8: UInt16(rgb.r), green8: UInt16(rgb.g), blue8: UInt16(rgb.b))
        }
    }

    @MainActor
    public static func apply(to view: TerminalView) {
        view.installColors(ansiColors)
        view.nativeBackgroundColor = NSColor(hex: Theme.bg)
        view.nativeForegroundColor = NSColor(hex: Theme.text)
        view.caretColor = NSColor(hex: Theme.accent)
        view.selectedTextBackgroundColor = NSColor(hex: Theme.selection)
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }
}
```

`Sources/TerminalKit/TerminalSession.swift`:

```swift
import AppKit
import SwiftTerm

/// One pseudo-terminal running one process. The view outlives SwiftUI view updates, so switching
/// sessions in the UI never restarts the process.
@MainActor
public final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    public let view: LocalProcessTerminalView
    public var onExit: ((Int32?) -> Void)?
    public var onTitle: ((String) -> Void)?
    public private(set) var isRunning = false

    public init(launch: TerminalLaunch) {
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        super.init()
        TerminalPalette.apply(to: view)
        view.processDelegate = self
        view.startProcess(executable: launch.executable, args: launch.args, environment: launch.environmentStrings,
                          execName: nil, currentDirectory: launch.currentDirectory)
        isRunning = true
    }

    public func terminate() {
        guard isRunning else { return }
        view.terminate()
    }

    private func finished(_ exitCode: Int32?) {
        guard isRunning else { return }
        isRunning = false
        onExit?(exitCode)
    }

    nonisolated public func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated public func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onMain { $0.onTitle?(title) }
    }

    nonisolated public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated public func processTerminated(source: TerminalView, exitCode: Int32?) {
        onMain { $0.finished(exitCode) }
    }

    /// SwiftTerm calls the delegate on the main queue today; hop explicitly in case that changes.
    nonisolated private func onMain(_ body: @escaping @MainActor (TerminalSession) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(self) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body(self) } }
        }
    }
}
```

`Sources/TerminalKit/TerminalHost.swift`:

```swift
import SwiftUI
import SwiftTerm

public struct TerminalHost: NSViewRepresentable {
    public let session: TerminalSession

    public init(session: TerminalSession) {
        self.session = session
    }

    public func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = session.view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    public func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
```

- [ ] **Step 5: Run the test and verify it passes**

Run: `swift test --filter TerminalKitTests`
Expected: 3 tests PASS. If `testSessionRunsTheProcessWithEnvironmentAndDirectory` times out, check that `onExit` is being called on the main thread. The test waits on the main run loop, so `DispatchQueue.main.async` work still gets delivered.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Package.resolved Sources/TerminalKit Tests/TerminalKitTests
git commit -m "feat(terminal): wrap SwiftTerm with Muse palette and session lifecycle"
```

---

### Task 11: AgentMasterUI (panels, sidebar, header)

**Files:**
- Modify: `Package.swift`
- Create in `Sources/AgentMasterUI/`: `Style.swift`, `StatusGlyph.swift`, `PanelSection.swift`, `TodoPanel.swift`, `AgentsPanel.swift`, `ChangesPanel.swift`, `UsagePanel.swift`, `SidePanel.swift`, `SessionSidebar.swift`, `SessionHeader.swift`, `PreviewData.swift`
- Test: `Tests/AgentMasterUITests/AgentMasterUITests.swift`

**Interfaces:**
- Consumes: `SessionState`, `SessionStatus`, `TodoItem`, `TodoStatus`, `SubagentInfo`, `FileChange`, `DiffHunk`, `DiffLine`, `Usage`, `TokenFormat`, `DurationFormat`, and `Theme` (Tasks 1–2).
- Produces:
  - Style: `Color(hex:)`, `Palette.{bg,text,muted,faint,accent,selection,teal,success,error,warning,diffAddBg,diffAddFg,diffDelBg,diffDelFg}`, `MuseFont.{body,small,heading}`, `HairLine`, and `EmptyHint(_:)`.
  - `StatusGlyph.symbol(for: SessionStatus)`, `.colorHex(for: SessionStatus)`, `.symbol(for: TodoStatus)`, and `.colorHex(for: TodoStatus)`.
  - Panels:
    - `SidePanel(state: SessionState)`
    - `TodoPanel(todos:)`
    - `AgentsPanel(subagents:mainActive:)`
    - `ChangesPanel(changes:)` and `DiffView(change:)`
    - `UsagePanel(usage:permissionMode:)`
  - Sidebar:
    - `struct SessionRowModel: Identifiable, Equatable { id, projectPath, title, status, createdAt }`
    - `struct SessionGroup: Identifiable, Equatable { id (projectPath), name, rows }`
    - `SessionGrouping.group(_ rows: [SessionRowModel]) -> [SessionGroup]`. Groups are ordered by their newest row, newest first, and rows within a group are also newest first.
    - `SessionSidebar(rows:selection: Binding<String?>, onNew: () -> Void)`
  - `SessionHeader(project:model:mode:needsAttention:)` and `PreviewData.state`.

UI code imports only `AgentMasterCore`, per spec §7: UI → Core.

- [ ] **Step 1: Add the UI targets**

In `Package.swift`, add these two lines to `targets:`:

```swift
        .target(name: "AgentMasterUI", dependencies: ["AgentMasterCore"]),
        .testTarget(name: "AgentMasterUITests", dependencies: ["AgentMasterUI"]),
```

- [ ] **Step 2: Write the failing test**

`Tests/AgentMasterUITests/AgentMasterUITests.swift`:

```swift
import XCTest
import AgentMasterCore
@testable import AgentMasterUI

final class AgentMasterUITests: XCTestCase {
    func testSessionGlyphs() {
        XCTAssertEqual(StatusGlyph.symbol(for: SessionStatus.running), "◈")
        XCTAssertEqual(StatusGlyph.symbol(for: SessionStatus.starting), "◈")
        XCTAssertEqual(StatusGlyph.symbol(for: SessionStatus.needsAttention), "◆")
        XCTAssertEqual(StatusGlyph.symbol(for: SessionStatus.idle), "◇")
        XCTAssertEqual(StatusGlyph.symbol(for: SessionStatus.ended), "✓")
        XCTAssertEqual(StatusGlyph.colorHex(for: SessionStatus.needsAttention), Theme.accent)
        XCTAssertEqual(StatusGlyph.colorHex(for: SessionStatus.running), Theme.teal)
        XCTAssertEqual(StatusGlyph.colorHex(for: SessionStatus.idle), Theme.muted)
        XCTAssertEqual(StatusGlyph.colorHex(for: SessionStatus.ended), Theme.success)
    }

    func testTodoGlyphs() {
        XCTAssertEqual(StatusGlyph.symbol(for: TodoStatus.completed), "✓")
        XCTAssertEqual(StatusGlyph.symbol(for: TodoStatus.inProgress), "◆")
        XCTAssertEqual(StatusGlyph.symbol(for: TodoStatus.pending), "◇")
        XCTAssertEqual(StatusGlyph.colorHex(for: TodoStatus.completed), Theme.success)
        XCTAssertEqual(StatusGlyph.colorHex(for: TodoStatus.inProgress), Theme.teal)
        XCTAssertEqual(StatusGlyph.colorHex(for: TodoStatus.pending), Theme.muted)
    }

    func testGroupingOrdersProjectsAndRowsNewestFirst() {
        func row(_ id: String, _ project: String, _ minute: Double) -> SessionRowModel {
            SessionRowModel(id: id, projectPath: project, title: id, status: .idle,
                            createdAt: Date(timeIntervalSince1970: minute * 60))
        }
        let groups = SessionGrouping.group([
            row("a1", "/w/alpha", 1), row("b1", "/w/beta", 2), row("a2", "/w/alpha", 3), row("c1", "/x/alpha", 0),
        ])
        XCTAssertEqual(groups.map(\.id), ["/w/alpha", "/w/beta", "/x/alpha"])
        XCTAssertEqual(groups.map(\.name), ["alpha", "beta", "alpha"])
        XCTAssertEqual(groups[0].rows.map(\.id), ["a2", "a1"])
        XCTAssertEqual(SessionGrouping.group([]), [])
    }

    func testPreviewStateExercisesEveryPanel() {
        let state = PreviewData.state
        XCTAssertFalse(state.todos.isEmpty)
        XCTAssertFalse(state.subagents.isEmpty)
        XCTAssertFalse(state.changes.isEmpty)
        XCTAssertNotNil(state.usage)
    }
}
```

- [ ] **Step 3: Run the test and verify it fails**

Run: `swift test --filter AgentMasterUITests`
Expected: the build fails with `cannot find 'StatusGlyph' in scope`.

- [ ] **Step 4: Implement the style and glyphs**

`Sources/AgentMasterUI/Style.swift`:

```swift
import SwiftUI
import AgentMasterCore

extension Color {
    public init(hex: String) {
        let rgb = Theme.rgb(hex) ?? (r: 0, g: 0, b: 0)
        self.init(.sRGB, red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }
}

public enum Palette {
    public static let bg = Color(hex: Theme.bg)
    public static let text = Color(hex: Theme.text)
    public static let muted = Color(hex: Theme.muted)
    public static let faint = Color(hex: Theme.faint)
    public static let accent = Color(hex: Theme.accent)
    public static let selection = Color(hex: Theme.selection)
    public static let teal = Color(hex: Theme.teal)
    public static let success = Color(hex: Theme.success)
    public static let error = Color(hex: Theme.error)
    public static let warning = Color(hex: Theme.warning)
    public static let diffAddBg = Color(hex: Theme.diffAddBg)
    public static let diffAddFg = Color(hex: Theme.diffAddFg)
    public static let diffDelBg = Color(hex: Theme.diffDelBg)
    public static let diffDelFg = Color(hex: Theme.diffDelFg)
}

public enum MuseFont {
    public static let body = Font.system(size: 13, design: .monospaced)
    public static let small = Font.system(size: 11, design: .monospaced)
    public static let heading = Font.system(size: 11, weight: .bold, design: .monospaced)
}

public struct HairLine: View {
    let color: Color

    public init(color: Color = Palette.faint) {
        self.color = color
    }

    public var body: some View {
        Rectangle().fill(color).frame(height: 1)
    }
}

public struct EmptyHint: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text).font(MuseFont.small).foregroundStyle(Palette.faint)
    }
}
```

`Sources/AgentMasterUI/StatusGlyph.swift`:

```swift
import SwiftUI
import AgentMasterCore

public enum StatusGlyph {
    public static func symbol(for status: SessionStatus) -> String {
        switch status {
        case .starting, .running: return "◈"
        case .needsAttention: return "◆"
        case .idle: return "◇"
        case .ended: return "✓"
        }
    }

    public static func colorHex(for status: SessionStatus) -> String {
        switch status {
        case .starting: return Theme.faint
        case .running: return Theme.teal
        case .needsAttention: return Theme.accent
        case .idle: return Theme.muted
        case .ended: return Theme.success
        }
    }

    public static func symbol(for status: TodoStatus) -> String {
        switch status {
        case .completed: return "✓"
        case .inProgress: return "◆"
        case .pending: return "◇"
        }
    }

    public static func colorHex(for status: TodoStatus) -> String {
        switch status {
        case .completed: return Theme.success
        case .inProgress: return Theme.teal
        case .pending: return Theme.muted
        }
    }
}
```

`Sources/AgentMasterUI/PanelSection.swift`:

```swift
import SwiftUI

/// Collapsible right-panel block with an uppercase bold muted title (spec §4.5).
public struct PanelSection<Content: View>: View {
    let title: String
    let content: Content
    @State private var expanded = true

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(title.uppercased()).font(MuseFont.heading).foregroundStyle(Palette.muted)
                    Spacer()
                    Text(expanded ? "▾" : "▸").font(MuseFont.small).foregroundStyle(Palette.faint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { content }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
```

- [ ] **Step 5: Implement the panels**

`Sources/AgentMasterUI/TodoPanel.swift`:

```swift
import SwiftUI
import AgentMasterCore

public struct TodoPanel: View {
    let todos: [TodoItem]

    public init(todos: [TodoItem]) {
        self.todos = todos
    }

    public var body: some View {
        if todos.isEmpty {
            EmptyHint("No tasks yet")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(todos) { todo in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(StatusGlyph.symbol(for: todo.status)).foregroundStyle(Color(hex: StatusGlyph.colorHex(for: todo.status)))
                        Text(todo.subject)
                            .foregroundStyle(todo.status == .completed ? Palette.muted : Palette.text)
                            .lineLimit(2)
                    }
                    .font(MuseFont.body)
                }
            }
        }
    }
}
```

`Sources/AgentMasterUI/AgentsPanel.swift`:

```swift
import SwiftUI
import AgentMasterCore

public struct AgentsPanel: View {
    let subagents: [SubagentInfo]
    let mainActive: Bool

    public init(subagents: [SubagentInfo], mainActive: Bool) {
        self.subagents = subagents
        self.mainActive = mainActive
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("main").bold().foregroundStyle(Palette.accent)
                    if mainActive { Text("◈").foregroundStyle(Palette.teal) }
                }
                ForEach(subagents) { agent in
                    HStack(spacing: 6) {
                        Text("└").foregroundStyle(Palette.faint)
                        Text(agent.finished ? "✓" : "•")
                            .foregroundStyle(agent.finished ? Palette.success : Palette.teal)
                        Text(agent.description ?? agent.type)
                            .foregroundStyle(agent.finished ? Palette.muted : Palette.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(DurationFormat.short(agent.elapsed(at: context.date))).foregroundStyle(Palette.faint)
                    }
                }
            }
            .font(MuseFont.body)
        }
    }
}
```

`Sources/AgentMasterUI/ChangesPanel.swift`:

```swift
import SwiftUI
import AgentMasterCore

public struct ChangesPanel: View {
    let changes: [FileChange]
    @State private var expanded: Set<String> = []

    public init(changes: [FileChange]) {
        self.changes = changes
    }

    public var body: some View {
        if changes.isEmpty {
            EmptyHint("No changes yet")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(changes) { change in
                    Button {
                        if expanded.contains(change.id) { expanded.remove(change.id) } else { expanded.insert(change.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Text((change.path as NSString).lastPathComponent).foregroundStyle(Palette.text).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("+\(change.added)").foregroundStyle(Palette.success)
                            Text("−\(change.removed)").foregroundStyle(Palette.error)
                            Text(expanded.contains(change.id) ? "⌄" : "›").foregroundStyle(Palette.faint)
                        }
                        .font(MuseFont.body)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(change.path)
                    if expanded.contains(change.id) { DiffView(change: change) }
                }
            }
        }
    }
}

/// Inline unified diff. Syntax highlighting is M5.
public struct DiffView: View {
    let change: FileChange

    public init(change: FileChange) {
        self.change = change
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(change.hunks.enumerated()), id: \.offset) { _, hunk in
                    Text("@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@")
                        .foregroundStyle(Palette.faint)
                        .padding(.vertical, 2)
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        DiffLineRow(line: line)
                    }
                }
            }
            .font(MuseFont.small)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).stroke(Palette.faint, lineWidth: 1))
    }
}

struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        let (marker, foreground, background): (String, Color, Color) = {
            switch line.kind {
            case .added: return ("+", Palette.diffAddFg, Palette.diffAddBg)
            case .removed: return ("-", Palette.diffDelFg, Palette.diffDelBg)
            case .context: return (" ", Palette.muted, .clear)
            }
        }()
        Text(marker + line.text)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
    }
}
```

`Sources/AgentMasterUI/UsagePanel.swift`:

```swift
import SwiftUI
import AgentMasterCore

public struct UsagePanel: View {
    let usage: Usage?
    let permissionMode: String?

    public init(usage: Usage?, permissionMode: String?) {
        self.usage = usage
        self.permissionMode = permissionMode
    }

    public var body: some View {
        if let usage {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("ctx \(usage.contextUsedPercent.map { "\($0)%" } ?? "–")").foregroundStyle(Palette.text)
                    Text("·").foregroundStyle(Palette.faint)
                    Text(String(format: "$%.2f", usage.costUSD)).foregroundStyle(Palette.text)
                }
                Text("↑\(TokenFormat.short(usage.inputTokens)) ↓\(TokenFormat.short(usage.outputTokens))")
                    .foregroundStyle(Palette.muted)
                Text([usage.modelName, permissionMode].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(Palette.muted)
            }
            .font(MuseFont.body)
        } else {
            EmptyHint("Waiting for first status update")
        }
    }
}
```

`Sources/AgentMasterUI/SidePanel.swift`:

```swift
import SwiftUI
import AgentMasterCore

public struct SidePanel: View {
    let state: SessionState

    public init(state: SessionState) {
        self.state = state
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PanelSection("Todo") { TodoPanel(todos: state.todos) }
                HairLine()
                PanelSection("Agents") { AgentsPanel(subagents: state.subagents, mainActive: state.status == .running) }
                HairLine()
                PanelSection("Changes") { ChangesPanel(changes: state.changes) }
                HairLine()
                PanelSection("Usage") { UsagePanel(usage: state.usage, permissionMode: state.permissionMode) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.bg)
    }
}

#Preview {
    SidePanel(state: PreviewData.state).frame(width: 320, height: 700).preferredColorScheme(.dark)
}
```

- [ ] **Step 6: Implement the sidebar, header and preview data**

`Sources/AgentMasterUI/SessionSidebar.swift`:

```swift
import SwiftUI
import AgentMasterCore

public struct SessionRowModel: Identifiable, Equatable {
    public let id: String
    public let projectPath: String
    public let title: String
    public let status: SessionStatus
    public let createdAt: Date

    public init(id: String, projectPath: String, title: String, status: SessionStatus, createdAt: Date) {
        self.id = id
        self.projectPath = projectPath
        self.title = title
        self.status = status
        self.createdAt = createdAt
    }
}

public struct SessionGroup: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let rows: [SessionRowModel]
}

public enum SessionGrouping {
    public static func group(_ rows: [SessionRowModel]) -> [SessionGroup] {
        Dictionary(grouping: rows, by: \.projectPath)
            .map { path, rows in
                SessionGroup(id: path, name: (path as NSString).lastPathComponent,
                             rows: rows.sorted { $0.createdAt > $1.createdAt })
            }
            .sorted { $0.rows[0].createdAt > $1.rows[0].createdAt }
    }
}

public struct SessionSidebar: View {
    let rows: [SessionRowModel]
    @Binding var selection: String?
    let onNew: () -> Void

    public init(rows: [SessionRowModel], selection: Binding<String?>, onNew: @escaping () -> Void) {
        self.rows = rows
        self._selection = selection
        self.onNew = onNew
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(SessionGrouping.group(rows)) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("▾ " + group.name).font(MuseFont.heading).foregroundStyle(Palette.muted)
                                .help(group.id)
                            ForEach(group.rows) { row in
                                SessionRow(row: row, selected: row.id == selection)
                                    .onTapGesture { selection = row.id }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 28)   // clears the traffic lights in the hidden title bar
            }
            HairLine()
            Button(action: onNew) {
                Text("＋ New session").font(MuseFont.body).foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .background(Palette.bg)
    }
}

struct SessionRow: View {
    let row: SessionRowModel
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(StatusGlyph.symbol(for: row.status)).foregroundStyle(Color(hex: StatusGlyph.colorHex(for: row.status)))
            Text(row.title).foregroundStyle(selected ? Palette.text : Palette.muted).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(MuseFont.body)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Palette.selection : .clear))
        .contentShape(Rectangle())
    }
}
```

`Sources/AgentMasterUI/SessionHeader.swift`:

```swift
import SwiftUI

/// `AgentMaster ▸ <project>` on the left, `model · mode` on the right; the rule turns accent when waiting on you.
public struct SessionHeader: View {
    let project: String
    let model: String?
    let mode: String?
    let needsAttention: Bool

    public init(project: String, model: String?, mode: String?, needsAttention: Bool) {
        self.project = project
        self.model = model
        self.mode = mode
        self.needsAttention = needsAttention
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("AgentMaster").foregroundStyle(Palette.muted)
                Text("▸").foregroundStyle(Palette.faint)
                Text(project).foregroundStyle(Palette.text)
                Spacer()
                Text([model, mode].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(Palette.muted)
            }
            .font(MuseFont.small)
            .padding(.horizontal, 12)
            .frame(height: 28)
            HairLine(color: needsAttention ? Palette.accent : Palette.faint)
        }
        .background(Palette.bg)
    }
}
```

`Sources/AgentMasterUI/PreviewData.swift`:

```swift
import Foundation
import AgentMasterCore

public enum PreviewData {
    public static var state: SessionState {
        let start = Date().addingTimeInterval(-42)
        var state = SessionState()
        let events: [SessionEvent] = [
            .sessionStarted(claudeSessionId: "preview", cwd: "/Users/me/my-proj", transcriptPath: nil),
            .permissionModeChanged("default"),
            .promptSubmitted(text: "Fix add()"),
            .todosChanged([
                TodoItem(id: "1", subject: "Read app.py", status: .completed),
                TodoItem(id: "2", subject: "Fix add()", status: .inProgress),
                TodoItem(id: "3", subject: "Run script", status: .pending),
            ]),
            .subagentStarted(agentId: "a1", agentType: "general-purpose"),
            .subagentDescribed(agentId: "a1", description: "reviewer", agentType: nil),
            .fileChanged(FileChange(path: "/Users/me/my-proj/app.py", hunks: [
                DiffHunk(oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, lines: [
                    DiffLine(kind: .context, text: "def add(a, b):"),
                    DiffLine(kind: .removed, text: "    return a - b"),
                    DiffLine(kind: .added, text: "    return a + b"),
                ]),
            ])),
            .usageUpdated(Usage(modelName: "Opus 5.5", contextUsedPercent: 34, inputTokens: 48_200,
                                outputTokens: 1_600, costUSD: 0.12)),
        ]
        events.forEach { state.apply($0, at: start) }
        return state
    }
}
```

- [ ] **Step 7: Run the tests and verify they pass**

Run: `swift test --filter AgentMasterUITests`
Expected: 4 tests PASS. Then open `Sources/AgentMasterUI/SidePanel.swift` in Xcode (`xed .`) and confirm the `#Preview` renders all four sections in dark colors.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/AgentMasterUI Tests/AgentMasterUITests
git commit -m "feat(ui): add Muse side panels, session sidebar and header"
```

---

### Task 12: App assembly (M1 + M2 end to end)

**Files:**
- Modify: `Package.swift` (final form)
- Create in `Sources/AgentMaster/`: `AgentMasterApp.swift`, `AppModel.swift`, `SessionController.swift`, `MainWindow.swift`
- Create: `scripts/bundle.sh`

**Interfaces:**
- Consumes everything above. In particular:
  - `HookServer(socketPath:handler:)`
  - `HookTranslator`
  - `LaunchEnvironment.sessionEnvironment` and `captureLoginShell`
  - `ClaudeLocator.locate`
  - `AppPaths.standard`, `prepare`, `writeSettings`, and `hookExecutable`
  - `SessionSettingsBuilder(hookExecutable:).data()`
  - `TerminalSession` and `TerminalHost`
  - `SidePanel`, `SessionSidebar`, `SessionRowModel`, and `SessionHeader`
- Produces: the `AgentMaster` executable and `build/AgentMaster.app`.

There are no unit tests for this task. It is glue code, verified by the manual checklist in Step 6 and by the smoke script in Task 13.

- [ ] **Step 1: Final Package.swift**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgentMaster",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentMaster", targets: ["AgentMaster"]),
        .executable(name: "agentmaster-hook", targets: ["agentmaster-hook"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.18.0"),
    ],
    targets: [
        .target(name: "AgentMasterCore"),
        .target(name: "AgentMasterWire", dependencies: ["AgentMasterCore"]),
        .executableTarget(name: "agentmaster-hook", dependencies: ["AgentMasterWire"]),
        .target(name: "AgentMasterBridge", dependencies: ["AgentMasterCore", "AgentMasterWire"]),
        .target(name: "TerminalKit", dependencies: ["AgentMasterCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .target(name: "AgentMasterUI", dependencies: ["AgentMasterCore"]),
        .executableTarget(name: "AgentMaster",
                          dependencies: ["AgentMasterCore", "AgentMasterWire", "AgentMasterBridge", "TerminalKit", "AgentMasterUI"]),
        .testTarget(name: "AgentMasterCoreTests", dependencies: ["AgentMasterCore"]),
        .testTarget(name: "AgentMasterWireTests", dependencies: ["AgentMasterWire"]),
        .testTarget(name: "AgentMasterBridgeTests", dependencies: ["AgentMasterBridge"],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "TerminalKitTests", dependencies: ["TerminalKit"]),
        .testTarget(name: "AgentMasterUITests", dependencies: ["AgentMasterUI"]),
    ]
)
```

- [ ] **Step 2: SessionController**

`Sources/AgentMaster/SessionController.swift`:

```swift
import Foundation
import Observation
import AgentMasterCore
import AgentMasterBridge
import AgentMasterUI
import TerminalKit

/// One AgentMaster session: one PTY running claude, its translator and its reduced state.
@MainActor
@Observable
final class SessionController: Identifiable {
    let id: String
    let projectPath: String
    let createdAt = Date()
    private(set) var state = SessionState()
    private(set) var title: String?
    @ObservationIgnored let terminal: TerminalSession
    @ObservationIgnored private var translator = HookTranslator()

    init(id: String, projectPath: String, launch: TerminalLaunch) {
        self.id = id
        self.projectPath = projectPath
        terminal = TerminalSession(launch: launch)
        terminal.onExit = { [weak self] _ in
            guard let self, self.state.status != .ended else { return }
            self.apply([.sessionEnded(reason: "process_exit")])
        }
        terminal.onTitle = { [weak self] title in
            self?.title = title.isEmpty ? nil : title
        }
    }

    func receive(hook payload: JSONValue) {
        apply(translator.translate(payload))
    }

    func receive(statusLine payload: JSONValue) {
        apply(translator.translate(statusLine: payload))
    }

    private func apply(_ events: [SessionEvent]) {
        let now = Date()
        for event in events { state.apply(event, at: now) }
    }

    var projectName: String {
        (projectPath as NSString).lastPathComponent
    }

    var row: SessionRowModel {
        SessionRowModel(id: id, projectPath: projectPath, title: title ?? "Session \(id.prefix(4))",
                        status: state.status, createdAt: createdAt)
    }
}
```

- [ ] **Step 3: AppModel**

`Sources/AgentMaster/AppModel.swift`:

```swift
import AppKit
import Observation
import AgentMasterCore
import AgentMasterWire
import AgentMasterBridge
import TerminalKit

enum AppError: LocalizedError {
    case claudeNotFound
    case hookHelperMissing

    var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "Claude Code not found. Install it (~/.local/bin/claude) or set AGENTMASTER_CLAUDE_PATH."
        case .hookHelperMissing:
            return "agentmaster-hook is missing. Build with scripts/bundle.sh, or `swift build` so it sits next to the app binary."
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var sessions: [SessionController] = []
    var selectedId: String?
    var errorMessage: String?

    @ObservationIgnored private let paths = AppPaths.standard
    @ObservationIgnored private var server: HookServer?
    @ObservationIgnored private var baseEnvironment: [String: String]?
    @ObservationIgnored private var environmentTask: Task<[String: String], Never>?

    init() {
        // The login shell can take seconds; start it now so the first session does not wait.
        environmentTask = Task.detached {
            LaunchEnvironment.captureLoginShell() ?? ProcessInfo.processInfo.environment
        }
        do {
            try paths.prepare()
            let server = HookServer(socketPath: paths.socketPath) { message, reply in
                // M3 replaces this with the native approval / question overlays.
                if message.kind == .request { reply(nil) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.route(message) }
                }
            }
            try server.start()
            self.server = server
        } catch {
            errorMessage = "Could not start the hook server: \(error)"
        }
    }

    var selected: SessionController? {
        sessions.first { $0.id == selectedId }
    }

    func chooseProjectAndStart() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start Session"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await startSession(in: url.path) }
    }

    func startSession(in projectPath: String) async {
        do {
            let base = await environment()
            guard let claude = ClaudeLocator.locate(environment: base) else { throw AppError.claudeNotFound }
            guard let hook = paths.hookExecutable() else { throw AppError.hookHelperMissing }
            let id = UUID().uuidString
            let settings = try paths.writeSettings(SessionSettingsBuilder(hookExecutable: hook).data(), sessionId: id)
            let launch = TerminalLaunch(
                executable: claude,
                args: ["--settings", settings.path],
                environment: LaunchEnvironment.sessionEnvironment(base: base, sessionId: id, socketPath: paths.socketPath),
                currentDirectory: projectPath)
            let session = SessionController(id: id, projectPath: projectPath, launch: launch)
            sessions.append(session)
            selectedId = id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func shutdown() {
        server?.stop()
        server = nil
        sessions.forEach { $0.terminal.terminate() }
    }

    private func environment() async -> [String: String] {
        if let baseEnvironment { return baseEnvironment }
        let captured = await environmentTask?.value ?? ProcessInfo.processInfo.environment
        baseEnvironment = captured
        return captured
    }

    private func route(_ message: WireMessage) {
        guard let session = sessions.first(where: { $0.id == message.sessionId }) else { return }
        switch message.kind {
        case .statusline: session.receive(statusLine: message.payload)
        case .event, .request: session.receive(hook: message.payload)
        }
    }
}
```

- [ ] **Step 4: Window and app entry**

`Sources/AgentMaster/MainWindow.swift`:

```swift
import SwiftUI
import AgentMasterUI
import TerminalKit

struct MainWindow: View {
    @Bindable var model: AppModel

    var body: some View {
        HSplitView {
            SessionSidebar(rows: model.sessions.map(\.row), selection: $model.selectedId) {
                model.chooseProjectAndStart()
            }
            .frame(minWidth: 180, idealWidth: 240, maxWidth: 360)

            if let session = model.selected {
                VStack(spacing: 0) {
                    SessionHeader(project: session.projectName, model: session.state.usage?.modelName,
                                  mode: session.state.permissionMode,
                                  needsAttention: session.state.status == .needsAttention)
                    TerminalHost(session: session.terminal)
                        .id(session.id)
                }
                .frame(minWidth: 520)

                SidePanel(state: session.state)
                    .frame(minWidth: 240, idealWidth: 320, maxWidth: 480)
            } else {
                VStack(spacing: 12) {
                    EmptyHint("No session")
                    Button("New Session…  ⌘N") { model.chooseProjectAndStart() }
                        .buttonStyle(.plain)
                        .font(MuseFont.body)
                        .foregroundStyle(Palette.accent)
                }
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.bg)
            }
        }
        .background(Palette.bg)
        .alert("AgentMaster", isPresented: Binding(get: { model.errorMessage != nil },
                                                  set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
```

`Sources/AgentMaster/AgentMasterApp.swift`:

```swift
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor lazy var model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable (`swift run AgentMaster`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model.shutdown() }
    }
}

@main
struct AgentMasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            MainWindow(model: delegate.model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session…") { delegate.model.chooseProjectAndStart() }
                    .keyboardShortcut("n")
            }
        }
    }
}
```

Run: `swift build`
Expected: the build succeeds with no errors. Concurrency warnings from SwiftTerm are acceptable. There must be none from `Sources/AgentMaster`.

- [ ] **Step 5: Bundle script**

`scripts/bundle.sh`:

```bash
#!/bin/bash
# Builds build/AgentMaster.app: the app binary in MacOS/, the hook helper in Helpers/, ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product AgentMaster
swift build -c release --product agentmaster-hook
BIN="$(swift build -c release --show-bin-path)"

APP="build/AgentMaster.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers"
cp "$BIN/AgentMaster" "$APP/Contents/MacOS/AgentMaster"
cp "$BIN/agentmaster-hook" "$APP/Contents/Helpers/agentmaster-hook"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.agentmaster.app</string>
    <key>CFBundleName</key><string>AgentMaster</string>
    <key>CFBundleExecutable</key><string>AgentMaster</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/Helpers/agentmaster-hook"
codesign --force --sign - "$APP"
echo "Built $APP"
```

Run: `chmod +x scripts/bundle.sh && scripts/bundle.sh && codesign --verify --deep --strict build/AgentMaster.app && echo SIGNED`
Expected: ends with `Built build/AgentMaster.app` and `SIGNED`.

- [ ] **Step 6: Manual verification (M1 + M2 exit criteria)**

Run `open build/AgentMaster.app`, press ⌘N, choose a scratch directory such as `mkdir -p /tmp/am-demo`, and check:

- [ ] The Claude Code TUI renders on the Muse background with correct colors. Typing, arrow keys, Esc, and pasting work. Resizing the window reflows the TUI.
- [ ] On a first run in that directory, the trust prompt is answerable in the terminal.
- [ ] The prompt `Create two tasks, then write hello.txt containing hi, then mark both tasks done` makes TODO show ◇ → ◆ → ✓ live, and CHANGES list `hello.txt +1 −0`. Clicking the file expands the diff.
- [ ] The prompt `Use a subagent to say OK` makes AGENTS show `└ • <description>` with a ticking timer, then `✓`.
- [ ] USAGE shows ctx %, cost, and the model after the first reply, and the header shows `model · default`.
- [ ] Running a command that needs approval makes the sidebar glyph turn `◆` and the header rule turn accent. Approving in the terminal returns it to `◈`, then `◇`.
- [ ] `/clear` empties TODO, AGENTS, and CHANGES, and the session stays `◇` rather than `✓`.
- [ ] `/exit` changes the sidebar glyph to `✓`.
- [ ] `ls ~/.claude/projects/-private-tmp-am-demo/` lists a new `.jsonl`, so the transcript was saved.
- [ ] In a new session, `! env | grep -E '^(CLAUDE|CMUX|AGENTMASTER)'` shows `AGENTMASTER_SESSION_ID` and `AGENTMASTER_SOCKET`. It also shows `CLAUDECODE=1`, which claude sets for its own children. It shows no `CMUX_*`, `CLAUDE_CODE_CHILD_SESSION`, or `CLAUDE_JOB_DIR`.
- [ ] Quit AgentMaster, then run in a plain terminal: `claude --settings ~/Library/Application\ Support/AgentMaster/sessions/<id>/settings.json`. Claude works normally and every hook is silent, because the app is not running.
- [ ] Two sessions in two projects each update only their own panels.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/AgentMaster scripts/bundle.sh
git commit -m "feat(app): assemble AgentMaster with terminal, hook bridge and live panels"
```

---

### Task 13: End-to-end smoke script

**Files:**
- Create: `scripts/smoke.py`

**Interfaces:**
- Consumes: the `agentmaster-hook` binary (`hook`, `statusline`, and `settings` subcommands from Task 6), the wire protocol from Task 3, and the real `claude` binary.
- Produces: `scripts/smoke.py`, which exits 0 on PASS. It uses real tokens on haiku, so run it by hand before merging, not in the unit test suite.

This script checks the real Claude Code against our assumptions without the GUI. It covers the hook names, the TaskCreate response shape, `structuredPatch`, statusLine delivery, and the session-id tagging. When Claude Code updates, run it first.

- [ ] **Step 1: Write the script**

`scripts/smoke.py`:

```python
#!/usr/bin/env python3
"""End-to-end smoke test: real interactive claude -> agentmaster-hook -> fake AgentMaster socket.

Usage: scripts/smoke.py   (claude: ~/.local/bin/claude or $AGENTMASTER_CLAUDE_PATH;
                          hook: `swift build` output or $AGENTMASTER_HOOK_PATH)
Costs a few cents of haiku tokens. Exits 0 on PASS.
"""
import json, os, pty, re, select, shutil, socket, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STRIP = {"CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT",
         "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
         "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_PID", "CLAUDE_JOB_DIR", "CLAUDE_EFFORT",
         "TERM_PROGRAM", "TERM_PROGRAM_VERSION"}
REQUIRED = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"}
PROMPT = ("Do these steps in order without asking me anything: "
          "1) create a task with the TaskCreate tool whose subject is 'Fix add'; "
          "2) edit app.py so add() returns a + b; "
          "3) run the bash command: echo smoke-done; "
          "4) reply with just the word Finished.")


class FakeApp(threading.Thread):
    """Records every message; answers requests with an empty reply (handle in terminal)."""

    def __init__(self, path):
        super().__init__(daemon=True)
        self.path, self.messages, self.lock = path, [], threading.Lock()
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(16)

    def run(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            with conn:
                data = b""
                while not data.endswith(b"\n"):
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                if not data.strip():
                    continue
                message = json.loads(data)
                with self.lock:
                    self.messages.append(message)
                if message.get("kind") == "request":
                    conn.sendall((json.dumps({"id": message["id"]}) + "\n").encode())

    def snapshot(self):
        with self.lock:
            return list(self.messages)


def visible(raw):
    """Terminal output without escape sequences or whitespace (the TUI draws spaces as cursor moves)."""
    text = re.sub(rb"\x1b\[[0-9;?>]*[A-Za-z]|\x1b\][^\x07]*\x07|\x1b[()][A-Z0-9]|\x1b[=>]", b"", raw)
    return re.sub(rb"\s+", b"", text)


def event_names(messages):
    return [m["payload"].get("hook_event_name") for m in messages if m.get("kind") != "statusline"]


def main():
    claude = os.environ.get("AGENTMASTER_CLAUDE_PATH") or os.path.expanduser("~/.local/bin/claude")
    if not os.access(claude, os.X_OK):
        sys.exit(f"FAIL: claude not found at {claude}")

    hook = os.environ.get("AGENTMASTER_HOOK_PATH")
    if not hook:
        subprocess.run(["swift", "build", "--product", "agentmaster-hook"], cwd=ROOT, check=True)
        bin_dir = subprocess.run(["swift", "build", "--show-bin-path"], cwd=ROOT, check=True,
                                 capture_output=True, text=True).stdout.strip()
        hook = os.path.join(bin_dir, "agentmaster-hook")

    scratch = tempfile.mkdtemp(prefix="am-smoke-", dir="/tmp")
    work = os.path.join(scratch, "work")
    os.makedirs(work)
    with open(os.path.join(work, "app.py"), "w") as f:
        f.write("def add(a, b):\n    return a - b\n")
    settings = os.path.join(scratch, "settings.json")
    with open(settings, "wb") as f:
        f.write(subprocess.run([hook, "settings"], check=True, capture_output=True).stdout)

    sock = os.path.join(scratch, "am.sock")
    app = FakeApp(sock)
    app.start()

    env = {k: v for k, v in os.environ.items()
           if k not in STRIP and not k.startswith(("CMUX_", "AGENTMASTER_"))}
    env.update(TERM="xterm-256color", COLORTERM="truecolor", AGENTMASTER_SESSION_ID="SMOKE", AGENTMASTER_SOCKET=sock)
    env.setdefault("LANG", "en_US.UTF-8")

    args = [claude, "--settings", settings, "--model", "haiku", "--permission-mode", "acceptEdits",
            "--allowedTools", "Bash(echo:*)"]
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(work)
        os.execve(claude, args, env)

    deadline, screen, trusted, prompted, exited_at = time.time() + 240, b"", False, False, None
    try:
        while time.time() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.5)
            if ready:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                screen = (screen + chunk)[-20000:]
            if not trusted and b"Entertoconfirm" in visible(screen):
                time.sleep(0.5)
                os.write(fd, b"\x1b[B")    # "Yes, I trust this folder" is the second option
                time.sleep(0.5)
                os.write(fd, b"\r")        # separate write, or the TUI reads it as one escape sequence
                trusted = True
                screen = b""
            if not prompted and b"shift+tabtocycle" in visible(screen):
                # A prompt passed on the command line is dropped when the trust dialog shows, so type it.
                time.sleep(1)
                os.write(fd, PROMPT.encode())
                time.sleep(1)
                os.write(fd, b"\r")
                prompted = True
            names = event_names(app.snapshot())
            if "Stop" in names and exited_at is None:
                time.sleep(1)
                os.write(fd, b"/exit")
                time.sleep(0.5)
                os.write(fd, b"\r")
                exited_at = time.time()
            if "SessionEnd" in names:
                break
    finally:
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
        app.server.close()

    messages = app.snapshot()
    names = event_names(messages)
    failures = []
    missing = REQUIRED - set(names)
    if missing:
        failures.append(f"missing hook events: {sorted(missing)}")
    if not any(m.get("kind") == "statusline" for m in messages):
        failures.append("no statusline message")
    posts = [m["payload"] for m in messages if m["payload"].get("hook_event_name") == "PostToolUse"]
    if not any(p.get("tool_name") == "TaskCreate" and (p.get("tool_response") or {}).get("task", {}).get("id")
               for p in posts):
        failures.append("TaskCreate PostToolUse without tool_response.task.id")
    if not any(p.get("tool_name") in ("Edit", "MultiEdit") and (p.get("tool_response") or {}).get("structuredPatch")
               for p in posts):
        failures.append("Edit PostToolUse without a non-empty structuredPatch")
    if any(m.get("sessionId") != "SMOKE" for m in messages):
        failures.append("a message was not tagged with AGENTMASTER_SESSION_ID")

    print(f"{len(messages)} messages: {names}")
    if failures:
        print("FAIL:\n  " + "\n  ".join(failures))
        with open(os.path.join(scratch, "screen.log"), "wb") as f:
            f.write(screen)
        print(f"(scratch kept at {scratch}; last terminal output in screen.log)")
        sys.exit(1)
    shutil.rmtree(scratch, ignore_errors=True)
    print("PASS")


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Run it**

Run: `chmod +x scripts/smoke.py && scripts/smoke.py`
Expected: in about 20–60 s it prints a message list and then `PASS`. The script answers the folder-trust dialog itself, then types the prompt, because Claude Code drops a command-line prompt when that dialog is shown. It gives up after 240 s. If it fails, `screen.log` in the kept scratch directory holds the last terminal output. If a required event is missing, check `~/.claude/settings.json` for `disableAllHooks`. If the edit shape changed, re-record a fixture: copy the real payloads from the printed list into a new `Tests/AgentMasterBridgeTests/Fixtures/*.jsonl` and update Task 7's translator.

- [ ] **Step 3: Commit**

```bash
git add scripts/smoke.py
git commit -m "test: add end-to-end smoke script against real Claude Code"
```

---

## Completion checklist

- [ ] `swift test` passes: all six test targets, run three times in a row.
- [ ] `scripts/bundle.sh` succeeds and every item in the Task 12 Step 6 manual checklist holds.
- [ ] `scripts/smoke.py` prints PASS.
- [ ] Spec §10: the M1 and M2 completion criteria are met. The next plan is M3 (native approval and question overlays), which replaces the `reply(nil)` in `AppModel`.
