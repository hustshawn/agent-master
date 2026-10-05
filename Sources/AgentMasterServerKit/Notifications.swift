import Foundation

/// What the service worker shows; `sessionId` is where a tap on it opens.
struct PushPayload: Codable, Equatable {
    let title: String
    let body: String
    let sessionId: String?
    /// A later notification with the same tag replaces the earlier one on the device.
    let tag: String
}

/// Pushes to every registered device when a session needs the user: a request waits, a turn ended, or the
/// agent exited. Sending is fire-and-forget; the app's own lists stay the record if a push is lost.
public final class PushNotifier: @unchecked Sendable {
    /// Push services want a way to reach the sender (RFC 8292 §2.1); the project page is one.
    static let contact = "https://github.com/hustshawn/agent-master"
    static let bodyLimit = 160

    public let store: PushSubscriptionStore
    private let sender: WebPushSender

    init(dataDirectory: URL, transport: any WebPushTransport) throws {
        store = PushSubscriptionStore(url: dataDirectory.appendingPathComponent("push.json"))
        let keys = try VAPIDKeyPair.loadOrCreate(storageURL: dataDirectory.appendingPathComponent("vapid-key"))
        sender = WebPushSender(keys: keys, store: store, contact: Self.contact, transport: transport)
    }

    /// The browser's `applicationServerKey`.
    public var publicKey: String { sender.keys.publicKeyBase64URL }

    func notify(_ payload: PushPayload, urgency: String = "normal") {
        let subscriptions = store.list()
        guard !subscriptions.isEmpty, let data = try? JSONEncoder().encode(payload) else { return }
        let sender = sender
        Task {
            await withTaskGroup(of: Void.self) { group in
                for subscription in subscriptions {
                    group.addTask { try? await sender.send(data, to: subscription, urgency: urgency) }
                }
            }
        }
    }

    public func sendTest() {
        notify(PushPayload(title: "AgentMaster", body: "Notifications work on this device.", sessionId: nil, tag: "test"))
    }

    static func clipped(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > bodyLimit ? String(line.prefix(bodyLimit)) + "…" : line
    }
}
