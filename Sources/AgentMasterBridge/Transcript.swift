import Foundation
import AgentMasterCore

/// One step of a conversation, read back from an agent's transcript so it can be summarized.
public enum TranscriptEntry: Equatable, Sendable {
    case user(String)
    case assistant(String)
    case tool(name: String, input: String)
    case toolResult(String)
}

/// Reads each agent's transcript format. Only what a summary needs: prompts, replies, tool calls and results.
public enum TranscriptParser {
    /// Claude Code: `~/.claude/projects/<project>/<id>.jsonl`, one message per line.
    public static func claude(_ data: Data) -> [TranscriptEntry] {
        lines(data).flatMap { line -> [TranscriptEntry] in
            guard line["isMeta"]?.boolValue != true, let content = line["message"]?["content"] else { return [] }
            switch line["type"]?.stringValue {
            case "user":
                if let text = content.stringValue { return prompt(text).map { [.user($0)] } ?? [] }
                return (content.arrayValue ?? []).compactMap { block in
                    switch block["type"]?.stringValue {
                    case "text": return block["text"]?.stringValue.flatMap(prompt).map(TranscriptEntry.user)
                    case "tool_result": return .toolResult(text(of: block["content"]))
                    default: return nil
                    }
                }
            case "assistant":
                return (content.arrayValue ?? []).compactMap { block in
                    switch block["type"]?.stringValue {
                    case "text": return nonEmpty(block["text"]?.stringValue).map(TranscriptEntry.assistant)
                    case "tool_use": return .tool(name: block["name"]?.stringValue ?? "tool", input: compact(block["input"]))
                    default: return nil
                    }
                }
            default:
                return []
            }
        }
    }

