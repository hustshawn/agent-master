import XCTest
import Foundation
import Crypto
@testable import AgentMasterServerKit

/// RFC 8291 Appendix A gives the exact keys, salt and plaintext for one message, plus the ciphertext
/// they must produce: the strongest possible check that the key derivation and framing are right.
final class WebPushEncryptionTests: XCTestCase {
    func testEncryptsTheRFC8291AppendixAVectorByteForByte() throws {
        let plaintext = Data("When I grow up, I want to be a watermelon".utf8)
        let receiverPublicKey = try decode("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4")
        let authSecret = try decode("BTBZMqHH6r4Tts7J_aSIgg")
        let salt = try decode("DGv6ra1nlYgDCS1FRnbzlw")
        let senderKey = try P256.KeyAgreement.PrivateKey(rawRepresentation: decode("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"))

        let body = try WebPushEncryption.encrypt(plaintext, receiverPublicKey: receiverPublicKey, authSecret: authSecret,
                                                 salt: salt, senderKey: senderKey)

        let expectedHeader = try decode(
            "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8")
        let expectedCiphertext = try decode("8pfeW0KbunFT06SuDKoJH9Ql87S1QUrdirN6GcG7sFz1y1sqLgVi1VhjVkHsUoEsbI_0LpXMuGvnzQ")
        XCTAssertEqual(body, expectedHeader + expectedCiphertext)
    }

    func testAnInvalidReceiverKeyIsRejected() {
        XCTAssertThrowsError(try WebPushEncryption.encrypt(Data("hi".utf8), receiverPublicKey: Data([1, 2, 3]),
                                                           authSecret: WebPushEncryption.randomBytes(16)))
    }

    private func decode(_ string: String) throws -> Data {
        try XCTUnwrap(Base64URL.decode(string))
    }
}

/// RFC 8292 VAPID: the Authorization header must carry a well-formed, correctly signed JWT.
final class VAPIDAuthorizationTests: XCTestCase {
    private struct Claims: Decodable { let aud: String; let exp: Int; let sub: String }

    func testTheHeaderCarriesAJWTThatVerifiesWithThePublicKeyItAdvertises() throws {
        let keys = VAPIDKeyPair(privateKey: P256.Signing.PrivateKey())
        let endpoint = URL(string: "https://push.example.net/some/resource/path")!
        let header = try VAPIDAuthorization.header(for: endpoint, keys: keys, contact: "ops@example.com",
                                                   now: Date(timeIntervalSince1970: 1_000_000))

        XCTAssertTrue(header.hasPrefix("vapid t="))
        let parameters = header.dropFirst("vapid ".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let tParameter = parameters.first(where: { $0.hasPrefix("t=") }),
              let kParameter = parameters.first(where: { $0.hasPrefix("k=") }) else {
            return XCTFail("missing t= or k= parameter in \(header)")
        }
        XCTAssertEqual(String(kParameter.dropFirst(2)), keys.publicKeyBase64URL)

        let segments = tParameter.dropFirst(2).split(separator: ".")
        XCTAssertEqual(segments.count, 3, "a JWT is header.claims.signature")
        let headerJSON = try XCTUnwrap(Base64URL.decode(String(segments[0])))
        XCTAssertEqual(String(decoding: headerJSON, as: UTF8.self), #"{"typ":"JWT","alg":"ES256"}"#)

        let claimsJSON = try XCTUnwrap(Base64URL.decode(String(segments[1])))
        let claims = try JSONDecoder().decode(Claims.self, from: claimsJSON)
        XCTAssertEqual(claims.aud, "https://push.example.net", "aud must be the origin, not the full endpoint")
        XCTAssertEqual(claims.sub, "mailto:ops@example.com")
        XCTAssertEqual(claims.exp, 1_000_000 + 12 * 3600)

        let signature = try P256.Signing.ECDSASignature(rawRepresentation: XCTUnwrap(Base64URL.decode(String(segments[2]))))
        let signingInput = Data("\(segments[0]).\(segments[1])".utf8)
        XCTAssertTrue(keys.privateKey.publicKey.isValidSignature(signature, for: signingInput))
    }

    func testABareContactIsWrappedAsMailto() {
        XCTAssertEqual(VAPIDAuthorization.subject("a@b.com"), "mailto:a@b.com")
        XCTAssertEqual(VAPIDAuthorization.subject("https://example.com/contact"), "https://example.com/contact")
        XCTAssertEqual(VAPIDAuthorization.subject(), "mailto:agentmaster@localhost")
    }

    func testKeyPairIsCreatedOnceAndReloadedFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-vapid-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("vapid-key")

        let first = try VAPIDKeyPair.loadOrCreate(storageURL: url)
        let second = try VAPIDKeyPair.loadOrCreate(storageURL: url)
        XCTAssertEqual(first.publicKeyBase64URL, second.publicKeyBase64URL)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600)
    }
}

