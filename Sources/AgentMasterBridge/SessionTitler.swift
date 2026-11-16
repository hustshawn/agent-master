import Foundation
import AgentMasterCore

/// Names a session after its first turn: a short title from `claude -p` on Haiku, in place of the first prompt.
public enum SessionTitler {
    public static let model = "haiku"
    static let replyLimit = 2_000
    static let titleLimit = 80

    public static let instructions = """
        You name a coding-agent session for a sidebar. The user's first prompt and the agent's reply follow.
        Reply with the title only: at most six words (about fifteen characters in Chinese or Japanese), \
        no quotes and no final punctuation. Say what the task is about. Write in the language the user wrote in.
        """

    /// The prompt to title the session from when a turn ends, or nil before a real prompt or once it has a name.
    public static func prompt(for state: SessionState, customName: String?) -> String? {
        guard customName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { return nil }
        return state.firstPromptText
    }

    static func input(prompt: String, reply: String?) -> String {
        "USER: " + prompt + (reply.map { "\n\nAGENT: " + $0.prefix(replyLimit) } ?? "")
    }

    /// The answer's first line, without heading marks, quotes or a final full stop.
    static func clean(_ output: String) -> String? {
        let quotes = CharacterSet(charactersIn: "\"'`“”‘’「」『』*").union(.whitespaces)
        guard let line = output.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        var title = String(line.drop { $0 == "#" }).trimmingCharacters(in: quotes)
        while let last = title.last, ".。".contains(last) { title.removeLast() }
        title = String(title.trimmingCharacters(in: quotes).prefix(titleLimit))
        return title.isEmpty ? nil : title
    }

    /// The title for a session whose first prompt was `prompt` and whose agent answered `reply`.
    public static func run(prompt: String, reply: String?, environment: [String: String], directory: URL,
                           timeout: TimeInterval = 60) async throws -> String {
        let output = try await SessionSummary.claude(input: input(prompt: prompt, reply: reply), instructions: instructions,
                                                     model: model, environment: environment, directory: directory,
                                                     timeout: timeout)
        guard let title = clean(output) else { throw SessionSummary.Failure.failed("claude returned no title.") }
        return title
    }
}
