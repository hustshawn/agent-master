import Foundation
import AgentMasterCore
import AgentMasterWire

/// Kiro CLI, run as `kiro-cli chat`. Kiro reads hooks only from agent configs, and agent configs only from a
/// project's `.kiro/agents`, `~/.kiro/agents` or `KIRO_AGENT_CONFIG_DIR`. Each session points that variable at its
/// own folder holding a `kiro_default` with AgentMaster's hooks, which stands in for the built-in default agent;
/// neither the project nor `~/.kiro` is touched. The variable replaces `~/.kiro/agents` for that session, and
/// the v3 engine ignores it (checked on kiro-cli 2.25).
public struct KiroAgent: AgentKind {
    public static let modelOption = AgentOption.modelId
    public static let hooksOption = "hooks"
    public static let trustAllToolsOption = "trustAllTools"
    /// The built-in agent `kiro-cli chat` starts when none is named.
    static let agentName = "kiro_default"
    static let agentFolder = "kiro-agents"

    public let id = "kiro"
    public let displayName = "Kiro"
    public let executable = ExecutableSpec(name: "kiro-cli", overrideVariable: "AGENTMASTER_KIRO_PATH")
    public let glyph = AgentGlyphStyle.ghost(hex: "#8F49FF")
    public let shortcut: AgentShortcut? = AgentShortcut(key: "n", control: true)
    public var supportsResume: Bool { true }
    public var hookDialect: any HookDialect { KiroHookDialect() }

    public init() {}

    public func options(environment: [String: String]) -> [AgentOption] {
        [
            AgentOption(id: Self.modelOption, title: "Default model", kind: .choice([], allowsCustom: true),
                        note: "Run kiro-cli chat --list-models for the ids."),
            AgentOption(id: Self.trustAllToolsOption, title: "Trust all tools", kind: .toggle(default: false),
                        note: "Kiro runs every tool, shell commands included, without asking. It asks you to accept this once per session."),
            AgentOption(id: Self.hooksOption, title: "Show session activity in panels", kind: .toggle(default: true),
                        note: "Replaces the default agent for the session, so agents in ~/.kiro/agents are not available in it."),
        ]
    }

    public func transcript(at path: String) -> [TranscriptEntry] {
        let conversation = (path as NSString).deletingPathExtension + ".jsonl"
        return FileManager.default.contents(atPath: conversation).map(TranscriptParser.kiro) ?? []
    }

    public func hooksEnabled(preferences: AgentPreferences) -> Bool {
        preferences.bool(Self.hooksOption, default: true)
    }

    public func hookArguments(for plan: HookPlan) throws -> [String] {
        _ = try plan.writeSessionFile(Self.agentConfig(command: plan.command), folder: Self.agentFolder,
                                      name: "\(Self.agentName).json")
        return []
    }

    public func hookEnvironment(for plan: HookPlan) -> [String: String] {
        ["KIRO_AGENT_CONFIG_DIR": plan.paths.sessionDirectory(plan.sessionId).appendingPathComponent(Self.agentFolder).path]
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
        if let resumeId { args += ["--resume-id", resumeId] }
        if let model = preferences.string(Self.modelOption) { args += ["--model", model] }
        if preferences.bool(Self.trustAllToolsOption, default: false) { args.append("--trust-all-tools") }
        return args + hookArguments
    }
}

/// Kiro's payloads are Claude-shaped apart from names: camelCase events, its own tool names and inputs, no
/// `tool_use_id` and no transcript path. This fills those in so HookTranslator reads them like Claude's.
public struct KiroHookDialect: HookDialect {
    /// Kiro's events and the Claude events they stand for. Kiro has no session end or subagent events.
    static let events = [
        ("agentSpawn", "SessionStart"), ("userPromptSubmit", "UserPromptSubmit"),
        ("preToolUse", "PreToolUse"), ("postToolUse", "PostToolUse"), ("stop", "Stop"),
    ]

    let home: String

    public init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    public func normalize(_ payload: JSONValue) -> JSONValue {
        guard var fields = payload.objectValue,
              let event = Self.events.first(where: { $0.0 == fields["hook_event_name"]?.stringValue })?.1
        else { return payload }
        fields["hook_event_name"] = .string(event)
        switch event {
        case "SessionStart":
            // Kiro saves each conversation here; its presence is what makes a session resumable.
            if let id = fields["session_id"]?.stringValue {
                fields["transcript_path"] = .string("\(home)/.kiro/sessions/cli/\(id).json")
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

    /// Claude's name and input for a Kiro tool, and for edits the `tool_response` Claude would report.
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
