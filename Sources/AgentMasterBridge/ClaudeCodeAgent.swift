import Foundation
import AgentMasterCore
import AgentMasterWire

/// Claude Code: hooks injected with `--settings`, so its panels light up through HookTranslator.
public struct ClaudeCodeAgent: AgentKind {
    public static let modelOption = "model"
    public static let permissionModeOption = "permissionMode"
    public static let allowBypassOption = "allowBypass"
    public static let modelAliases = ["opus", "sonnet", "haiku", "fable"]
    /// The values `claude --permission-mode` accepts.
    public static let permissionModes = ["manual", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions"]

    public let id = "claude"
    public let displayName = "Claude Code"
    public var supportsResume: Bool { true }

    private let locate: @Sendable ([String: String]) -> String?

    public init(locate: @escaping @Sendable ([String: String]) -> String? = { ClaudeLocator.locate(environment: $0) }) {
        self.locate = locate
    }

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

    public func resumeId(from state: SessionState) -> String? {
        state.claudeSessionId
    }

    public static func arguments(settingsPath: String, preferences: AgentPreferences, resumeId: String? = nil) -> [String] {
        var args = ["--settings", settingsPath]
        if let model = preferences.string(modelOption) { args += ["--model", model] }
        // An unknown mode would make claude refuse to start; follow its own settings instead.
        let mode = preferences.string(permissionModeOption).flatMap { permissionModes.contains($0) ? $0 : nil }
        if let mode { args += ["--permission-mode", mode] }
        if preferences.bool(allowBypassOption, default: true) || mode == "bypassPermissions" {
            args.append("--allow-dangerously-skip-permissions")
        }
        if let resumeId { args += ["--resume", resumeId] }
        return args
    }

    public func launch(_ request: AgentLaunchRequest) throws -> AgentLaunch {
        guard let claude = locate(request.environment) else { throw AgentLaunchError.claudeNotFound }
        guard let hook = request.paths.hookExecutable() else { throw AgentLaunchError.hookHelperMissing }
        let settings = try request.paths.writeSettings(SessionSettingsBuilder(hookExecutable: hook).data(),
                                                       sessionId: request.sessionId)
        return AgentLaunch(
            executable: claude,
            args: Self.arguments(settingsPath: settings.path, preferences: request.preferences, resumeId: request.resumeId),
            environment: LaunchEnvironment.sessionEnvironment(base: request.environment, sessionId: request.sessionId,
                                                             socketPath: request.paths.socketPath))
    }
}

public enum AgentRegistry {
    public static let all: [any AgentKind] = [ClaudeCodeAgent()]
    public static var defaultAgent: any AgentKind { all[0] }

    public static func agent(id: String) -> (any AgentKind)? {
        all.first { $0.id == id }
    }
}
