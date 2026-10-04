import Foundation
import AgentMasterCore
import AgentMasterBridge

/// One row of a session's chat view: a prompt, a reply, or a tool call with its result.
public struct ChatItemJSON: Codable, Equatable, Sendable {
    /// "user", "assistant" or "tool".
    public let kind: String
    public var text: String?
    public var name: String?
    /// A tool call's one-line label, as the panels word it ("Edit Login.swift", "$ swift test").
    public var title: String?
    public var input: String?
    /// Nil while the tool has not returned.
    public var output: String?
}

/// Part of a chat: the items from `start` on, out of `total`.
public struct ChatJSON: Codable, Equatable, Sendable {
    public let start: Int
    public let total: Int
    public let items: [ChatItemJSON]
}

/// Turns a transcript into chat rows and pages them for a browser that already has the earlier ones.
enum Chat {
    /// Tool inputs and results are cut to this for the browser; the transcript keeps the rest.
    static let inputLimit = 2_000
    static let outputLimit = 4_000

    static func items(_ entries: [TranscriptEntry]) -> [ChatItemJSON] {
        var items: [ChatItemJSON] = []
        var toolIndex: [String: Int] = [:]
        for entry in entries {
            switch entry {
            case .user(let text):
                items.append(ChatItemJSON(kind: "user", text: text))
            case .assistant(let text):
                items.append(ChatItemJSON(kind: "assistant", text: text))
            case let .tool(name, input, id):
                let parsed = (try? JSONValue.parse(Data(input.utf8))) ?? .null
                if let id { toolIndex[id] = items.count }
                items.append(ChatItemJSON(kind: "tool", name: name, title: ToolClassifier.kind(name: name, input: parsed).title,
                                          input: truncated(input, inputLimit)))
            case let .toolResult(text, id):
                // Without an id, the result belongs to the earliest call still waiting for one.
                let index = id.flatMap { toolIndex[$0] }
                    ?? items.firstIndex { $0.kind == "tool" && $0.output == nil }
                if let index { items[index].output = truncated(text, outputLimit) }
            }
        }
        return items
    }

    /// The items from `after` on, starting earlier at a tool call whose result was still missing then, since
    /// that row may have changed. The browser replaces everything from `start`.
    static func page(_ items: [ChatItemJSON], after: Int) -> ChatJSON {
        let after = max(0, min(after, items.count))
        let start = items[..<after].firstIndex { $0.kind == "tool" && $0.output == nil } ?? after
        return ChatJSON(start: start, total: items.count, items: Array(items[start...]))
    }

    private static func truncated(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + " […]" : text
    }
}
