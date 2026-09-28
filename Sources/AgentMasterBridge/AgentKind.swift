import Foundation
import AgentMasterCore

/// A coding agent AgentMaster can run in a terminal: Claude Code or Codex. The protocol holds just what
/// these need, so it is not shaped around guesses about other agents.
public protocol AgentKind: Sendable {
    /// Part of the stored preference keys: never change it once shipped.
    var id: String { get }
    var displayName: String { get }
    var supportsResume: Bool { get }
    func options(environment: [String: String]) -> [AgentOption]
    /// A toggle the current preferences switch on regardless of its stored value (shown on and disabled).
    func isForcedOn(optionId: String, preferences: AgentPreferences) -> Bool
    /// The id `launch` needs to continue this session's conversation later.
    func resumeId(from state: SessionState) -> String?
    func launch(_ request: AgentLaunchRequest) throws -> AgentLaunch
}

extension AgentKind {
    public var supportsResume: Bool { false }
    public func isForcedOn(optionId: String, preferences: AgentPreferences) -> Bool { false }
    public func resumeId(from state: SessionState) -> String? { nil }
}

public struct AgentLaunchRequest {
    public let sessionId: String
    public let preferences: AgentPreferences
    /// The login shell's environment.
    public let environment: [String: String]
    public let paths: AppPaths
    public let resumeId: String?

    public init(sessionId: String, preferences: AgentPreferences, environment: [String: String],
                paths: AppPaths, resumeId: String? = nil) {
        self.sessionId = sessionId
        self.preferences = preferences
        self.environment = environment
        self.paths = paths
        self.resumeId = resumeId
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
    case claudeNotFound
    case codexNotFound
    case hookHelperMissing

    public var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "Claude Code not found. Install it (~/.local/bin/claude) or set AGENTMASTER_CLAUDE_PATH."
        case .codexNotFound:
            return "Codex CLI not found. Install it (~/.local/bin/codex) or set AGENTMASTER_CODEX_PATH."
        case .hookHelperMissing:
            return "agentmaster-hook is missing. Build with scripts/bundle.sh, or `swift build` so it sits next to the app binary."
        }
    }
}
