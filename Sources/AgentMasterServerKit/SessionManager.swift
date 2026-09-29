import Foundation
import AgentMasterCore
import AgentMasterWire
import AgentMasterBridge

/// Pushed to every browser over /api/events.
public struct ServerEvent: Codable, Sendable {
    /// "snapshot" (all sessions), "session" (one added or changed) or "removed".
    public let type: String
    public var sessions: [SessionJSON]?
    public var session: SessionJSON?
    public var id: String?
}

public enum SessionManagerError: Error, CustomStringConvertible {
    case notADirectory(String)
    case unknownAgent(String)
    case unknownSession(String)

    public var description: String {
        switch self {
        case .notADirectory(let path): return "\(path) is not a folder on the server."
        case .unknownAgent(let id): return "Unknown agent \(id)."
        case .unknownSession(let id): return "Unknown session \(id)."
        }
    }
}

/// Everything the server knows: its sessions, the hook server they report to, preferences and the
/// restore journal. The server-side counterpart of the Mac app's AppModel, over the same Bridge.
public final class SessionManager: @unchecked Sendable {
    public struct Configuration {
        /// The server's own support directory: socket, per-session settings and the journal live here,
        /// apart from the Mac app's, so both can run on one machine.
        public var dataDirectory: URL
        /// The server binary; `agentmaster-hook` must sit next to it.
        public var executableURL: URL
        /// The agents' environment. Nil captures the login shell's, falling back to the server's own.
        public var environment: [String: String]?

        public init(dataDirectory: URL, executableURL: URL, environment: [String: String]? = nil) {
            self.dataDirectory = dataDirectory
            self.executableURL = executableURL
            self.environment = environment
        }
    }

    public let paths: AppPaths
    public let environment: [String: String]
    private let settings: ServerSettings
    private let journal: OpenSessionJournal
    private let journalLock = NSLock()
    private var hookServer: HookServer?

    private let lock = NSLock()
    private var sessions: [ServerSession] = []
    private var listeners: [UUID: @Sendable (ServerEvent) -> Void] = [:]
    /// While relaunching the journal's sessions, do not overwrite it with the partial list.
    private var restoring = false

    public init(_ configuration: Configuration) throws {
        paths = AppPaths(supportDirectory: configuration.dataDirectory,
                         bundleURL: configuration.executableURL.deletingLastPathComponent(),
                         executableURL: configuration.executableURL)
        journal = OpenSessionJournal(fileURL: paths.openSessionsURL)
        environment = configuration.environment ?? LaunchEnvironment.captureLoginShell() ?? ProcessInfo.processInfo.environment
        try paths.prepare()
        settings = ServerSettings(url: configuration.dataDirectory.appendingPathComponent("settings.json"))
        paths.removeAllSessionDirectories()
        let server = HookServer(socketPath: paths.socketPath) { [weak self] message, reply in
            // Approvals and questions are answered in the terminal, as in the Mac app today.
            if message.kind == .request { reply(nil) }
            self?.route(message)
        }
        try server.start()
        hookServer = server
    }

    // MARK: sessions

    public func list() -> [SessionJSON] {
        lock.lock()
        let current = sessions
        lock.unlock()
        return current.map(\.json)
    }

