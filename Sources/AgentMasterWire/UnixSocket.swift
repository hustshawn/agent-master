import Foundation

public enum UnixSocketError: Error, Equatable {
    case pathTooLong
    case system(String, Int32)
    case timeout
    case closed
}

func makeSocketAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw UnixSocketError.pathTooLong }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)   // the rest is already zero, so the path is NUL-terminated
    }
    return address
}

private func withSockaddr<T>(_ address: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

public enum UnixSocket {
    public static func connect(path: String) throws -> UnixSocketConnection {
        let address = try makeSocketAddress(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.system("socket", errno) }
        let result = withSockaddr(address) { Darwin.connect(fd, $0, $1) }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.system("connect", code)
        }
        return UnixSocketConnection(fd: fd)
    }
}

/// One connected stream. `write`/`close` may be called from any thread; `readLine` from one reader.
public final class UnixSocketConnection {
    private let fd: Int32
    private let lock = NSLock()
    private var isClosed = false
    private var buffer = LineBuffer()
    private var lines: [Data] = []

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        close()
    }

    public func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        // Checked under the lock so a late writer can never hit a closed-and-reused fd.
        guard !isClosed else { throw UnixSocketError.closed }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw UnixSocketError.system("write", errno)
                }
                offset += written
            }
        }
    }

    public func readLine(timeout: TimeInterval? = nil) throws -> Data {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            if !lines.isEmpty { return lines.removeFirst() }
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { throw UnixSocketError.timeout }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, Int32(max(1, min(remaining * 1000, 60_000))))
                if ready == 0 { continue }
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw UnixSocketError.system("poll", errno)
                }
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw UnixSocketError.system("read", errno)
            }
            if count == 0 { throw UnixSocketError.closed }
            lines.append(contentsOf: buffer.append(Data(chunk[0..<count])))
        }
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fd)
    }
}

public final class UnixSocketListener {
    public let path: String
    private let fd: Int32
    private let lock = NSLock()
    private var isClosed = false

    public init(path: String) throws {
        let address = try makeSocketAddress(path)
        unlink(path)   // a crashed previous run may have left the file behind
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError.system("socket", errno) }
        guard withSockaddr(address, { bind(fd, $0, $1) }) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw UnixSocketError.system("bind", code)
        }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(path)
            throw UnixSocketError.system("listen", code)
        }
        self.path = path
        self.fd = fd
    }

    deinit {
        close()
    }

    /// Returns nil when nothing connected within `timeout`.
    public func accept(timeout: TimeInterval) throws -> UnixSocketConnection? {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, Int32(timeout * 1000))
        if ready == 0 { return nil }
        if ready < 0 {
            if errno == EINTR { return nil }
            throw UnixSocketError.system("poll", errno)
        }
        let client = Darwin.accept(fd, nil, nil)
        if client < 0 {
            if errno == EINTR || errno == ECONNABORTED || errno == EAGAIN { return nil }
            throw UnixSocketError.system("accept", errno)
        }
        return UnixSocketConnection(fd: client)
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fd)
        unlink(path)
    }
}
