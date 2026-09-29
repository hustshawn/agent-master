import Foundation
import AgentMasterCore
import AgentMasterWire

/// OpenAI Codex CLI, run as its interactive TUI. Its hooks take Claude-shaped payloads, so they go through
/// the same `agentmaster-hook` and HookTranslator; they are injected per session with `-c hooks.<Event>=…`.
public struct CodexAgent: AgentKind {
    public static let modelOption = "model"
    public static let sandboxOption = "sandbox"
    public static let approvalOption = "approval"
    public static let hooksOption = "hooks"
    /// The values `codex --sandbox` accepts.
    public static let sandboxModes = ["read-only", "workspace-write", "danger-full-access"]
    /// The values `codex --ask-for-approval` accepts (0.154 rejects `untrusted` and `on-failure`).
    public static let approvalPolicies = ["on-request", "never"]

    public let id = "codex"
    public let displayName = "Codex"
    public var supportsResume: Bool { true }

    private let locate: @Sendable ([String: String]) -> String?
    private let transcriptExists: @Sendable (String) -> Bool

    public init(locate: @escaping @Sendable ([String: String]) -> String? = { CodexLocator.locate(environment: $0) },
                transcriptExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.locate = locate
        self.transcriptExists = transcriptExists
    }

    public func options(environment: [String: String]) -> [AgentOption] {
        [
            AgentOption(id: Self.modelOption, title: "Default model", kind: .choice([], allowsCustom: true)),
            AgentOption(id: Self.sandboxOption, title: "Default sandbox", kind: .choice(
                Self.sandboxModes.map { AgentChoice(value: $0) }, allowsCustom: false)),
            AgentOption(id: Self.approvalOption, title: "Default approval policy", kind: .choice(
                Self.approvalPolicies.map { AgentChoice(value: $0) }, allowsCustom: false)),
            // Codex runs only hooks the user has trusted in its own UI, and there is no way to trust one
            // from the command line, so AgentMaster's hooks need the bypass flag.
            AgentOption(id: Self.hooksOption, title: "Show session activity in panels (bypasses Codex hook trust)",
                        kind: .toggle(default: true)),
        ]
    }

    /// Same rule as Claude: resume only a conversation whose transcript is still on disk.
    public func resumeId(from state: SessionState) -> String? {
        guard let id = state.claudeSessionId,
              let path = state.transcriptPath,
              transcriptExists(path) else { return nil }
        return id
    }

    /// `hookCommand` is the shell command for `agentmaster-hook hook`, or nil to inject no hooks.
    public static func arguments(preferences: AgentPreferences, hookCommand: String? = nil,
                                 resumeId: String? = nil) -> [String] {
        var args: [String] = []
        if let resumeId { args += ["resume", resumeId] }
        if let model = preferences.string(modelOption) { args += ["--model", model] }
        // An unknown value would make codex refuse to start; follow its own config instead.
        if let sandbox = preferences.string(sandboxOption), sandboxModes.contains(sandbox) { args += ["--sandbox", sandbox] }
        if let approval = preferences.string(approvalOption), approvalPolicies.contains(approval) {
            args += ["--ask-for-approval", approval]
        }
        if let hookCommand {
            args.append("--dangerously-bypass-hook-trust")
            for event in SessionSettingsBuilder.hookEvents {
                var hook = "type=\"command\",command=\(tomlString(hookCommand))"
                if SessionSettingsBuilder.decisionEvents.contains(event) {
                    hook += ",timeout=\(SessionSettingsBuilder.decisionTimeout)"
                }
                let matcher = SessionSettingsBuilder.toolEvents.contains(event) ? "matcher=\"*\"," : ""
                args += ["-c", "hooks.\(event)=[{\(matcher)hooks=[{\(hook)}]}]"]
            }
        }
        return args
    }

    public func launch(_ request: AgentLaunchRequest) throws -> AgentLaunch {
        guard let codex = locate(request.environment) else { throw AgentLaunchError.codexNotFound }
        var hookCommand: String?
        if request.preferences.bool(Self.hooksOption, default: true) {
            guard let hook = request.paths.hookExecutable() else { throw AgentLaunchError.hookHelperMissing }
            hookCommand = SessionSettingsBuilder(hookExecutable: hook).command("hook")
        }
        return AgentLaunch(
            executable: codex,
            args: Self.arguments(preferences: request.preferences, hookCommand: hookCommand, resumeId: request.resumeId),
            environment: LaunchEnvironment.sessionEnvironment(base: request.environment, sessionId: request.sessionId,
                                                             socketPath: request.paths.socketPath))
    }

    /// A TOML basic string, which is how `-c key=value` values are parsed.
    static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public enum CodexLocator {
    public static func locate(
        environment: [String: String],
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        var candidates: [String] = []
        if let override = environment["AGENTMASTER_CODEX_PATH"], !override.isEmpty { candidates.append(override) }
        candidates += [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        return candidates.first(where: isExecutable)
    }
}