    public func session(id: String) -> ServerSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions.first { $0.id == id }
    }

    /// Starts `agentId` (the default agent when nil) in `projectPath`. `model` overrides the default model once.
    @discardableResult
    public func create(projectPath rawPath: String, agentId: String? = nil, model: String? = nil,
                       resumeId: String? = nil, title: String? = nil,
                       columns: UInt16 = 120, rows: UInt16 = 36) throws -> SessionJSON {
        // Agents report resolved paths (/tmp is /private/tmp on macOS); resolve here so file changes read relative.
        let projectPath = Self.realPath(Self.expandingTilde(rawPath))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SessionManagerError.notADirectory(projectPath)
        }
        let agent: any AgentKind
        if let agentId {
            guard let found = AgentRegistry.agent(id: agentId) else { throw SessionManagerError.unknownAgent(agentId) }
            agent = found
        } else {
            agent = AgentRegistry.defaultAgent
        }
        let id = UUID().uuidString
        var preferences = settings.preferences(for: agent.id)
        if let model, !model.trimmingCharacters(in: .whitespaces).isEmpty { preferences.values[AgentOption.modelId] = model }
        let launch = try agent.launch(AgentLaunchRequest(sessionId: id, preferences: preferences, environment: environment,
                                                         paths: paths, resumeId: resumeId, projectPath: projectPath))
        // An agent can report its first hook the moment it starts. Holding the lock from spawn to registration
        // makes the hook thread's lookup wait for the session instead of dropping the message.
        lock.lock()
        let process: PTYProcess
        do {
            process = try PTYProcess(executable: launch.executable, arguments: launch.args, environment: launch.environment,
                                     directory: projectPath, columns: columns, rows: rows)
        } catch {
            lock.unlock()
            throw error
        }
        let session = ServerSession(id: id, agent: agent, projectPath: projectPath, resumeHint: resumeId,
                                    customName: title, process: process)
        session.onChange = { [weak self, weak session] in
            guard let self, let session else { return }
            self.persist()
            self.broadcast(ServerEvent(type: "session", session: session.json))
        }
        sessions.append(session)
        lock.unlock()
        process.onExit { [weak session] _ in session?.processExited() }
        settings.recordProject(projectPath)
        persist()
        let json = session.json
        broadcast(ServerEvent(type: "session", session: json))
        return json
    }

    public func rename(id: String, to name: String) throws {
        guard let session = session(id: id) else { throw SessionManagerError.unknownSession(id) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        session.customName = trimmed.isEmpty ? nil : trimmed
    }

    public func close(id: String) throws {
        lock.lock()
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            throw SessionManagerError.unknownSession(id)
        }
        let session = sessions.remove(at: index)
        lock.unlock()
        session.onChange = nil
        session.process.terminate()
        paths.removeSessionDirectory(sessionId: id)
        persist()
        broadcast(ServerEvent(type: "removed", id: id))
    }

    /// Relaunches the sessions open when the server last stopped, if the General setting allows it.
    public func restoreOpenSessions() {
        guard settings.restoreSessionsOnLaunch else { return }
        let plan = RestorePlan.make(records: journal.load(), agents: AgentRegistry.all) { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard !plan.isEmpty else { return }
        lock.lock()
        restoring = true
        lock.unlock()
        var restored = 0
        for record in plan {
            if (try? create(projectPath: record.projectPath, agentId: record.agentId, resumeId: record.resumeId,
                            title: record.title)) != nil {
                restored += 1
            }
        }
        lock.lock()
        restoring = false
        lock.unlock()
        // If every relaunch failed (e.g. the agent is not installed), keep the journal for next time.
        if restored > 0 { persist() }
    }

    public func shutdown() {
        journalLock.lock()
        journal.freeze()
        journalLock.unlock()
        hookServer?.stop()
        hookServer = nil
        lock.lock()
        let current = sessions
        lock.unlock()
        current.forEach { $0.process.terminate() }
    }

    // MARK: browsers

    /// Registers for events and returns the current sessions, with no gap in between.
    public func subscribe(_ handler: @escaping @Sendable (ServerEvent) -> Void) -> (token: UUID, sessions: [SessionJSON]) {
        lock.lock()
        let token = UUID()
        listeners[token] = handler
        let current = sessions
        lock.unlock()
        return (token, current.map(\.json))
    }

    public func unsubscribe(_ token: UUID) {
        lock.lock()
        listeners[token] = nil
        lock.unlock()
    }

    // MARK: settings

    public func agents() -> [AgentJSON] {
        AgentRegistry.all.map { AgentJSON($0, environment: environment, preferences: settings.preferences(for: $0.id)) }
    }

    public func setOption(agentId: String, optionId: String, value: String?) throws {
        guard AgentRegistry.agent(id: agentId) != nil else { throw SessionManagerError.unknownAgent(agentId) }
        settings.set(value, agentId: agentId, optionId: optionId)
    }

    public var restoreSessionsOnLaunch: Bool {
        get { settings.restoreSessionsOnLaunch }
        set { settings.restoreSessionsOnLaunch = newValue }
    }

    public var recentProjects: [String] { settings.recentProjects }

    // MARK: private

    private func route(_ message: WireMessage) {
        guard let session = session(id: message.sessionId) else { return }
        switch message.kind {
        case .statusline: session.receive(statusLine: message.payload)
        case .event, .request: session.receive(hook: message.payload)
        }
    }

    private func broadcast(_ event: ServerEvent) {
        lock.lock()
        let handlers = Array(listeners.values)
        lock.unlock()
        handlers.forEach { $0(event) }
    }

    private func persist() {
        lock.lock()
        let skip = restoring
        let current = sessions
        lock.unlock()
        guard !skip else { return }
        let records = RestorePlan.records(from: current.map(\.snapshot), agents: AgentRegistry.all)
        // Hook events and HTTP requests persist from different threads; the journal is not thread-safe.
        journalLock.lock()
        journal.save(records)
        journalLock.unlock()
    }

    /// The path with every symlink resolved, as the agent's own getcwd() sees it. Not URL.resolvingSymlinksInPath,
    /// which strips a leading /private on macOS and so turns /private/tmp back into /tmp.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func expandingTilde(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" { return NSHomeDirectory() }
        if trimmed.hasPrefix("~/") { return NSHomeDirectory() + trimmed.dropFirst(1) }
        return (trimmed as NSString).standardizingPath
    }
}
