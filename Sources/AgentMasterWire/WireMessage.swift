import Foundation
import AgentMasterCore

public enum WireKind: String, Codable, Sendable {
    /// Fire-and-forget hook notification.
    case event
    /// The shim blocks until the app replies (PermissionRequest, PreToolUse/AskUserQuestion).
    case request
    /// statusLine JSON; fire-and-forget.
    case statusline
}

public struct WireMessage: Codable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    public let kind: WireKind
    public let payload: JSONValue

    public init(id: String, sessionId: String, kind: WireKind, payload: JSONValue) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.payload = payload
    }
}

/// `output == nil` means "print nothing": Claude Code then falls back to its own terminal UI.
public struct WireReply: Codable, Equatable, Sendable {
    public let id: String
    public let output: String?

    public init(id: String, output: String?) {
        self.id = id
        self.output = output
    }
}

public enum WireCodec {
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, line: Data) throws -> T {
        try JSONDecoder().decode(type, from: line)
    }
}

/// Accumulates socket reads and yields complete, non-empty lines (without the newline).
public struct LineBuffer {
    private var data = Data()

    public init() {}

    public mutating func append(_ chunk: Data) -> [Data] {
        data.append(chunk)
        var lines: [Data] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let line = Data(data[data.startIndex..<newline])
            data = Data(data[data.index(after: newline)...])
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }
}
