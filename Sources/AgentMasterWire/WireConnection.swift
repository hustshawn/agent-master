import Foundation

public protocol WireConnection: AnyObject {
    /// `line` is a message already encoded with `WireCodec.encodeLine`.
    func send(_ line: Data) throws
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

    func send(_ line: Data) throws {
        try socket.write(line)
    }

    func receiveReply(timeout: TimeInterval) throws -> WireReply {
        try WireCodec.decode(WireReply.self, line: socket.readLine(timeout: timeout))
    }

    func close() {
        socket.close()
    }
}
