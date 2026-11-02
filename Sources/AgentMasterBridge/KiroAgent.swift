import Foundation
import AgentMasterCore
import AgentMasterWire

/// Kiro CLI, run as `kiro-cli chat`, on the engine its `chat.agentEngine` setting picks unless the Agent engine option
/// says otherwise. The V2 engine reads hooks only from agent configs, found in a project's `.kiro/agents`,
/// `~/.kiro/agents` or `KIRO_AGENT_CONFIG_DIR`: each session points that variable at its own folder holding a
/// `kiro_default` with AgentMaster's hooks, which stands in for the built-in default agent and replaces
/// `~/.kiro/agents` for that session. The V3 engine ignores the variable and reads hooks only from Kiro's own
/// `hooks` folder (and a trusted project's), so every V3 session shares one file there, which does nothing outside
/// AgentMaster. V2 never reads that folder, so a session gets both and works on either engine (kiro-cli 2.37).
public struct KiroAgent: AgentKind {
    public static let modelOption = AgentOption.modelId
    public static let hooksOption = "hooks"
    public static let trustAllToolsOption = "trustAllTools"
    public static let engineOption = "engine"
    /// `kiro-cli chat --v2` or `--v3`.
    static let engines = ["v2", "v3"]
    /// The built-in agent `kiro-cli chat` starts when none is named.
    static let agentName = "kiro_default"
    static let agentFolder = "kiro-agents"
    /// The V3 hooks file in Kiro's `hooks` folder, and the variable that points it at this session's hook helper.
    static let sharedHooksName = "agentmaster.json"
    static let hookVariable = "AGENTMASTER_KIRO_HOOK"

    public let id = "kiro"
    public let displayName = "Kiro"
    public let executable = ExecutableSpec(name: "kiro-cli", overrideVariable: "AGENTMASTER_KIRO_PATH")
    public let glyph = AgentGlyphStyle.ghost(hex: "#8F49FF")
    public let shortcut: AgentShortcut? = AgentShortcut(key: "n", control: true)
    public var supportsResume: Bool { true }
    public var hookDialect: any HookDialect { KiroHookDialect() }
    /// The V3 engine's first hook comes with the first prompt. While it starts, what is typed waits in its queue.
    public var promptHints: [String] { ["ask a question or describe a task", "type to queue a message"] }

    public init() {}

    public func options(environment: [String: String]) -> [AgentOption] {
        [
            AgentOption(id: Self.modelOption, title: "Default model", kind: .choice([], allowsCustom: true),
                        note: "Run kiro-cli chat --list-models for the ids."),
            AgentOption(id: Self.engineOption, title: "Agent engine", kind: .choice(
                Self.engines.map { AgentChoice(value: $0, label: $0.uppercased()) }, allowsCustom: false),
                        note: "Following Kiro uses its chat.agentEngine setting, which is V2 until you switch."),
            AgentOption(id: Self.trustAllToolsOption, title: "Trust all tools", kind: .toggle(default: false),
                        note: "Kiro runs every tool, shell commands included, without asking. It asks you to accept this once per session."),
            AgentOption(id: Self.hooksOption, title: "Show session activity in panels", kind: .toggle(default: true),
                        note: "On V2 it replaces the default agent for the session, so agents in ~/.kiro/agents are not available in it. On V3 it adds ~/.kiro/hooks/agentmaster.json, which does nothing outside AgentMaster."),
        ]
    }

    public func transcript(at path: String) -> [TranscriptEntry] {
        if (path as NSString).lastPathComponent == KiroHookDialect.v3Transcript {
            return FileManager.default.contents(atPath: path).map(TranscriptParser.kiroV3) ?? []
        }
        let conversation = (path as NSString).deletingPathExtension + ".jsonl"
        return FileManager.default.contents(atPath: conversation).map(TranscriptParser.kiro) ?? []
    }

    /// The names its hooks use too (V2's, then V3's), mapped the same way.
    public func toolKind(name: String, input: JSONValue) -> ToolKind {
        guard let (claudeName, claudeInput, _) = KiroHookDialect.claudeTool(name, input: input) else {
            return ToolClassifier.kind(name: name, input: input)
        }
        return ToolClassifier.kind(name: claudeName, input: claudeInput)
    }

    public func hooksEnabled(preferences: AgentPreferences) -> Bool {
        preferences.bool(Self.hooksOption, default: true)
    }

    public func hookArguments(for plan: HookPlan) throws -> [String] {
        _ = try plan.writeSessionFile(Self.agentConfig(command: plan.command), folder: Self.agentFolder,
                                      name: "\(Self.agentName).json")
        if plan.preferences.string(Self.engineOption) != "v2" {
            // Without it V3 sessions only lack their panels, so a folder that cannot be written does not stop the launch.
            try? Self.installSharedHooks(in: Self.configHome(environment: plan.environment))
        }
        return []
    }

