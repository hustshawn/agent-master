import Foundation

/// One session to reopen on the next launch.
public struct OpenSessionRecord: Codable, Equatable, Sendable {
    public let agentId: String
    public let projectPath: String
    public let createdAt: Date
    public let resumeId: String
    public let selected: Bool
    /// The row title (custom name or first prompt); optional so older journals still decode.
    public let title: String?
    /// The web edition's "reviewed" mark on the last turn; nil (not reviewed) in older journals and the Mac app.
    public let reviewed: Bool?
    /// `SessionState.lastActivityAt`, so the Mac sidebar keeps its order; nil before the first turn and in older journals.
    public let lastActivityAt: Date?

    public init(agentId: String, projectPath: String, createdAt: Date, resumeId: String, selected: Bool,
                title: String? = nil, reviewed: Bool? = nil, lastActivityAt: Date? = nil) {
        self.agentId = agentId
        self.projectPath = projectPath
        self.createdAt = createdAt
        self.resumeId = resumeId
        self.selected = selected
        self.title = title
        self.reviewed = reviewed
        self.lastActivityAt = lastActivityAt
    }
}
