import Foundation
import AgentMasterCore
import AgentMasterWire

/// A coding agent AgentMaster runs in a terminal. Each agent CLI keeps its own harness; an implementation
/// only says how this CLI differs: where its binary is, its settings, how it loads AgentMaster's hooks, its
/// other launch arguments and how its hook payloads read. Everything else (finding the binary and the hook
/// helper, the session environment, resuming, the panels, the new-session UI) is shared.
public protocol AgentKind: Sendable {
    /// Part of the stored preference keys: never change it once shipped.
    var id: String { get }
    var displayName: String { get }
    var executable: ExecutableSpec { get }
    var glyph: AgentGlyphStyle { get }
    /// A menu shortcut that starts this agent without the new-session panel.
    var shortcut: AgentShortcut? { get }
    var supportsResume: Bool { get }
    /// Maps this agent's hook payloads onto the Claude Code shape HookTranslator reads.
    var hookDialect: any HookDialect { get }

    /// Declared settings; the default-model option, if any, uses `AgentOption.modelId`.
    func options(environment: [String: String]) -> [AgentOption]
    /// A toggle the current preferences switch on regardless of its stored value (shown on and disabled).
    func isForcedOn(optionId: String, preferences: AgentPreferences) -> Bool
    /// The id `launch` needs to continue this session's conversation later.
    func resumeId(from state: SessionState) -> String?

    /// Whether to inject AgentMaster's hooks into this launch.
    func hooksEnabled(preferences: AgentPreferences) -> Bool
    /// Writes `plan` in this agent's own hook format; returns the arguments that make the agent load it.
    func hookArguments(for plan: HookPlan) throws -> [String]
    /// The full argument list, given the hook arguments (empty when hooks are off) and an optional resume id.
    func arguments(preferences: AgentPreferences, hookArguments: [String], resumeId: String?) -> [String]

    /// Shared by every agent (see the extension); override only for a launch that fits nothing above.
    func launch(_ request: AgentLaunchRequest) throws -> AgentLaunch
}

extension AgentKind {
    public var shortcut: AgentShortcut? { nil }
    public var supportsResume: Bool { false }
    public var hookDialect: any HookDialect { ClaudeHookDialect() }
    public func isForcedOn(optionId: String, preferences: AgentPreferences) -> Bool { false }
    public func hooksEnabled(preferences: AgentPreferences) -> Bool { false }
    public func hookArguments(for plan: HookPlan) throws -> [String] { [] }

    /// Resume the conversation the hooks reported, as long as its transcript is still on disk.
    public func resumeId(from state: SessionState) -> String? {
        guard supportsResume else { return nil }
        return SessionResume.id(from: state) { FileManager.default.fileExists(atPath: $0) }
    }

    public func launch(_ request: AgentLaunchRequest) throws -> AgentLaunch {
        guard let binary = executable.locate(environment: request.environment) else {
            throw AgentLaunchError.notFound(agent: displayName, executable: executable)
        }
        var hookArgs: [String] = []
        if hooksEnabled(preferences: request.preferences) {
            guard let hook = request.paths.hookExecutable() else { throw AgentLaunchError.hookHelperMissing }
            hookArgs = try hookArguments(for: HookPlan(hookExecutable: hook, sessionId: request.sessionId,
                                                       paths: request.paths, projectPath: request.projectPath))
        }
        return AgentLaunch(
            executable: binary,
            args: arguments(preferences: request.preferences, hookArguments: hookArgs, resumeId: request.resumeId),
            environment: LaunchEnvironment.sessionEnvironment(base: request.environment, sessionId: request.sessionId,
                                                             socketPath: request.paths.socketPath))
    }
}

/// Every agent AgentMaster offers, in UI order; the first is the default. Adding an agent means adding it here.
public enum AgentRegistry {
    public static let all: [any AgentKind] = [ClaudeCodeAgent(), CodexAgent()]
    public static var defaultAgent: any AgentKind { all[0] }

    public static func agent(id: String) -> (any AgentKind)? {
        all.first { $0.id == id }
    }
}

public enum SessionResume {
    /// The conversation id the hooks reported, if its transcript still exists.
    public static func id(from state: SessionState, fileExists: (String) -> Bool) -> String? {
        guard let id = state.agentSessionId, let path = state.transcriptPath, fileExists(path) else { return nil }
        return id
    }
}

/// What an agent's hook configuration must do: run `command` for each of `events`, with the shared
/// matcher and timeout rules. The session directory is the place for any file the agent has to read.
public struct HookPlan {
    public struct Event: Equatable {
        public let name: String
        /// "*" for tool events.
        public let matcher: String?
        /// Seconds, for events whose hook may wait on the user.
        public let timeout: Int?
    }

    public let hookExecutable: String
    public let sessionId: String
    public let paths: AppPaths
    public let projectPath: String?

    public init(hookExecutable: String, sessionId: String, paths: AppPaths, projectPath: String?) {
        self.hookExecutable = hookExecutable
        self.sessionId = sessionId
        self.paths = paths
        self.projectPath = projectPath
    }

    /// The shell command for `agentmaster-hook hook`.
    public var command: String {
        SessionSettingsBuilder(hookExecutable: hookExecutable).command("hook")
    }

    /// Named as Claude Code names them; an agent with other names maps them (and back, in its HookDialect).
    public static let events: [Event] = SessionSettingsBuilder.hookEvents.map { name in
        Event(name: name,
              matcher: SessionSettingsBuilder.toolEvents.contains(name) ? "*" : nil,
              timeout: SessionSettingsBuilder.decisionEvents.contains(name) ? SessionSettingsBuilder.decisionTimeout : nil)
    }

    /// Writes `data` into this session's directory, removed when the session closes.
    public func writeSessionFile(_ data: Data) throws -> URL {
        try paths.writeSettings(data, sessionId: sessionId)
    }
}

/// A key equivalent, kept free of SwiftUI so agents can declare one.
public struct AgentShortcut: Equatable, Sendable {
    public let key: Character
    public let option: Bool
    public let shift: Bool

    public init(key: Character, option: Bool = false, shift: Bool = false) {
        self.key = key
        self.option = option
        self.shift = shift
    }
}

public struct AgentLaunchRequest {
    public let sessionId: String
    public let preferences: AgentPreferences
    /// The login shell's environment.
    public let environment: [String: String]
    public let paths: AppPaths
    public let resumeId: String?
    /// The folder the session runs in.
    public let projectPath: String?

    public init(sessionId: String, preferences: AgentPreferences, environment: [String: String],
                paths: AppPaths, resumeId: String? = nil, projectPath: String? = nil) {
        self.sessionId = sessionId
        self.preferences = preferences
        self.environment = environment
        self.paths = paths
        self.resumeId = resumeId
        self.projectPath = projectPath
    }
}

public struct AgentLaunch: Equatable {
    public let executable: String
    public let args: [String]
    public let environment: [String: String]

    public init(executable: String, args: [String], environment: [String: String]) {
        self.executable = executable
        self.args = args
        self.environment = environment
    }
}

public enum AgentLaunchError: LocalizedError, Equatable {
    case notFound(agent: String, executable: ExecutableSpec)
    case hookHelperMissing

    public var errorDescription: String? {
        switch self {
        case let .notFound(agent, executable):
            return "\(agent) not found. Install it (~/.local/bin/\(executable.name)) or set \(executable.overrideVariable)."
        case .hookHelperMissing:
            return "agentmaster-hook is missing. Build with scripts/bundle.sh, or `swift build` so it sits next to the app binary."
        }
    }
}