/// `<data-dir>/push.json`: subscriptions dedupe by endpoint and survive a reload.
final class PushSubscriptionStoreTests: XCTestCase {
    func testAddDedupesByEndpointAndPersistsAcrossInstances() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-push-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("push.json")

        let store = PushSubscriptionStore(url: url)
        let endpoint = "https://push.example.net/subscription/a"
        store.add(PushSubscription(endpoint: endpoint, keys: .init(p256dh: "p", auth: "a"), label: "iPhone"))
        store.add(PushSubscription(endpoint: endpoint, keys: .init(p256dh: "p2", auth: "a2"), label: "iPhone"))
        XCTAssertEqual(store.list().count, 1, "re-subscribing at the same endpoint replaces the old keys")
        XCTAssertEqual(store.list().first?.keys.p256dh, "p2")

        let reloaded = PushSubscriptionStore(url: url)
        XCTAssertEqual(reloaded.list(), store.list())

        store.remove(endpoint: endpoint)
        XCTAssertEqual(store.list(), [])
        XCTAssertEqual(PushSubscriptionStore(url: url).list(), [], "the removal must have been persisted too")
    }
}

/// `WebPushSender`: a gone subscription must be dropped from the store, not just reported.
final class WebPushSenderTests: XCTestCase {
    private struct FakeTransport: WebPushTransport {
        let status: Int
        func post(url: URL, headers: [String: String], body: Data) async throws -> Int { status }
    }

    private func makeSubscription(endpoint: String) -> PushSubscription {
        let receiverKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        return PushSubscription(endpoint: endpoint,
                                keys: .init(p256dh: Base64URL.encode(receiverKey),
                                           auth: Base64URL.encode(WebPushEncryption.randomBytes(16))))
    }

    func test410RemovesTheSubscriptionFromTheStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-push-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PushSubscriptionStore(url: dir.appendingPathComponent("push.json"))
        let subscription = makeSubscription(endpoint: "https://push.example.net/subscription/gone")
        store.add(subscription)

        let sender = WebPushSender(keys: VAPIDKeyPair(privateKey: P256.Signing.PrivateKey()), store: store,
                                   transport: FakeTransport(status: 410))
        do {
            try await sender.send(Data("hello".utf8), to: subscription)
            XCTFail("expected WebPushError.gone")
        } catch WebPushError.gone {
            // expected
        }
        XCTAssertTrue(store.list().isEmpty)
    }

    func test404AlsoRemovesTheSubscription() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-push-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PushSubscriptionStore(url: dir.appendingPathComponent("push.json"))
        let subscription = makeSubscription(endpoint: "https://push.example.net/subscription/also-gone")
        store.add(subscription)

        let sender = WebPushSender(keys: VAPIDKeyPair(privateKey: P256.Signing.PrivateKey()), store: store,
                                   transport: FakeTransport(status: 404))
        await XCTAssertThrowsErrorAsync(try await sender.send(Data("hello".utf8), to: subscription))
        XCTAssertTrue(store.list().isEmpty)
    }

    func testASuccessfulSendLeavesTheSubscriptionInPlace() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-push-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PushSubscriptionStore(url: dir.appendingPathComponent("push.json"))
        let subscription = makeSubscription(endpoint: "https://push.example.net/subscription/ok")
        store.add(subscription)

        let sender = WebPushSender(keys: VAPIDKeyPair(privateKey: P256.Signing.PrivateKey()), store: store,
                                   transport: FakeTransport(status: 201))
        try await sender.send(Data("hello".utf8), to: subscription)
        XCTAssertEqual(store.list().count, 1)
    }
}

func XCTAssertThrowsErrorAsync(_ expression: @autoclosure () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await expression()
        XCTFail("expected an error to be thrown", file: file, line: line)
    } catch {
        // expected
    }
}