    /// Codex: `~/.codex/sessions/…/rollout-*.jsonl`; the conversation is in its `response_item` lines.
    public static func codex(_ data: Data) -> [TranscriptEntry] {
        lines(data).compactMap { line -> TranscriptEntry? in
            guard line["type"]?.stringValue == "response_item", let item = line["payload"] else { return nil }
            switch item["type"]?.stringValue {
            case "message":
                let text = (item["content"]?.arrayValue ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
                switch item["role"]?.stringValue {
                case "user": return prompt(text).map(TranscriptEntry.user)
                case "assistant": return nonEmpty(text).map(TranscriptEntry.assistant)
                default: return nil   // developer: Codex's own instructions
                }
            case "function_call":
                return .tool(name: item["name"]?.stringValue ?? "tool", input: item["arguments"]?.stringValue ?? "")
            case "custom_tool_call":
                return .tool(name: item["name"]?.stringValue ?? "tool", input: item["input"]?.stringValue ?? "")
            case "function_call_output", "custom_tool_call_output":
                return .toolResult(text(of: item["output"]))
            default:
                return nil
            }
        }
    }

    /// Kiro: the hooks report `<id>.json`, which holds only metadata; the conversation is the `<id>.jsonl` beside it.
    public static func kiro(_ data: Data) -> [TranscriptEntry] {
        lines(data).flatMap { line -> [TranscriptEntry] in
            let blocks = line["data"]?["content"]?.arrayValue ?? []
            switch line["kind"]?.stringValue {
            case "Prompt":
                let text = blocks.filter { $0["kind"]?.stringValue == "text" }.compactMap { $0["data"]?.stringValue }
                return prompt(text.joined(separator: "\n")).map { [.user($0)] } ?? []
            case "AssistantMessage":
                return blocks.compactMap { block in
                    switch block["kind"]?.stringValue {
                    case "text": return nonEmpty(block["data"]?.stringValue).map(TranscriptEntry.assistant)
                    case "toolUse":
                        return .tool(name: block["data"]?["name"]?.stringValue ?? "tool", input: compact(block["data"]?["input"]))
                    default: return nil
                    }
                }
            case "ToolResults":
                return blocks.filter { $0["kind"]?.stringValue == "toolResult" }.map { .toolResult(text(of: $0["data"]?["content"])) }
            default:
                return []
            }
        }
    }

    private static func lines(_ data: Data) -> [JSONValue] {
        data.split(separator: UInt8(ascii: "\n")).compactMap { try? JSONValue.parse(Data($0)) }
    }

    /// A real prompt, not text the CLI injected (`<command-name>`, `<environment_context>`, AGENTS.md…).
    private static func prompt(_ text: String) -> String? {
        guard let text = nonEmpty(text), !text.hasPrefix("<"), !text.hasPrefix("# AGENTS.md instructions") else { return nil }
        return text
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// Tool results are a string, or a list of text blocks (`text` in Claude's, `data` in Kiro's).
    private static func text(of value: JSONValue?) -> String {
        if let string = value?.stringValue { return string }
        if let blocks = value?.arrayValue {
            return blocks.map { $0["text"]?.stringValue ?? $0["data"]?.stringValue ?? compact($0) }.joined(separator: "\n")
        }
        return compact(value)
    }

    private static func compact(_ value: JSONValue?) -> String {
        guard let value, let data = try? value.encoded() else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Summarizes a session in the background with `claude -p`, so the session itself is never interrupted.
public enum SessionSummary {
    static let toolInputLimit = 300
    static let toolResultLimit = 400
    static let messageLimit = 4_000
    static let conversationLimit = 200_000

    public static let instructions = """
        You review a coding-agent session. Its transcript follows: the user's prompts, the agent's replies, \
        the tools it called and their results (all of them truncated).

        Write a short Markdown report with exactly these sections:
        ## Summary
        What the user asked for and what was done, in a few sentences.
        ## Changes
        Each file created or edited, one bullet each, with what changed.
        ## Open items
        What is unfinished, failing or waiting on the user. "None" if nothing.
        ## Retrospective
        What slowed the session down (wrong turns, errors, retries, missing context) and concrete suggestions \
        to get there faster next time.

        Base everything on the transcript and do not guess. Be concise. Write in the language the user wrote in.
        """

    /// The transcript as plain text, each part cut to a size that keeps long sessions within one request.
    public static func conversation(_ entries: [TranscriptEntry]) -> String {
        let text = entries.map { entry in
            switch entry {
            case .user(let text): return "USER: " + truncated(text, messageLimit)
            case .assistant(let text): return "AGENT: " + truncated(text, messageLimit)
            case let .tool(name, input): return "TOOL \(name): " + truncated(input, toolInputLimit)
            case .toolResult(let text): return "RESULT: " + truncated(text, toolResultLimit)
            }
        }.joined(separator: "\n\n")
        guard text.count > conversationLimit else { return text }
        // Keep the start, where the task is set, and most of the end, where it stands now.
        let head = conversationLimit / 5
        let tail = conversationLimit - head
        return String(text.prefix(head)) + "\n\n[… \(text.count - conversationLimit) characters omitted …]\n\n"
            + String(text.suffix(tail))
    }

    static func truncated(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + " […]" : text
    }

    public enum Failure: LocalizedError {
        case claudeNotFound
        case emptyTranscript
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .claudeNotFound: return "Summaries need Claude Code (claude), which was not found."
            case .emptyTranscript: return "The transcript has no conversation yet."
            case .failed(let message): return message
            }
        }
    }

    /// Runs `claude -p` with no tools and no saved session, in `directory` so no project's CLAUDE.md is read.
    public static func run(entries: [TranscriptEntry], environment: [String: String], directory: URL,
                           timeout: TimeInterval = 300) async throws -> String {
        guard !entries.isEmpty else { throw Failure.emptyTranscript }
        guard let claude = ClaudeCodeAgent().executable.locate(environment: environment) else { throw Failure.claudeNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["-p", "--no-session-persistence", "--tools", "", "--system-prompt", instructions]
        process.environment = LaunchEnvironment.childEnvironment(base: environment)
        process.currentDirectoryURL = directory
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do { try process.run() } catch {
                    return continuation.resume(throwing: Failure.failed("Could not run claude: \(error.localizedDescription)"))
                }
                // Feed stdin and drain stdout/stderr at the same time, or a full pipe stalls claude.
                DispatchQueue.global().async {
                    input.fileHandleForWriting.write(Data(conversation(entries).utf8))
                    try? input.fileHandleForWriting.close()
                }
                let stderr = DataBox()
                let drained = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    stderr.data = errors.fileHandleForReading.readDataToEndOfFile()
                    drained.signal()
                }
                let timer = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let stdout = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                drained.wait()
                let text = String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: Failure.failed("claude did not finish within \(Int(timeout)) seconds."))
                } else if process.terminationStatus != 0 || text.isEmpty {
                    let message = String(decoding: stderr.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: Failure.failed(message.isEmpty ? (text.isEmpty ? "claude returned nothing." : text) : message))
                } else {
                    continuation.resume(returning: text)
                }
            }
        }
    }
}
