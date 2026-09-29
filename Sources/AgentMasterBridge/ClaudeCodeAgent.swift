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

    public init() {}

    public func options(environment: [String: String]) -> [AgentOption] {
        [
            AgentOption(id: Self.modelOption, title: "Default model", kind: .choice(
                Self.modelAliases.map { AgentChoice(value: $0, detail: environment["ANTHROPIC_DEFAULT_\($0.uppercased())_MODEL"]) },
                allowsCustom: true)),
            AgentOption(id: Self.permissionModeOption, title: "Default permission mode", kind: .choice(
                Self.permissionModes.map { AgentChoice(value: $0, label: $0 == "manual" ? "manual (default)" : nil) },
                allowsCustom: false)),
            AgentOption(id: Self.allowBypassOption, title: "Allow switching to bypass permissions in a session",
                        kind: .toggle(default: true)),
        ]
    }

    public func isForcedOn(optionId: String, preferences: AgentPreferences) -> Bool {
        optionId == Self.allowBypassOption && preferences.string(Self.permissionModeOption) == "bypassPermissions"
    }

    public func hooksEnabled(preferences: AgentPreferences) -> Bool { true }

    public func hookArguments(for plan: HookPlan) throws -> [String] {
        let settings = try plan.writeSessionFile(SessionSettingsBuilder(hookExecutable: plan.hookExecutable).data())
        return ["--settings", settings.path]
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