    public func hookEnvironment(for plan: HookPlan) -> [String: String] {
        ["KIRO_AGENT_CONFIG_DIR": plan.paths.sessionDirectory(plan.sessionId).appendingPathComponent(Self.agentFolder).path,
         Self.hookVariable: plan.hookExecutable]
    }

    /// Kiro's config folder: `KIRO_HOME` when it is an absolute path, else `~/.kiro`.
    static func configHome(environment: [String: String]) -> URL {
        if let kiroHome = environment["KIRO_HOME"], kiroHome.hasPrefix("/") { return URL(fileURLWithPath: kiroHome) }
        return URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".kiro")
    }

    /// Writes the V3 hooks file unless it is already there as is.
    static func installSharedHooks(in configHome: URL) throws {
        let folder = configHome.appendingPathComponent("hooks")
        let url = folder.appendingPathComponent(sharedHooksName)
        let data = try sharedHooks()
        guard (try? Data(contentsOf: url)) != data else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// A V3 hook per event (tool hooks without a matcher run for every tool). Kiro runs each command with `sh`; the
    /// variable is set only in AgentMaster's sessions, so anywhere else the hook exits at once.
    static func sharedHooks() throws -> Data {
        let command = "[ -z \"$\(hookVariable)\" ] || exec \"$\(hookVariable)\" hook"
        let hooks: [JSONValue] = KiroHookDialect.events.map { _, event in
            ["name": .string("AgentMaster \(event)"), "trigger": .string(event),
             "action": ["type": "command", "command": .string(command)]]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(["version": "v1", "hooks": .array(hooks)] as JSONValue)
    }

    /// The default agent's settings (every tool, the default resources) plus a hook per Kiro event.
    static func agentConfig(command: String) throws -> Data {
        var hooks: [String: JSONValue] = [:]
        for (event, claudeEvent) in KiroHookDialect.events {
            var hook: [String: JSONValue] = ["command": .string(command)]
            if SessionSettingsBuilder.toolEvents.contains(claudeEvent) { hook["matcher"] = "*" }
            hooks[event] = [.object(hook)]
        }
        let config: JSONValue = [
            "name": .string(agentName),
            "description": "Kiro's default agent, with AgentMaster's hooks",
            "tools": ["*"],
            "hooks": .object(hooks),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(config)
    }

    public func arguments(preferences: AgentPreferences, hookArguments: [String], resumeId: String?) -> [String] {
        var args = ["chat"]
        if let engine = preferences.string(Self.engineOption), Self.engines.contains(engine) { args.append("--" + engine) }
        if let resumeId { args += ["--resume-id", resumeId] }
        if let model = preferences.string(Self.modelOption) { args += ["--model", model] }
        if preferences.bool(Self.trustAllToolsOption, default: false) { args.append("--trust-all-tools") }
        return args + hookArguments
    }
}

/// Kiro's payloads are Claude-shaped apart from names: its own tool names and inputs, no `tool_use_id` and no
/// transcript path, and on the V2 engine camelCase events. This fills those in so HookTranslator reads them like
/// Claude's. V3 sends SessionStart only with a new conversation's first prompt, and none for a resumed one.
public struct KiroHookDialect: HookDialect {
    /// Kiro's V2 events and the Claude events they stand for, which V3 uses as is. Kiro reports no subagent events,
    /// and V3's SessionEnd only when its process exits.
    static let events = [
        ("agentSpawn", "SessionStart"), ("userPromptSubmit", "UserPromptSubmit"),
        ("preToolUse", "PreToolUse"), ("postToolUse", "PostToolUse"), ("stop", "Stop"),
    ]
    /// V3 keeps each conversation in `<config folder>/sessions/<workspace hash>/<session id>/` as this file.
    static let v3Transcript = "messages.jsonl"

    let home: String
    /// Where V3 keeps its sessions; V2's are always under `home`.
    let v3Sessions: URL

    public init(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        v3Sessions = KiroAgent.configHome(environment: environment.merging(["HOME": home]) { $1 })
            .appendingPathComponent("sessions")
    }

    public func normalize(_ payload: JSONValue) -> JSONValue {
        guard var fields = payload.objectValue, let name = fields["hook_event_name"]?.stringValue,
              let event = Self.events.first(where: { $0.0 == name || $0.1 == name })?.1
        else { return payload }
        let v2 = name != event
        fields["hook_event_name"] = .string(event)
        switch event {
        case "SessionStart" where v2:
            // Kiro saves each conversation here; its presence is what makes a session resumable.
            if let id = fields["session_id"]?.stringValue {
                fields["transcript_path"] = .string("\(home)/.kiro/sessions/cli/\(id).json")
            }
        case "SessionStart", "UserPromptSubmit":
            // Either can be the first a V3 conversation reports (see HookTranslator).
            if !v2, let id = fields["session_id"]?.stringValue, let path = v3TranscriptPath(sessionId: id) {
                fields["transcript_path"] = .string(path)
            }
        case "Stop":
            fields["last_assistant_message"] = fields["assistant_response"]
        case "PreToolUse", "PostToolUse":
            let input = fields["tool_input"] ?? .null
            // A PreToolUse and its PostToolUse carry the same input, so the pair gets the same id.
            fields["tool_use_id"] = .string(Self.toolUseId(name: fields["tool_name"]?.stringValue ?? "", input: input))
            if let (name, claudeInput, response) = Self.claudeTool(fields["tool_name"]?.stringValue, input: input) {
                fields["tool_name"] = .string(name)
                fields["tool_input"] = claudeInput
                if event == "PostToolUse", let response { fields["tool_response"] = response }
            }
        default:
            break
        }
        return .object(fields)
    }

    /// The workspace hash in the path is Kiro's own; the session id alone finds the folder.
    private func v3TranscriptPath(sessionId: String) -> String? {
        let buckets = (try? FileManager.default.contentsOfDirectory(atPath: v3Sessions.path)) ?? []
        return buckets.lazy
            .map { self.v3Sessions.appendingPathComponent($0).appendingPathComponent(sessionId) }
            .first { FileManager.default.fileExists(atPath: $0.path) }?
            .appendingPathComponent(Self.v3Transcript).path
    }

    /// Claude's name and input for a Kiro tool (V2's names, then V3's), and for edits the `tool_response` Claude
    /// would report.
    static func claudeTool(_ name: String?, input: JSONValue) -> (String, JSONValue, JSONValue?)? {
        let path = input["path"]?.stringValue ?? ""
        switch name {
        case "shell":
            return ("Bash", ["command": input["command"] ?? "", "description": input["__tool_use_purpose"] ?? .null], nil)
        case "read":
            let first = input["operations"]?[0]?["path"]?.stringValue ?? path
            return ("Read", ["file_path": .string(first)], nil)
        case "grep":
            return ("Grep", ["pattern": input["pattern"] ?? "", "path": .string(path)], nil)
        case "glob":
            return ("Glob", ["pattern": input["pattern"] ?? "", "path": .string(path)], nil)
        case "write":
            let content = input["content"]?.stringValue ?? ""
            switch input["command"]?.stringValue {
            case "create":
                return ("Write", ["file_path": .string(path), "content": .string(content)],
                        ["type": "create", "filePath": .string(path), "content": .string(content)])
            case "strReplace":
                let old = input["oldStr"]?.stringValue ?? "", new = input["newStr"]?.stringValue ?? ""
                return ("Edit", ["file_path": .string(path), "old_string": .string(old), "new_string": .string(new)],
                        patch(path: path, removed: lines(old), added: lines(new)))
            case "insert":
                return ("Edit", ["file_path": .string(path), "old_string": "", "new_string": .string(content)],
                        patch(path: path, removed: [], added: lines(content)))
            default:
                return nil
            }
        case "read_file":
            return ("Read", ["file_path": .string(path)], nil)
        case "fs_write":
            let content = input["text"]?.stringValue ?? ""
            return ("Write", ["file_path": .string(path), "content": .string(content)],
                    ["type": "create", "filePath": .string(path), "content": .string(content)])
        case "str_replace":
            let old = input["oldStr"]?.stringValue ?? "", new = input["newStr"]?.stringValue ?? ""
            return ("Edit", ["file_path": .string(path), "old_string": .string(old), "new_string": .string(new)],
                    patch(path: path, removed: lines(old), added: lines(new)))
        case "fs_append":
            let text = input["text"]?.stringValue ?? ""
            return ("Edit", ["file_path": .string(path), "old_string": "", "new_string": .string(text)],
                    patch(path: path, removed: [], added: lines(text)))
        case "execute_bash":
            return ("Bash", ["command": input["command"] ?? "", "description": input["description"] ?? .null], nil)
        case "grep_search":
            return ("Grep", ["pattern": input["query"] ?? "", "path": ""], nil)
        case "file_search":
            return ("Glob", ["pattern": input["query"] ?? "", "path": ""], nil)
        default:
            return nil
        }
    }

    /// A Claude `structuredPatch` for one replacement. Kiro reports no line numbers, so starts are 0.
    private static func patch(path: String, removed: [String], added: [String]) -> JSONValue {
        let lines = removed.map { JSONValue.string("-" + $0) } + added.map { JSONValue.string("+" + $0) }
        return ["filePath": .string(path), "structuredPatch": [[
            "oldStart": 0, "oldLines": .number(Double(removed.count)),
            "newStart": 0, "newLines": .number(Double(added.count)), "lines": .array(lines),
        ]]]
    }

    private static func lines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// FNV-1a over the tool name and its input with sorted keys: stable across the Pre and Post payloads.
    static func toolUseId(name: String, input: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = Array(name.utf8) + [0] + Array((try? encoder.encode(input)) ?? Data())
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return "kiro-" + String(hash, radix: 16)
    }
}
