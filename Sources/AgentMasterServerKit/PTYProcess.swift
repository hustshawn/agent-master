import Foundation
import CPTY
#if canImport(Glibc)
import Glibc
private let posixWrite = Glibc.write
#else
import Darwin
private let posixWrite = Darwin.write
#endif

/// One agent process in a pseudo-terminal. Output is kept in a bounded scrollback, so a browser that
/// connects later (or reconnects) sees the screen, and is fanned out to every connected browser.
public final class PTYProcess: @unchecked Sendable {
    /// Enough for a TUI's recent history; older output is dropped from the front.
    public static let scrollbackLimit = 2 * 1024 * 1024

    public let pid: pid_t
    private let fd: Int32
    private let queue = DispatchQueue(label: "agentmaster.pty")
    private var source: DispatchSourceRead?
    private let lock = NSLock()
    private var scrollback = Data()
    private var subscribers: [UUID: @Sendable (Data) -> Void] = [:]
    private var exitStatus: Int32?
    private var exitHandler: (@Sendable (Int32) -> Void)?

    public enum SpawnError: Error, CustomStringConvertible {
        case failed(Int32)
        public var description: String { "could not start the agent (\(String(cString: strerror(errnoValue))))" }
        private var errnoValue: Int32 { if case let .failed(code) = self { return code }; return 0 }
    }

    public init(executable: String, arguments: [String], environment: [String: String], directory: String,
                columns: UInt16 = 120, rows: UInt16 = 36) throws {
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var master: Int32 = -1
        let pid = argv.withUnsafeBufferPointer { argvPointer in
            envp.withUnsafeBufferPointer { envpPointer in
                cpty_spawn(executable, argvPointer.baseAddress, envpPointer.baseAddress, directory, rows, columns, &master)
            }
        }
        guard pid > 0 else { throw SpawnError.failed(errno) }
        self.pid = pid
        fd = master
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        startReading()
        startWaiting()
    }

    /// Called once, when the process exits, with its raw wait status.
    public func onExit(_ handler: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        let status = exitStatus
        if status == nil { exitHandler = handler }
        lock.unlock()
        if let status { handler(status) }
    }

    public var hasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exitStatus != nil
    }

    /// Registers `handler` for new output and returns the scrollback so far, with no gap in between.
    public func subscribe(_ handler: @escaping @Sendable (Data) -> Void) -> (token: UUID, scrollback: Data) {
        lock.lock()
        defer { lock.unlock() }
        let token = UUID()
        subscribers[token] = handler
        return (token, scrollback)
    }

    public func unsubscribe(_ token: UUID) {
        lock.lock()
        subscribers[token] = nil
        lock.unlock()
    }

    public func write(_ data: Data) {
        queue.async { [fd] in
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                var stalls = 0
                while offset < raw.count {
                    let written = posixWrite(fd, base + offset, raw.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0 && (errno == EAGAIN || errno == EINTR) && stalls < 200 {
                        stalls += 1
                        usleep(5_000)   // the agent is not reading; give it up to a second
                    } else {
                        return
                    }
                }
            }
        }
    }

    public func resize(columns: UInt16, rows: UInt16) {
        guard columns > 0, rows > 0 else { return }
        _ = cpty_resize(fd, rows, columns)
    }

    /// Hangs up the terminal's process group, then kills it if it is still there after two seconds.
    public func terminate() {
        guard !hasExited else { return }
        kill(-pid, SIGHUP)
        kill(pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            if !hasExited { kill(-pid, SIGKILL) }
        }
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [fd] in _ = close(fd) }
        self.source = source
        source.resume()
    }

    private func readAvailable() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                deliver(Data(chunk[0..<count]))
                if count < chunk.count { return }
            } else if count < 0 && (errno == EAGAIN || errno == EINTR) {
                return
            } else {
                // EOF, or EIO once every process holding the terminal has gone.
                source?.cancel()
                source = nil
                return
            }
        }
    }

    private func deliver(_ data: Data) {
        lock.lock()
        scrollback.append(data)
        if scrollback.count > Self.scrollbackLimit {
            // Cut at a line break so the replay does not start in the middle of an escape sequence.
            var cut = scrollback.count - Self.scrollbackLimit / 2
            if let newline = scrollback[(scrollback.startIndex + cut)...].firstIndex(of: 0x0A) {
                cut = newline - scrollback.startIndex + 1
            }
            scrollback = Data(scrollback.dropFirst(cut))
        }
        let handlers = Array(subscribers.values)
        lock.unlock()
        handlers.forEach { $0(data) }
    }

    private func startWaiting() {
        let thread = Thread { [self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            lock.lock()
            exitStatus = status
            let handler = exitHandler
            exitHandler = nil
            lock.unlock()
            handler?(status)
        }
        thread.name = "agentmaster.pty.wait"
        thread.start()
    }
}
