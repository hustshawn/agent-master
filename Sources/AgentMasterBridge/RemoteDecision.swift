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

/// How a PreToolUse the policy rules stopped is answered (ADR 0017).
public enum PolicyReply: Equatable, Sendable {
    /// The user allowed it (an ASK), or nothing objected.
    case allow
    /// A rule denied it, or the user did; `reason` goes back to the model.
    case deny(reason: String)
    /// Nobody answered in AgentMaster (the terminal was chosen, it timed out or it expired): the agent's own
    /// approval decides where it can, else the call is denied, since an empty answer would let it run.
    case handBack(reason: String)
}
