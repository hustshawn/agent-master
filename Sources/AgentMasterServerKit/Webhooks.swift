import Foundation
import Logging

/// Where else the server says a session needs the user, next to Web Push (ADR 0017): `notifications` in
/// settings.json. Every key may be missing.
public struct NotificationSettings: Codable, Equatable, Sendable {
    public struct Webhook: Codable, Equatable, Sendable {
        /// Stable across edits, so Settings can send back a masked URL and the right stored one is kept: several
        /// webhooks on one host (two Telegram bots) mask to the same text.
        public var id: String
        /// A secret: an ntfy topic or a Telegram bot token is in it. Shown masked (see `masked`), never logged.
        public var url: String
        /// "ntfy", "telegram" or "json".
        public var format: String

        public init(id: String = UUID().uuidString, url: String, format: String) {
            self.id = id
            self.url = url
            self.format = format
        }

        /// A webhook written before ids existed, or added in Settings, gets a new one.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
            url = try container.decode(String.self, forKey: .url)
            format = try container.decode(String.self, forKey: .format)
        }
    }

    public var webhooks: [Webhook]
    /// The address browsers reach the server at (behind a proxy the server cannot know it), for the link in a
    /// notification; without it there is no link.
    public var publicURL: String?
    /// The kinds of event webhooks post (see `WebhookEvent.kind`). A finished turn is off by default, as on
    /// the Mac: one post per turn per session is noise on a phone.
    public var events: [String]

    public init(webhooks: [Webhook] = [], publicURL: String? = nil, events: [String] = Self.defaultEvents) {
        self.webhooks = webhooks
        self.publicURL = publicURL
        self.events = events
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        webhooks = try container.decodeIfPresent([Webhook].self, forKey: .webhooks) ?? []
        publicURL = try container.decodeIfPresent(String.self, forKey: .publicURL)
        events = try container.decodeIfPresent([String].self, forKey: .events) ?? Self.defaultEvents
    }

    public static let formats = ["ntfy", "telegram", "json"]
    public static let eventKinds = ["approval", "question", "policy", "turn", "exit"]
    public static let defaultEvents = ["approval", "question", "policy", "exit"]
    static let mask = "••••"

    /// An http(s) URL with a host, or one still masked (`merging` keeps the stored URL for it).
    public static func isPostable(_ url: String) -> Bool {
        if url.contains(mask) { return true }
        guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
              let host = components.host else { return false }
        return (scheme == "http" || scheme == "https") && !host.isEmpty
    }

    /// The scheme and host only, so Settings can show which service a webhook goes to without its secret.
    public static func masked(_ url: String) -> String {
        guard let components = URLComponents(string: url), let scheme = components.scheme, let host = components.host else {
            return mask
        }
        return "\(scheme)://\(host)/\(mask)"
    }

    /// These settings as Settings shows them: webhook URLs masked.
    public var masked: NotificationSettings {
        NotificationSettings(webhooks: webhooks.map { Webhook(id: $0.id, url: Self.masked($0.url), format: $0.format) },
                             publicURL: publicURL, events: events)
    }

    /// `incoming` from Settings, where a webhook whose URL is still the masked form keeps the stored URL with
    /// its id; one with a masked URL and no stored match is dropped, as its URL is unknown.
    public func merging(_ incoming: NotificationSettings) -> NotificationSettings {
        let stored = Dictionary(webhooks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = incoming.webhooks.compactMap { hook -> Webhook? in
            guard hook.url.contains(Self.mask) else { return hook }
            guard let old = stored[hook.id] else { return nil }
            return Webhook(id: old.id, url: old.url, format: hook.format)
        }
        let publicURL = incoming.publicURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        return NotificationSettings(webhooks: kept, publicURL: publicURL?.isEmpty == false ? publicURL : nil,
                                    events: incoming.events)
    }
}

