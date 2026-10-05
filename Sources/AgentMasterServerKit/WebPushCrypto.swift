import Foundation
import Crypto

/// Base64url (RFC 4648 §5), unpadded: what Web Push subscriptions, VAPID keys and JWTs all use on the wire.
enum Base64URL {
    static func encode<D: DataProtocol>(_ data: D) -> String {
        Data(data).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) -> Data? {
        var padded = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded.append("=") }
        return Data(base64Encoded: padded)
    }
}

/// The server's VAPID (RFC 8292) signing identity: a P-256 key pair kept at `<data-dir>/vapid-key`
/// (mode 600, the private scalar as base64url text, like `ServerMain`'s `token` file), generated once
/// and reused so the browser's `applicationServerKey` and the "vapid" Authorization header stay stable
/// across restarts and across subscriptions.
public struct VAPIDKeyPair: Sendable {
    public let privateKey: P256.Signing.PrivateKey
    /// The uncompressed public point (0x04 || X || Y), base64url-encoded: passed to the browser as
    /// `applicationServerKey` for `pushManager.subscribe`, and as the "k" parameter below.
    public let publicKeyBase64URL: String

    public init(privateKey: P256.Signing.PrivateKey) {
        self.privateKey = privateKey
        publicKeyBase64URL = Base64URL.encode(privateKey.publicKey.x963Representation)
    }

    /// Loads the key pair from `storageURL`, generating and saving a new one the first time.
    public static func loadOrCreate(storageURL: URL) throws -> VAPIDKeyPair {
        if let text = try? String(contentsOf: storageURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let data = Base64URL.decode(text), let key = try? P256.Signing.PrivateKey(rawRepresentation: data) {
            return VAPIDKeyPair(privateKey: key)
        }
        let key = P256.Signing.PrivateKey()
        try Data(Base64URL.encode(key.rawRepresentation).utf8).write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
        return VAPIDKeyPair(privateKey: key)
    }
}

/// RFC 8292 VAPID: a self-identifying JWT an application server attaches to every push request, so a
/// push service can attribute requests to it without a prior registration step.
public enum VAPIDAuthorization {
    /// A bare contact address is wrapped as a "mailto:" URI, as RFC 8292 §2.1 recommends for the "sub" claim.
    public static func subject(_ contact: String = "agentmaster@localhost") -> String {
        contact.contains(":") ? contact : "mailto:\(contact)"
    }

    /// The scheme and host (and non-default port) a push endpoint belongs to: the "aud" claim must be
    /// exactly this origin (RFC 8292 §2), not the full endpoint path.
    public static func origin(of endpoint: URL) -> String {
        var origin = "\(endpoint.scheme ?? "https")://\(endpoint.host ?? "")"
        if let port = endpoint.port { origin += ":\(port)" }
        return origin
    }

    /// The "Authorization: vapid t=<jwt>, k=<key>" header value (RFC 8292 §3) for a request to `endpoint`.
    public static func header(for endpoint: URL, keys: VAPIDKeyPair, contact: String = "agentmaster@localhost",
                              expiresIn: TimeInterval = 12 * 3600, now: Date = Date()) throws -> String {
        let jwt = try makeJWT(audience: origin(of: endpoint), subject: subject(contact),
                              expiresAt: now.addingTimeInterval(expiresIn), privateKey: keys.privateKey)
        return "vapid t=\(jwt), k=\(keys.publicKeyBase64URL)"
    }

    /// A compact JWS (RFC 7515) with the "ES256" signature RFC 8292 requires: header and claims are
    /// built as literal JSON, not `JSONEncoder`, so the field order and spacing are exactly as signed.
    static func makeJWT(audience: String, subject: String, expiresAt: Date, privateKey: P256.Signing.PrivateKey) throws -> String {
        let header = Base64URL.encode(Data(#"{"typ":"JWT","alg":"ES256"}"#.utf8))
        let claims = #"{"aud":"\#(audience)","exp":\#(Int(expiresAt.timeIntervalSince1970)),"sub":"\#(subject)"}"#
        let signingInput = "\(header).\(Base64URL.encode(Data(claims.utf8)))"
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(Base64URL.encode(signature.rawRepresentation))"
    }
}

/// RFC 8291 message encryption ("aes128gcm" content coding): combines the subscriber's P-256 public key
/// and auth secret with a fresh per-message sender key pair and salt via ECDH + HKDF, then seals the
/// payload with AES-128-GCM as the single record a push message is restricted to (RFC 8291 §4).
public enum WebPushEncryption {
    public enum Error: Swift.Error, CustomStringConvertible {
        case invalidReceiverKey
        public var description: String { "The subscription's p256dh key is not a valid P-256 point." }
    }

    /// A push service need not support more than 4096 octets of record size (RFC 8291 §4).
    static let recordSize: UInt32 = 4096

    /// `receiverPublicKey` and `authSecret` are a subscription's `keys.p256dh` and `keys.auth`, already
    /// base64url-decoded. `salt` and `senderKey` default to fresh random values; both are parameters so
    /// tests can supply the RFC 8291 Appendix A vector exactly and still exercise the real code path.
    public static func encrypt(_ plaintext: Data, receiverPublicKey: Data, authSecret: Data,
                               salt: Data = randomBytes(16),
                               senderKey: P256.KeyAgreement.PrivateKey = P256.KeyAgreement.PrivateKey()) throws -> Data {
        guard let receiver = try? P256.KeyAgreement.PublicKey(x963Representation: receiverPublicKey) else {
            throw Error.invalidReceiverKey
        }
        let senderPublicKey = senderKey.publicKey.x963Representation
        let ecdhSecret = try senderKey.sharedSecretFromKeyAgreement(with: receiver).withUnsafeBytes { Data($0) }

        // RFC 8291 §3.3: combine the ECDH secret with the authentication secret into the IKM for RFC 8188.
        let keyInfo = Data("WebPush: info".utf8) + Data([0]) + receiverPublicKey + senderPublicKey
        let prkKey = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ecdhSecret), salt: authSecret)
        let ikm = HKDF<SHA256>.expand(pseudoRandomKey: prkKey, info: keyInfo, outputByteCount: 32)

        // RFC 8188 §2.1: derive the content-encryption key and nonce from the message salt and the IKM.
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: ikm, salt: salt)
        let cek = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data("Content-Encoding: aes128gcm".utf8) + Data([0]),
                                      outputByteCount: 16)
        let nonceKey = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data("Content-Encoding: nonce".utf8) + Data([0]),
                                           outputByteCount: 12)
        let nonce = try AES.GCM.Nonce(data: nonceKey.withUnsafeBytes { Data($0) })

        // A push message is always a single, final record (RFC 8291 §4): delimiter 0x02, no further padding.
        let sealed = try AES.GCM.seal(plaintext + Data([0x02]), using: cek, nonce: nonce)

        // RFC 8188 §2.1 header: salt || record size (4 bytes) || keyid length (1 byte) || keyid.
        var header = salt
        withUnsafeBytes(of: recordSize.bigEndian) { header.append(contentsOf: $0) }
        header.append(UInt8(senderPublicKey.count))
        header.append(senderPublicKey)
        return header + sealed.ciphertext + sealed.tag
    }

    public static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }
}
