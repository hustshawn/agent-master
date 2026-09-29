import Foundation

public struct AppPaths {
    public let supportDirectory: URL
    public let bundleURL: URL
    public let executableURL: URL

    public init(supportDirectory: URL, bundleURL: URL, executableURL: URL) {
        self.supportDirectory = supportDirectory
        self.bundleURL = bundleURL
        self.executableURL = executableURL
    }

    public static var standard: AppPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentMaster")
        return AppPaths(supportDirectory: support, bundleURL: Bundle.main.bundleURL,
                        executableURL: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
    }

    public var socketPath: String {
        supportDirectory.appendingPathComponent("agentmaster.sock").path
    }

    public var openSessionsURL: URL {
        supportDirectory.appendingPathComponent("open-sessions.json")
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: supportDirectory.path)
    }

    public func writeSettings(_ data: Data, sessionId: String) throws -> URL {
        let directory = sessionDirectory(sessionId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("settings.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    public func removeSessionDirectory(sessionId: String) {
        try? FileManager.default.removeItem(at: sessionDirectory(sessionId))
    }

    /// Removes the entire sessions directory (all per-session settings dirs) and ignores errors.
    /// Called at launch before any session starts to clean up dirs left over from previous runs.
    public func removeAllSessionDirectories() {
        try? FileManager.default.removeItem(at: supportDirectory.appendingPathComponent("sessions"))
    }

    public func sessionDirectory(_ sessionId: String) -> URL {
        supportDirectory.appendingPathComponent("sessions").appendingPathComponent(sessionId)
    }

    /// `.app/Contents/Helpers/agentmaster-hook` when bundled; next to the executable under `swift run`.
    public func hookExecutable(isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        [
            bundleURL.appendingPathComponent("Contents/Helpers/agentmaster-hook").path,
            executableURL.deletingLastPathComponent().appendingPathComponent("agentmaster-hook").path,
        ].first(where: isExecutable)
    }
}