/// What a webhook says. Only the kind of event and the session's name: webhooks go through third parties,
/// so no command, tool input, question, reply or path (they may hold secrets). Web Push is end-to-end
/// encrypted and keeps its fuller text.
struct WebhookEvent: Equatable {
    /// "approval", "question", "policy", "turn" or "exit".
    let kind: String
    let sessionId: String
    let sessionTitle: String

    var title: String {
        let heading = ["approval": "Approval needed", "question": "Question", "policy": "Policy check",
                       "turn": "Turn finished", "exit": "Agent exited"][kind] ?? "AgentMaster"
        return "\(heading) · \(sessionTitle)"
    }

    var body: String {
        ["turn": "Ready for your next message.", "exit": "The agent quit."][kind] ?? "A session is waiting for you in AgentMaster."
    }
}

/// Posts each event to every configured webhook. Fire-and-forget, as Web Push: 5 s, no retry, a failure is
/// only logged (without the URL), and nothing waits on it, least of all a hook's reply.
final class WebhookNotifier: @unchecked Sendable {
    private let settings: @Sendable () -> NotificationSettings
    private let transport: any WebPushTransport
    private let logger = Logger(label: "agentmaster.webhooks")

    init(settings: @escaping @Sendable () -> NotificationSettings, transport: any WebPushTransport) {
        self.settings = settings
        self.transport = transport
    }

    func notify(_ event: WebhookEvent) {
        let current = settings()
        guard !current.webhooks.isEmpty, current.events.contains(event.kind) else { return }
        let requests = current.webhooks.compactMap { Self.request(for: event, webhook: $0, publicURL: current.publicURL) }
        let transport = transport, logger = logger
        Task {
            await withTaskGroup(of: Void.self) { group in
                for (format, url, headers, body) in requests {
                    group.addTask {
                        do {
                            let status = try await transport.post(url: url, headers: headers, body: body)
                            if !(200..<300).contains(status) { logger.warning("A \(format) webhook answered \(status).") }
                        } catch {
                            logger.warning("A \(format) webhook failed: \(type(of: error)).")
                        }
                    }
                }
            }
        }
    }

    /// The HTTP request one webhook gets; nil for an unknown format or a URL that does not parse.
    static func request(for event: WebhookEvent, webhook: NotificationSettings.Webhook,
                        publicURL: String?) -> (format: String, url: URL, headers: [String: String], body: Data)? {
        // Telegram's URL carries the bot token, so never over plain HTTP (review of #19, N3).
        guard let url = URL(string: webhook.url), url.scheme == "https" || (url.scheme == "http" && webhook.format != "telegram")
        else { return nil }
        let link = publicURL.map { base in
            (base.hasSuffix("/") ? String(base.dropLast()) : base) + "/#session=" + event.sessionId
        }
        switch webhook.format {
        case "ntfy":
            // ntfy reads the title and the click-through link from headers (docs.ntfy.sh/publish).
            var headers = ["Title": headerValue(event.title), "Content-Type": "text/plain; charset=utf-8"]
            if let link { headers["Click"] = link }
            return (webhook.format, url, headers, Data(event.body.utf8))
        case "telegram":
            // The URL is the bot's sendMessage with its chat_id in the query: only the text goes here.
            let text = ([event.title, event.body] + (link.map { [$0] } ?? [])).joined(separator: "\n")
            return (webhook.format, url, ["Content-Type": "application/json"], json(["text": text]))
        case "json":
            var fields: [String: String] = ["sessionId": event.sessionId, "kind": event.kind, "title": event.title,
                                            "body": event.body]
            if let link { fields["url"] = link }
            return (webhook.format, url, ["Content-Type": "application/json"], json(fields))
        default:
            return nil
        }
    }

    /// HTTP header values are ASCII; anything else goes as an RFC 2047 encoded word, which ntfy decodes.
    static func headerValue(_ text: String) -> String {
        let plain = text.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 && $0.value != 0x7F }
        return plain ? text : "=?UTF-8?B?" + Data(text.utf8).base64EncodedString() + "?="
    }

    private static func json(_ fields: [String: String]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(fields)) ?? Data()
    }
}
