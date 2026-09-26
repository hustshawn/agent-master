import Foundation

/// One session to reopen on the next launch.
public struct OpenSessionRecord: Codable, Equatable, Sendable {
    public let agentId: String
    public let projectPath: String
    public let createdAt: Date
    public let resumeId: String
    public let selected: Bool

    public init(agentId: String, projectPath: String, createdAt: Date, resumeId: String, selected: Bool) {
        self.agentId = agentId
        self.projectPath = projectPath
        self.createdAt = createdAt
        self.resumeId = resumeId
        self.selected = selected
    }
}
