import Foundation
import AgentMasterCore

/// OpenAI Codex CLI, run as its interactive TUI.
public struct CodexAgent: AgentKind {
    public static let modelOption = "model"
    public static let sandboxOption = "sandbox"
    public static let approvalOption = "approval"
    /// The values `codex --sandbox` accepts.
    public static let sandboxModes = ["read-only", "workspace-write", "danger-full-access"]
    /// The values `codex --ask-for-approval` accepts (0.154 rejects `untrusted` and `on-failure`).
    public static let approvalPolicies = ["on-request", "never"]

    public let id = "codex"
    public let displayName = "Codex"

    private let locate: @Sendable ([String: String]) -> String?

    public init(locate: @escaping @Sendable ([String: String]) -> String? = { CodexLocator.locate(environment: $0) }) {
        self.locate = locate
    }

    public func options(environment: [String: String]) -> [AgentOption] {
        [
            AgentOption(id: Self.modelOption, title: "Default model", kind: .choice([], allowsCustom: true)),
            AgentOption(id: Self.sandboxOption, title: "Default sandbox", kind: .choice(
                Self.sandboxModes.map { AgentChoice(value: $0) }, allowsCustom: false)),
            AgentOption(id: Self.approvalOption, title: "Default approval policy", kind: .choice(
                Self.approvalPolicies.map { AgentChoice(value: $0) }, allowsCustom: false)),
        ]
    }

    public static func arguments(preferences: AgentPreferences) -> [String] {
        var args: [String] = []
        if let model = preferences.string(modelOption) { args += ["--model", model] }
        // An unknown value would make codex refuse to start; follow its own config instead.
        if let sandbox = preferences.string(sandboxOption), sandboxModes.contains(sandbox) { args += ["--sandbox", sandbox] }
        if let approval = preferences.string(approvalOption), approvalPolicies.contains(approval) {
            args += ["--ask-for-approval", approval]
        }
        return args
    }

    public func launch(_ request: AgentLaunchRequest) throws -> AgentLaunch {
        guard let codex = locate(request.environment) else { throw AgentLaunchError.codexNotFound }
        return AgentLaunch(
            executable: codex,
            args: Self.arguments(preferences: request.preferences),
            environment: LaunchEnvironment.sessionEnvironment(base: request.environment, sessionId: request.sessionId,
                                                             socketPath: request.paths.socketPath))
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
