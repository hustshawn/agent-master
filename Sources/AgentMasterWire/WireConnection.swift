import Foundation

public protocol WireConnection: AnyObject {
    func send(_ message: WireMessage) throws
    func receiveReply(timeout: TimeInterval) throws -> WireReply
    func close()
}

public protocol WireConnector {
    func connect() throws -> WireConnection
}

public struct UnixWireConnector: WireConnector {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func connect() throws -> WireConnection {
        UnixWireConnection(socket: try UnixSocket.connect(path: path))
    }
}

final class UnixWireConnection: WireConnection {
    private let socket: UnixSocketConnection

    init(socket: UnixSocketConnection) {
        self.socket = socket
    }

    func send(_ message: WireMessage) throws {
        try socket.write(WireCodec.encodeLine(message))
    }

    func receiveReply(timeout: TimeInterval) throws -> WireReply {
        try WireCodec.decode(WireReply.self, line: socket.readLine(timeout: timeout))
    }

    func close() {
        socket.close()
    }
}
