import Foundation
import AgentMasterCore
import AgentMasterWire

/// Claude Code: hooks and the status line go in a per-session settings file passed with `--settings`.
public struct ClaudeCodeAgent: AgentKind {
    public static let modelOption = AgentOption.modelId
    public static let permissionModeOption = "permissionMode"
    public static let allowBypassOption = "allowBypass"
    public static let modelAliases = ["opus", "sonnet", "haiku", "fable"]
    /// The values `claude --permission-mode` accepts.
    public static let permissionModes = ["manual", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions"]

    public let id = "claude"
    public let displayName = "Claude Code"
    /// cmux ships a same-named wrapper that must be skipped.
    public let executable = ExecutableSpec(name: "claude", overrideVariable: "AGENTMASTER_CLAUDE_PATH", excluding: ["cmux.app"])
    public let glyph = AgentGlyphStyle.spark(hex: "#D97757")
    public var supportsResume: Bool { true }
    /// The per-session settings set AgentMaster's status line command.
    public var reportsUsage: Bool { true }

    public init() {}

    public func options(environment: [String: String]) -> [AgentOption] {
        [
            AgentOption(id: Self.modelOption, title: "Default model", kind: .choice(
                Self.modelAliases.map { AgentChoice(value: $0, detail: environment["ANTHROPIC_DEFAULT_\($0.uppercased())_MODEL"]) },
                allowsCustom: true)),
            AgentOption(id: Self.permissionModeOption, title: "Default permission mode", kind: .choice(
                Self.permissionModes.map { AgentChoice(value: $0, label: Self.permissionModeLabels[$0]) },
                allowsCustom: false)),
            AgentOption(id: Self.allowBypassOption, title: "Allow bypass permissions",
                        kind: .toggle(default: true), note: "Lets a running session switch to bypass permissions."),
        ]
    }

    static let permissionModeLabels = [
        "manual": "Manual (default)", "acceptEdits": "Accept edits", "plan": "Plan", "auto": "Auto",
        "dontAsk": "Don't ask", "bypassPermissions": "Bypass permissions",
    ]

    public func isForcedOn(optionId: String, preferences: AgentPreferences) -> Bool {
        optionId == Self.allowBypassOption && preferences.string(Self.permissionModeOption) == "bypassPermissions"
    }

    public func transcript(at path: String) -> [TranscriptEntry] {
        FileManager.default.contents(atPath: path).map(TranscriptParser.claude) ?? []
    }

    /// PermissionRequest takes a `decision`; AskUserQuestion is answered from PreToolUse by echoing its
    /// questions with an `answers` map (code.claude.com/docs/en/hooks#askuserquestion).
    public func hookOutput(for payload: JSONValue, decision: RemoteDecision) -> String? {
        let output: JSONValue
        switch (payload["hook_event_name"]?.stringValue, decision) {
        case ("PermissionRequest", .allow):
            output = ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]
        case let ("PermissionRequest", .deny(message, interrupt)):
            output = ["hookEventName": "PermissionRequest",
                      "decision": ["behavior": "deny", "message": .string(message), "interrupt": .bool(interrupt)]]
        case let ("PreToolUse", .answer(answers)) where payload["tool_name"]?.stringValue == "AskUserQuestion":
            output = ["hookEventName": "PreToolUse", "permissionDecision": "allow",
                      "updatedInput": ["questions": payload["tool_input"]?["questions"] ?? .array([]),
                                       "answers": .object(answers.mapValues(JSONValue.string))]]
        case let ("PreToolUse", .deny(message, _)) where payload["tool_name"]?.stringValue == "AskUserQuestion":
            output = ["hookEventName": "PreToolUse", "permissionDecision": "deny",
                      "permissionDecisionReason": .string(message)]
        default:
            return nil
        }
        return (try? JSONValue.object(["hookSpecificOutput": output]).encoded()).map { String(decoding: $0, as: UTF8.self) }
    }

    public func hooksEnabled(preferences: AgentPreferences) -> Bool { true }

    public func hookArguments(for plan: HookPlan) throws -> [String] {
        let settings = try plan.writeSessionFile(SessionSettingsBuilder(hookExecutable: plan.hookExecutable).data())
        // Files the user attaches from a browser are saved in the session's folder, outside the project; without
        // this, reading each one would ask for permission first.
        return ["--settings", settings.path, "--add-dir", plan.paths.sessionDirectory(plan.sessionId).path]
    }

    public func arguments(preferences: AgentPreferences, hookArguments: [String], resumeId: String?) -> [String] {
        var args = hookArguments
        if let model = preferences.string(Self.modelOption) { args += ["--model", model] }
        // An unknown mode would make claude refuse to start; follow its own settings instead.
        let mode = preferences.string(Self.permissionModeOption).flatMap { Self.permissionModes.contains($0) ? $0 : nil }
        if let mode { args += ["--permission-mode", mode] }
        if preferences.bool(Self.allowBypassOption, default: true) || mode == "bypassPermissions" {
            args.append("--allow-dangerously-skip-permissions")
        }
        if let resumeId { args += ["--resume", resumeId] }
        return args
    }
}
