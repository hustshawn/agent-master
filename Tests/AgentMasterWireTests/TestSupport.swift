import Foundation
@testable import AgentMasterWire

final class FakeConnection: WireConnection {
    var sent: [WireMessage] = []
    var reply: Result<WireReply, Error> = .failure(UnixSocketError.timeout)
    var receiveTimeout: TimeInterval?
    var closed = false

    func send(_ message: WireMessage) throws { sent.append(message) }

    func receiveReply(timeout: TimeInterval) throws -> WireReply {
        receiveTimeout = timeout
        return try reply.get()
    }

    func close() { closed = true }
}

struct FakeConnector: WireConnector {
    let connection: FakeConnection?

    func connect() throws -> WireConnection {
        guard let connection else { throw UnixSocketError.system("connect", ECONNREFUSED) }
        return connection
    }
}
