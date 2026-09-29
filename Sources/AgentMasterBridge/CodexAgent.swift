import Foundation
import AgentMasterCore

/// OpenAI Codex CLI, run as its interactive TUI. Its hooks take Claude-shaped payloads; they are injected
/// per session with `-c hooks.<Event>=…`, which Codex only runs with its hook-trust check bypassed.
public struct CodexAgent: AgentKind {
    public static let modelOption = AgentOption.modelId
    public static let sandboxOption = "sandbox"
    public static let approvalOption = "approval"
    public static let hooksOption = "hooks"
    /// The values `codex --sandbox` accepts.
    public static let sandboxModes = ["read-only", "workspace-write", "danger-full-access"]
    /// The values `codex --ask-for-approval` accepts (0.154 rejects `untrusted` and `on-failure`).
    public static let approvalPolicies = ["on-request", "never"]

    public let id = "codex"
    public let displayName = "Codex"
    public let executable = ExecutableSpec(name: "codex", overrideVariable: "AGENTMASTER_CODEX_PATH")
    public let glyph = AgentGlyphStyle.terminalPrompt
    public let shortcut: AgentShortcut? = AgentShortcut(key: "n", option: true)
    public var supportsResume: Bool { true }
    public var hookDialect: any HookDialect { CodexHookDialect() }

    public init() {}

    public func options(environment: [String: String]) -> [AgentOption] {
        [
            AgentOption(id: Self.modelOption, title: "Default model", kind: .choice([], allowsCustom: true)),
            AgentOption(id: Self.sandboxOption, title: "Default sandbox", kind: .choice(
                Self.sandboxModes.map { AgentChoice(value: $0, label: Self.labels[$0]) }, allowsCustom: false)),
            AgentOption(id: Self.approvalOption, title: "Default approval policy", kind: .choice(
                Self.approvalPolicies.map { AgentChoice(value: $0, label: Self.labels[$0]) }, allowsCustom: false)),
            // Codex runs only hooks the user has trusted in its own UI, and there is no way to trust one
            // from the command line, so AgentMaster's hooks need the bypass flag.
            AgentOption(id: Self.hooksOption, title: "Show session activity in panels", kind: .toggle(default: true),
                        note: "Bypasses Codex hook trust, so hooks from a project's own Codex config also run without asking."),
        ]
    }

    static let labels = [
        "read-only": "Read only", "workspace-write": "Workspace write", "danger-full-access": "Full access (no sandbox)",
        "on-request": "On request", "never": "Never ask",
    ]

    public func hooksEnabled(preferences: AgentPreferences) -> Bool {
        preferences.bool(Self.hooksOption, default: true)
    }

    public func hookArguments(for plan: HookPlan) throws -> [String] {
        Self.hookArguments(command: plan.command)
    }

    static func hookArguments(command: String) -> [String] {
        var args = ["--dangerously-bypass-hook-trust"]
        for event in HookPlan.events {
            var hook = "type=\"command\",command=\(tomlString(command))"
            if let timeout = event.timeout { hook += ",timeout=\(timeout)" }
            let matcher = event.matcher.map { "matcher=\(tomlString($0))," } ?? ""
            args += ["-c", "hooks.\(event.name)=[{\(matcher)hooks=[{\(hook)}]}]"]
        }
        return args
    }

    public func arguments(preferences: AgentPreferences, hookArguments: [String], resumeId: String?) -> [String] {
        var args: [String] = []
        if let resumeId { args += ["resume", resumeId] }
        if let model = preferences.string(Self.modelOption) { args += ["--model", model] }
        // An unknown value would make codex refuse to start; follow its own config instead.
        if let sandbox = preferences.string(Self.sandboxOption), Self.sandboxModes.contains(sandbox) {
            args += ["--sandbox", sandbox]
        }
        if let approval = preferences.string(Self.approvalOption), Self.approvalPolicies.contains(approval) {
            args += ["--ask-for-approval", approval]
        }
        return args + hookArguments
    }

    /// A TOML basic string, which is how `-c key=value` values are parsed.
    static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Codex's payloads already match Claude's, except that it edits files with `apply_patch` through Bash
/// and reports no PostToolUse for it, so the change is read from the PreToolUse command.
public struct CodexHookDialect: HookDialect {
    public init() {}

    public func fileChanges(in payload: JSONValue) -> [FileChange] {
        guard payload["hook_event_name"]?.stringValue == "PreToolUse", payload["tool_name"]?.stringValue == "Bash",
              let command = payload["tool_input"]?["command"]?.stringValue, command.hasPrefix("apply_patch")
        else { return [] }
        return PatchParser.changes(fromApplyPatch: command, cwd: payload["cwd"]?.stringValue)
    }
}
