import Foundation
import AgentMasterWire

/// Accepts `agentmaster-hook` connections on the app socket. A single accept thread reads each
/// connection's one message itself, so the handler sees hook events in the order Claude Code sent them.
public final class HookServer {
    public typealias Reply = (String?) -> Void
    public typealias Handler = (WireMessage, @escaping Reply) -> Void

    public let socketPath: String
    private let handler: Handler
    private let lock = NSLock()
    private var running = false
    private var pending: [String: UnixSocketConnection] = [:]
    private var finished: DispatchSemaphore?

    public init(socketPath: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    public var pendingCount: Int {
        sync { pending.count }
    }

    public func start() throws {
        let listener = try UnixSocketListener(path: socketPath)
        let finished = DispatchSemaphore(value: 0)
        sync {
            running = true
            self.finished = finished
        }
        let thread = Thread { [self] in
            acceptLoop(listener)
            listener.close()   // closed on this thread so the fd is never closed under a poll()
            finished.signal()
        }
        thread.name = "AgentMaster.HookServer"
        thread.start()
    }

    /// Releases every waiting shim; each prints nothing, so Claude Code falls back to its own UI.
    public func stop() {
        let (connections, finished) = sync { () -> ([UnixSocketConnection], DispatchSemaphore?) in
            running = false
            let connections = Array(pending.values)
            pending = [:]
            let finished = self.finished
            self.finished = nil
            return (connections, finished)
        }
        connections.forEach { $0.close() }
        _ = finished?.wait(timeout: .now() + 2)
    }

    private func acceptLoop(_ listener: UnixSocketListener) {
        while sync({ running }) {
            let accepted: UnixSocketConnection?
            do {
                accepted = try listener.accept(timeout: 0.2)
            } catch {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            guard let connection = accepted else { continue }
            // Keep this read bound small. Reads are serial on this one thread (that is what keeps events
            // in order), so a silent or stalled client delays every later event by up to this long, and
            // 1 s is already above the 300 ms hook-latency target. The shim encodes before connecting,
            // so a healthy client's line arrives immediately; do not raise this to accommodate slow ones.
            guard let line = try? connection.readLine(timeout: 1),
                  let message = try? WireCodec.decode(WireMessage.self, line: line) else {
                connection.close()
                continue
            }
            guard message.kind == .request else {
                connection.close()
                handler(message) { _ in }
                continue
            }
            let token = UUID().uuidString
            let registered = sync { () -> Bool in
                guard running else { return false }
                pending[token] = connection
                return true
            }
            guard registered else {
                connection.close()
                continue
            }
            handler(message) { [weak self] output in
                self?.reply(token: token, id: message.id, output: output)
            }
        }
    }

    private func reply(token: String, id: String, output: String?) {
        // removeValue makes a second reply, or one after stop(), a no-op.
        guard let connection = sync({ pending.removeValue(forKey: token) }) else { return }
        if let line = try? WireCodec.encodeLine(WireReply(id: id, output: output)) {
            try? connection.write(line)   // the shim may have timed out; SO_NOSIGPIPE makes this safe
        }
        connection.close()
    }

    private func sync<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
