import Foundation

/// A file the user uploaded to a session, to send with a message: what the browser shows, and where the
/// agent finds it. It belongs to that session only and goes away with it.
public struct AttachmentJSON: Codable, Equatable, Sendable {
    public let id: String
    public let sessionId: String
    /// As the user's device named it.
    public let name: String
    /// The MIME type the browser sent, "application/octet-stream" when it sent none.
    public let type: String
    public let size: Int
    /// Where the browser previews or downloads it (with the token as `?token=` in an <img> or link).
    public let url: String
    /// On the server; it goes into the prompt, so the agent reads it.
    public let path: String
}

/// What an upload and a message may carry. The browser reads these rather than keeping its own numbers.
public struct UploadLimitsJSON: Codable, Equatable, Sendable {
    public let maxFileBytes: Int
    public let maxAttachmentsPerMessage: Int

    public static let current = UploadLimitsJSON(maxFileBytes: 50 * 1024 * 1024, maxAttachmentsPerMessage: 10)
}

/// Every session's uploaded attachments, by id. Memory only: the files live in session folders, which the
/// server clears when it starts.
final class AttachmentStore: @unchecked Sendable {
    private let lock = NSLock()
    private var bySession: [String: [String: AttachmentJSON]] = [:]

    func add(_ attachment: AttachmentJSON) {
        lock.lock()
        bySession[attachment.sessionId, default: [:]][attachment.id] = attachment
        lock.unlock()
    }

    /// The attachment, if it was uploaded to this session; one from another session is not found.
    func find(sessionId: String, id: String) -> AttachmentJSON? {
        lock.lock()
        defer { lock.unlock() }
        return bySession[sessionId]?[id]
    }

    func removeAll(sessionId: String) {
        lock.lock()
        bySession[sessionId] = nil
        lock.unlock()
    }
}
