import Foundation
import AsyncHTTPClient
import NIOCore

/// One browser's Web Push subscription (the result of `pushManager.subscribe()`), as needed to encrypt
/// and address a push message (RFC 8291/RFC 8030).
public struct PushSubscription: Codable, Sendable, Equatable {
    public struct Keys: Codable, Sendable, Equatable {
        public var p256dh: String
        public var auth: String

        public init(p256dh: String, auth: String) {
            self.p256dh = p256dh
            self.auth = auth
        }
    }

    public var endpoint: String
    public var keys: Keys
    public var createdAt: Date
    /// A user-agent or device label from the browser, so Settings can show which device this is.
    public var label: String?

    public init(endpoint: String, keys: Keys, createdAt: Date = Date(), label: String? = nil) {
        self.endpoint = endpoint
        self.keys = keys
        self.createdAt = createdAt
        self.label = label
    }
}

/// Push subscriptions persisted as JSON at `<data-dir>/push.json`, the same atomic-write-plus-lock
/// style as `ServerSettings`, so a browser's subscription survives server restarts.
public final class PushSubscriptionStore: @unchecked Sendable {
    private struct Stored: Codable { var subscriptions: [PushSubscription] = [] }

    private let url: URL
    private let lock = NSLock()
    private var stored: Stored

    public init(url: URL) {
        self.url = url
        stored = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    /// Replaces any existing subscription with the same endpoint: a browser that subscribes again at the
    /// same push resource has rotated its keys, so the old ones are no longer any good.
    public func add(_ subscription: PushSubscription) {
        write { stored in
            stored.subscriptions.removeAll { $0.endpoint == subscription.endpoint }
            stored.subscriptions.append(subscription)
        }
    }

    public func remove(endpoint: String) {
        write { stored in stored.subscriptions.removeAll { $0.endpoint == endpoint } }
    }

    public func list() -> [PushSubscription] {
        read(\.subscriptions)
    }

    private func read<T>(_ body: (Stored) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(stored)
    }

    private func write(_ body: (inout Stored) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(stored) { try? data.write(to: url, options: .atomic) }
    }
}

/// What `WebPushSender` needs from HTTP: swapped for a scripted response in tests, so the encryption and
/// JWT logic can be verified without a real network call. `HTTPClientWebPushTransport` is the live one.
public protocol WebPushTransport: Sendable {
    func post(url: URL, headers: [String: String], body: Data) async throws -> Int
}

/// The live `WebPushTransport`, over AsyncHTTPClient: SwiftNIO like the rest of the server, where
/// URLSession on Linux would add a libcurl dependency to the server package.
public struct HTTPClientWebPushTransport: WebPushTransport {
    public init() {}

    public func post(url: URL, headers: [String: String], body: Data) async throws -> Int {
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .POST
        for (field, value) in headers { request.headers.add(name: field, value: value) }
        request.body = .bytes(ByteBuffer(bytes: body))
        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(30))
        return Int(response.status.code)
    }
}

public enum WebPushError: Error, CustomStringConvertible {
    /// The subscription's endpoint or keys could not even be parsed; there is nothing to send to.
    case invalidSubscription
    /// The push service reported the subscription no longer exists (404 or 410); it has been removed.
    case gone
    case rejected(Int)

    public var description: String {
        switch self {
        case .invalidSubscription: return "The push subscription's endpoint or keys are not valid."
        case .gone: return "The push subscription no longer exists."
        case .rejected(let status): return "The push service rejected the message (\(status))."
        }
    }
}

/// Sends Web Push messages (RFC 8030) with RFC 8291 encryption and an RFC 8292 VAPID Authorization
/// header. Removes a subscription from `store` the moment a push service reports it is gone.
public struct WebPushSender: Sendable {
    public var keys: VAPIDKeyPair
    public var store: PushSubscriptionStore
    public var contact: String
    public var transport: any WebPushTransport
    /// Seconds a push service may hold the message for if the user agent is offline (RFC 8030 §5.2).
    public var ttl: Int

    public init(keys: VAPIDKeyPair, store: PushSubscriptionStore, contact: String = "agentmaster@localhost",
               transport: any WebPushTransport = HTTPClientWebPushTransport(), ttl: Int = 24 * 60 * 60) {
        self.keys = keys
        self.store = store
        self.contact = contact
        self.transport = transport
        self.ttl = ttl
    }

    public func send(_ payload: Data, to subscription: PushSubscription, urgency: String = "normal") async throws {
        guard let endpoint = URL(string: subscription.endpoint),
              let receiverKey = Base64URL.decode(subscription.keys.p256dh),
              let authSecret = Base64URL.decode(subscription.keys.auth) else {
            throw WebPushError.invalidSubscription
        }
        let body = try WebPushEncryption.encrypt(payload, receiverPublicKey: receiverKey, authSecret: authSecret)
        let headers = [
            "Content-Type": "application/octet-stream",
            "Content-Encoding": "aes128gcm",
            "Authorization": try VAPIDAuthorization.header(for: endpoint, keys: keys, contact: contact),
            "TTL": String(ttl),
            "Urgency": urgency,
        ]
        let status = try await transport.post(url: endpoint, headers: headers, body: body)
        if status == 404 || status == 410 {
            store.remove(endpoint: subscription.endpoint)
            throw WebPushError.gone
        }
        guard (200...299).contains(status) else { throw WebPushError.rejected(status) }
    }
}
