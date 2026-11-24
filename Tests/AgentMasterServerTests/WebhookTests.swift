import XCTest
import AgentMasterCore
@testable import AgentMasterServerKit

/// Webhook notifications (ADR 0017), checked offline: the request each format gets, and the secrets kept out of sight.
final class WebhookTests: XCTestCase {
    private let event = WebhookEvent(kind: "approval", sessionId: "S1", sessionTitle: "Fix the tests")

    private func request(_ format: String, url: String = "https://ntfy.sh/secret-topic",
                         publicURL: String? = "https://box.example.ts.net/") throws
        -> (format: String, url: URL, headers: [String: String], body: Data) {
        try XCTUnwrap(WebhookNotifier.request(for: event, webhook: .init(url: url, format: format), publicURL: publicURL))
    }

    func testNtfyGetsTheTitleAndLinkInHeadersAndAShortBody() throws {
        let ntfy = try request("ntfy")
        XCTAssertEqual(ntfy.url.absoluteString, "https://ntfy.sh/secret-topic")
        XCTAssertEqual(ntfy.headers["Title"], WebhookNotifier.headerValue("Approval needed · Fix the tests"))
        XCTAssertEqual(ntfy.headers["Click"], "https://box.example.ts.net/#session=S1", "no token in the link")
        XCTAssertEqual(String(decoding: ntfy.body, as: UTF8.self), "A session is waiting for you in AgentMaster.")
        XCTAssertNil(try request("ntfy", publicURL: nil).headers["Click"], "no public address, no link")
    }

    func testANonAsciiTitleIsAnEncodedWord() {
        let value = WebhookNotifier.headerValue("Question · 修复测试")
        XCTAssertTrue(value.hasPrefix("=?UTF-8?B?") && value.hasSuffix("?="), value)
        let encoded = String(value.dropFirst(10).dropLast(2))
        XCTAssertEqual(Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) }, "Question · 修复测试")
        XCTAssertEqual(WebhookNotifier.headerValue("Plain title"), "Plain title")
    }

    func testTelegramAndJsonCarryOnlyTheEventAndTheSessionName() throws {
        let telegram = try request("telegram", url: "https://api.telegram.org/bot123:ABC/sendMessage?chat_id=42")
        let text = try JSONDecoder().decode([String: String].self, from: telegram.body)["text"]
        XCTAssertEqual(text, "Approval needed · Fix the tests\nA session is waiting for you in AgentMaster.\n" +
                             "https://box.example.ts.net/#session=S1")
        let json = try JSONDecoder().decode([String: String].self, from: try request("json").body)
        XCTAssertEqual(json, ["sessionId": "S1", "kind": "approval", "title": "Approval needed · Fix the tests",
                              "body": "A session is waiting for you in AgentMaster.",
                              "url": "https://box.example.ts.net/#session=S1"])
        XCTAssertNil(WebhookNotifier.request(for: event, webhook: .init(url: "https://x.example", format: "smtp"), publicURL: nil))
        XCTAssertNil(WebhookNotifier.request(for: event, webhook: .init(url: "file:///etc/passwd", format: "json"), publicURL: nil))
    }

    func testURLsAreMaskedAndAMaskedURLKeepsTheStoredOne() {
        let stored = NotificationSettings(webhooks: [.init(url: "https://ntfy.sh/secret-topic", format: "ntfy"),
                                                     .init(url: "https://api.telegram.org/bot1:X/sendMessage?chat_id=1",
                                                           format: "telegram")])
        let shown = stored.masked
        XCTAssertEqual(shown.webhooks.map(\.url), ["https://ntfy.sh/••••", "https://api.telegram.org/••••"])
        // Settings sends the list back with the first one's format changed, the second removed and a new one added.
        let incoming = NotificationSettings(webhooks: [.init(url: "https://ntfy.sh/••••", format: "json"),
                                                       .init(url: "https://hooks.example/new", format: "json")],
                                            publicURL: "  ")
        let merged = stored.merging(incoming)
        XCTAssertEqual(merged.webhooks, [.init(url: "https://ntfy.sh/secret-topic", format: "json"),
                                         .init(url: "https://hooks.example/new", format: "json")])
        XCTAssertNil(merged.publicURL, "blank is no address")
    }

    func testOlderSettingsDecodeWithoutTheKeys() throws {
        XCTAssertEqual(try JSONDecoder().decode(NotificationSettings.self, from: Data("{}".utf8)), NotificationSettings())
    }
}
