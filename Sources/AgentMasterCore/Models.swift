import Foundation

public enum ToolKind: Equatable, Sendable {
    case read(path: String)
    case search(pattern: String)
    case edit(path: String)
    case write(path: String)
    case shell(command: String, description: String?)
    case web(target: String)
    case agent(description: String)
    case other(name: String)

    /// One-line label, e.g. "Read app.py" or "$ echo hi".
    public var title: String {
        switch self {
        case .read(let path): return Self.join("Read", Self.basename(path))
        case .search(let pattern): return Self.join("Search", pattern)
        case .edit(let path): return Self.join("Edit", Self.basename(path))
        case .write(let path): return Self.join("Write", Self.basename(path))
        case .shell(let command, _): return "$ " + command
        case .web(let target): return Self.join("Fetch", target)
        case .agent(let description): return Self.join("Agent", description)
        case .other(let name): return name
        }
    }

    private static func basename(_ path: String) -> String {
        path.isEmpty ? "" : (path as NSString).lastPathComponent
    }

    private static func join(_ verb: String, _ detail: String) -> String {
        detail.isEmpty ? verb : verb + " " + detail
    }
}

public struct ToolCall: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let kind: ToolKind

    public init(id: String, name: String, kind: ToolKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

public enum ToolOutcome: Equatable, Sendable {
    case success
    case failure(message: String)
}

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case context, added, removed }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct DiffHunk: Equatable, Sendable {
    public let oldStart: Int
    public let oldLines: Int
    public let newStart: Int
    public let newLines: Int
    public let lines: [DiffLine]

    public init(oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.lines = lines
    }
}

public struct FileChange: Equatable, Sendable, Identifiable {
    public let path: String
    public var hunks: [DiffHunk]

    public init(path: String, hunks: [DiffHunk]) {
        self.path = path
        self.hunks = hunks
    }

    public var id: String { path }
    public var added: Int { hunks.flatMap(\.lines).filter { $0.kind == .added }.count }
    public var removed: Int { hunks.flatMap(\.lines).filter { $0.kind == .removed }.count }
}

public enum TodoStatus: String, Equatable, Sendable {
    case pending
    case inProgress = "in_progress"
    case completed
}

public struct TodoItem: Equatable, Sendable, Identifiable {
    public let id: String
    public var subject: String
    public var status: TodoStatus

    public init(id: String, subject: String, status: TodoStatus) {
        self.id = id
        self.subject = subject
        self.status = status
    }
}

public struct SubagentInfo: Equatable, Sendable, Identifiable {
    public let id: String
    public var type: String
    public var description: String?
    public var startedAt: Date
    public var finishedAt: Date?

    public init(id: String, type: String, description: String? = nil, startedAt: Date, finishedAt: Date? = nil) {
        self.id = id
        self.type = type
        self.description = description
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var finished: Bool { finishedAt != nil }

    public func elapsed(at now: Date) -> TimeInterval {
        max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
    }
}

public struct Usage: Equatable, Sendable {
    public let modelName: String
    public let contextUsedPercent: Int?
    public let inputTokens: Int
    public let outputTokens: Int
    public let costUSD: Double

    public init(modelName: String, contextUsedPercent: Int?, inputTokens: Int, outputTokens: Int, costUSD: Double) {
        self.modelName = modelName
        self.contextUsedPercent = contextUsedPercent
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
    }
}
