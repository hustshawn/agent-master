import Foundation
import Hummingbird
import Logging
#if canImport(Glibc)
import Glibc
#endif

/// `agentmaster-server [--host 127.0.0.1] [--port 8765] [--data-dir ~/.agentmaster-server] [--token TOKEN]`
public enum ServerMain {
    public struct Options: Equatable {
        public var host = "127.0.0.1"
        public var port = 8765
        public var dataDirectory = NSHomeDirectory() + "/.agentmaster-server"
        /// Nil reads (or creates) `token` in the data directory; AGENTMASTER_SERVER_TOKEN also sets it.
        public var token: String?

        public init() {}

        public static func parse(_ arguments: [String], environment: [String: String]) throws -> Options {
            var options = Options()
            options.token = environment["AGENTMASTER_SERVER_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
            var iterator = arguments.makeIterator()
            while let argument = iterator.next() {
                func value() throws -> String {
                    guard let next = iterator.next() else { throw UsageError("\(argument) needs a value") }
                    return next
                }
                switch argument {
                case "--host": options.host = try value()
                case "--port":
                    let text = try value()
                    guard let port = Int(text), (1...65535).contains(port) else { throw UsageError("bad port \(text)") }
                    options.port = port
                case "--data-dir": options.dataDirectory = SessionManager.expandingTilde(try value())
                case "--token": options.token = try value()
                case "-h", "--help": throw UsageError(nil)
                default: throw UsageError("unknown option \(argument)")
                }
            }
            return options
        }
    }

    public struct UsageError: Error, CustomStringConvertible {
        let message: String?
        init(_ message: String?) { self.message = message }
        public var description: String {
            (message.map { "agentmaster-server: \($0)\n" } ?? "") + """
            usage: agentmaster-server [--host 127.0.0.1] [--port 8765] [--data-dir ~/.agentmaster-server] [--token TOKEN]
              --host      address to listen on (default 127.0.0.1; reach it through an SSH tunnel or a TLS proxy)
              --port      port (default 8765)
              --data-dir  where sessions, settings and the token live (default ~/.agentmaster-server)
              --token     the browser's access token (default: AGENTMASTER_SERVER_TOKEN, else <data-dir>/token)
            """
        }
    }

    public static func run() async {
        signal(SIGPIPE, SIG_IGN)   // a browser or hook shim that goes away must not kill the server
        let options: Options
        do {
            options = try Options.parse(Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(error is UsageError && (error as! UsageError).message == nil ? 0 : 2)
        }
        var logger = Logger(label: "agentmaster-server")
        logger.logLevel = .info
        do {
            let dataDirectory = URL(fileURLWithPath: options.dataDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            let token = try options.token ?? loadOrCreateToken(in: dataDirectory)
            let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            let manager = try SessionManager(.init(dataDirectory: dataDirectory, executableURL: executable.resolvingSymlinksInPath()))
            manager.restoreOpenSessions()
            guard let webRoot = Bundle.module.resourceURL?.appendingPathComponent("Web").path else {
                throw UsageError("the web UI is missing from the build")
            }
            let app = WebServer.makeApplication(manager: manager, token: token, host: options.host, port: options.port,
                                                webRoot: webRoot, logger: logger)
            let shown = options.host == "0.0.0.0" || options.host == "::" ? "localhost" : options.host
            print("""
            AgentMaster server on http://\(options.host):\(options.port)
            Open: http://\(shown):\(options.port)/#token=\(token)
            Data: \(dataDirectory.path)
            """)
            if manager.paths.hookExecutable() == nil {
                print("warning: agentmaster-hook is not next to the server binary; sessions will not start.")
            }
            // stdout is block-buffered when it is a file or a pipe (nohup, systemd): show the link now.
            fflush(stdout)
            try await app.runService()
            manager.shutdown()
        } catch {
            FileHandle.standardError.write(Data("agentmaster-server: \(error)\n".utf8))
            exit(1)
        }
    }

    /// A random token kept in `<data-dir>/token` (mode 600), so the URL survives restarts.
    static func loadOrCreateToken(in directory: URL) throws -> String {
        let url = directory.appendingPathComponent("token")
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 24)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try Data(token.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return token
    }
}
