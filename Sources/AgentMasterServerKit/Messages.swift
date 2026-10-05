import Foundation

/// A message the user sent a session from a browser, and how far it got.
public struct MessageReceiptJSON: Codable, Equatable, Sendable {
    /// Chosen by the browser, so a retry of the same send is recognised.
    public let id: String
    public let sessionId: String
    public let text: String
    public let createdAt: Double
    /// "written" (typed into the terminal), "delivered" (the agent reported the prompt) or
    /// "unconfirmed" (no report in time; it may or may not have arrived).
    public var status: String
}

public enum MessageError: Error, CustomStringConvertible {
    case busy(String)
    case empty

    public var description: String {
        switch self {
        case .busy(let reason): return reason
        case .empty: return "The message is empty."
        }
    }
}

/// Types messages into sessions' terminals and matches them to the prompts the agents report. One message
/// per session is in flight at a time; receipts live in memory until their session closes.
final class MessageStore: @unchecked Sendable {
    /// How long to wait for the agent's UserPromptSubmit before calling a message unconfirmed.
    let confirmTimeout: TimeInterval
    private let lock = NSLock()
    private var receipts: [String: MessageReceiptJSON] = [:]
    var onChange: (@Sendable (MessageReceiptJSON) -> Void)?

    init(confirmTimeout: TimeInterval = 30) {
        self.confirmTimeout = confirmTimeout
    }

    var all: [MessageReceiptJSON] {
        lock.lock()
        defer { lock.unlock() }
        return receipts.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// After the paste, when to press Enter, and when to press it again if the agent has not reported the
    /// prompt yet. Claude Code turns a pasted image path into an attachment and swallows an Enter that comes
    /// while it reads the image; an extra Enter on an already empty input does nothing.
    static let enterDelays: [TimeInterval] = [0.3, 2.5, 6]

    /// Writes `text` into the session as typed input, unless a send with the same `id` already happened.
    /// `idle` is whether the agent is waiting for a prompt; `write` types into its terminal.
    func send(id: String, sessionId: String, text: String, idle: Bool,
              write: @escaping @Sendable (Data) -> Void) throws -> MessageReceiptJSON {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MessageError.empty }
        lock.lock()
        if let existing = receipts[id] {
            lock.unlock()
            return existing
        }
        guard idle else {
            lock.unlock()
            throw MessageError.busy("The agent is busy. Interrupt it first, or wait for the turn to end.")
        }
        guard !receipts.values.contains(where: { $0.sessionId == sessionId && $0.status == "written" }) else {
            lock.unlock()
            throw MessageError.busy("The previous message has not reached the agent yet.")
        }
        let receipt = MessageReceiptJSON(id: id, sessionId: sessionId, text: trimmed,
                                         createdAt: Date().timeIntervalSince1970, status: "written")
        receipts[id] = receipt
        lock.unlock()
        write(Self.pasted(trimmed))
        for (index, delay) in Self.enterDelays.enumerated() {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                // The first Enter always; the later ones only while the prompt still has not arrived.
                guard index == 0 || self?.status(id) == "written" else { return }
                write(Data("\r".utf8))
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + confirmTimeout) { [weak self] in
            self?.update(id, from: "written", to: "unconfirmed")
        }
        onChange?(receipt)
        return receipt
    }

    /// The agent reported `prompt`: the session's in-flight message, if this is it, has arrived.
    func promptSubmitted(sessionId: String, prompt: String) {
        lock.lock()
        // Spacing is not compared: with an image's path gone, Claude Code also folds the blank lines around it.
        let reported = Self.withoutWhitespace(prompt)
        let match = receipts.values.first {
            $0.sessionId == sessionId && $0.status == "written"
                && reported.contains(Self.withoutWhitespace(Self.withoutImagePaths($0.text)))
        }
        lock.unlock()
        if let match { update(match.id, from: "written", to: "delivered") }
    }

    /// The text an agent reports back for a prompt: Claude Code replaces an image's path with "[Image #1]".
    static func withoutImagePaths(_ text: String) -> String {
        text.replacingOccurrences(of: #"(^|\s)/\S+\.(png|jpe?g|gif|webp)(?=\s|$)"#, with: "",
                                  options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func withoutWhitespace(_ text: String) -> String {
        text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined()
    }

    private func status(_ id: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return receipts[id]?.status
    }

    func removeAll(sessionId: String) {
        lock.lock()
        receipts = receipts.filter { $0.value.sessionId != sessionId }
        lock.unlock()
    }

    /// A bracketed paste, so newlines stay in the prompt instead of submitting it. Enter follows separately.
    static func pasted(_ text: String) -> Data {
        Data("\u{1B}[200~\(text)\u{1B}[201~".utf8)
    }

    private func update(_ id: String, from old: String, to new: String) {
        lock.lock()
        guard var receipt = receipts[id], receipt.status == old else {
            lock.unlock()
            return
        }
        receipt.status = new
        receipts[id] = receipt
        lock.unlock()
        onChange?(receipt)
    }
}
