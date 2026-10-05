import Foundation
import AgentMasterCore

/// The user's answer to a hook request (an approval or a question), given in a browser instead of the
/// agent's own terminal UI.
public enum RemoteDecision: Equatable, Sendable {
    case allow
    /// `interrupt` also stops the turn, where the agent supports that.
    case deny(message: String, interrupt: Bool)
    /// AskUserQuestion: each question's text mapped to the chosen label (labels joined by ", " for multi-select).
    case answer([String: String])
}
