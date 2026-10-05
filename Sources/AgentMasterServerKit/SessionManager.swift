import Foundation
import AgentMasterCore
import AgentMasterWire
import AgentMasterBridge

/// Pushed to every browser over /api/events.
public struct ServerEvent: Codable, Sendable {
    /// "snapshot" (all sessions, requests and messages), "session" (one added or changed), "removed",
    /// "request" (one opened or resolved) or "message" (a receipt changed).
    public let type: String
    public var sessions: [SessionJSON]?
    public var session: SessionJSON?
    public var id: String?
    public var requests: [ActionRequestJSON]?
    public var request: ActionRequestJSON?
    public var messages: [MessageReceiptJSON]?
    public var message: MessageReceiptJSON?
}

public enum SessionManagerError: Error, CustomStringConvertible {
    case notADirectory(String)
    case unknownAgent(String)
    case unknownSession(String)
    case unsupportedImage(String)

    public var description: String {
        switch self {
        case .notADirectory(let path): return "\(path) is not a folder on the server."
        case .unknownAgent(let id): return "Unknown agent \(id)."
        case .unknownSession(let id): return "Unknown session \(id)."
        case .unsupportedImage(let type): return "\(type.isEmpty ? "This file" : type) is not a PNG, JPEG, GIF or WebP image."
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
        /// How push notifications reach the push services; replaced in tests.
        public var pushTransport: any WebPushTransport

        public init(dataDirectory: URL, executableURL: URL, environment: [String: String]? = nil,
                    pushTransport: any WebPushTransport = HTTPClientWebPushTransport()) {
            self.dataDirectory = dataDirectory
            self.executableURL = executableURL
            self.environment = environment
            self.pushTransport = pushTransport
        }
    }

    public let paths: AppPaths
    public let environment: [String: String]
    private let settings: ServerSettings
    private let journal: OpenSessionJournal
    private let journalLock = NSLock()
    private var hookServer: HookServer?
    private let requests = ActionRequestStore()
    private let messages = MessageStore()
    public let push: PushNotifier

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
        push = try PushNotifier(dataDirectory: configuration.dataDirectory, transport: configuration.pushTransport)
        paths.removeAllSessionDirectories()
        let server = HookServer(socketPath: paths.socketPath) { [weak self] message, reply in
            self?.route(message)
            guard message.kind == .request else { return }
            if let self { self.open(message, reply: reply) } else { reply(nil) }
        }
        try server.start()
        hookServer = server
        requests.onChange = { [weak self] request in
            // A timed-out approval's deny interrupts the turn, which ends it without a Stop hook.
            if request.outcome == "timed out", request.kind == "permission" {
                self?.session(id: request.sessionId)?.apply([.turnFinished(lastMessage: nil)])
            }
            self?.broadcast(ServerEvent(type: "request", request: request))
        }
        messages.onChange = { [weak self] receipt in self?.broadcast(ServerEvent(type: "message", message: receipt)) }
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
                       resumeId: String? = nil, title: String? = nil, reviewed: Bool = false,
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
                                    customName: title, reviewed: reviewed, process: process)
        session.onChange = { [weak self, weak session] in
            guard let self, let session else { return }
            self.persist()
            self.broadcast(ServerEvent(type: "session", session: session.json))
        }
        sessions.append(session)
        lock.unlock()
        process.onExit { [weak self, weak session] _ in
            session?.processExited()
            guard let self else { return }
            self.requests.expire(sessionId: id, reason: "session ended")
            // A closed session is gone from the list by now; only an agent that quit by itself is news.
            if let session = self.session(id: id) {
                self.push.notify(PushPayload(title: "Agent exited", body: session.json.title, sessionId: id, tag: "exit-\(id)"))
            }
        }
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

    /// Marks the last turn's result as reviewed (or not); the session's next prompt clears the mark.
    public func setReviewed(id: String, _ reviewed: Bool) throws {
        guard let session = session(id: id) else { throw SessionManagerError.unknownSession(id) }
        session.reviewed = reviewed
    }

    /// Saves an image pasted in the browser into the session's directory, which goes away with the session,
    /// and returns its path. Pasting that path into the agent attaches the image, like a local clipboard paste.
    public func saveImage(sessionId id: String, data: Data, contentType: String) throws -> String {
        guard session(id: id) != nil else { throw SessionManagerError.unknownSession(id) }
        let extensions = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp"]
        guard let ext = extensions[contentType] else { throw SessionManagerError.unsupportedImage(contentType) }
        let directory = paths.sessionDirectory(id).appendingPathComponent("images")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString.prefix(8).lowercased()).\(ext)")
        try data.write(to: url)
        return url.path
    }

    /// Saves any file sent from the browser (a document, a log, a photo) into the session's directory, which
    /// goes away with the session, and returns its path for the prompt. The name keeps its extension, so an
    /// agent still recognizes an image, and loses spaces and anything but letters, digits, `.`, `_` and `-`,
    /// so the path stays one word in the prompt.
    public func saveFile(sessionId id: String, data: Data, filename: String) throws -> String {
        guard session(id: id) != nil else { throw SessionManagerError.unknownSession(id) }
        let directory = paths.sessionDirectory(id).appendingPathComponent("files")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(UUID().uuidString.prefix(8).lowercased())-\(Self.safeFilename(filename))")
        try data.write(to: url)
        return url.path
    }

    static func safeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let base = (name as NSString).lastPathComponent
        let safe = String(base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return safe.isEmpty ? "file" : String(safe.suffix(80))
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
        requests.expire(sessionId: id, reason: "session closed")
        messages.removeAll(sessionId: id)
        session.process.terminate()
        paths.removeSessionDirectory(sessionId: id)
        persist()
        broadcast(ServerEvent(type: "removed", id: id))
    }

    /// The session's conversation from its transcript, from item `after` on (see `Chat.page`).
    public func chat(sessionId: String, after: Int = 0) throws -> ChatJSON {
        guard let session = session(id: sessionId) else { throw SessionManagerError.unknownSession(sessionId) }
        let entries = session.state.transcriptPath.map(session.agent.transcript(at:)) ?? []
        return Chat.page(Chat.items(entries), after: after)
    }

    // MARK: requests and messages

    /// Open and recently resolved approvals and questions, oldest first.
    public var actionRequests: [ActionRequestJSON] { requests.all }

    public var messageReceipts: [MessageReceiptJSON] { messages.all }

    @discardableResult
    public func answer(requestId: String, decision: RemoteDecision) throws -> ActionRequestJSON {
        try requests.answer(requestId, decision: decision)
    }

    /// Types `text` into the session as a prompt, only while the agent waits for one. A repeated `messageId`
    /// returns the first send's receipt instead of typing it again.
    public func send(sessionId: String, messageId: String, text: String) throws -> MessageReceiptJSON {
        guard let session = session(id: sessionId) else { throw SessionManagerError.unknownSession(sessionId) }
        return try messages.send(id: messageId, sessionId: sessionId, text: text, idle: session.state.status == .idle) {
            session.process.write($0)
        }
    }

    /// Esc: stops the agent's current turn, not its process. Claude Code reports no hook for an interrupted
    /// turn, so the turn is ended here; a hook that does come later sets the status again.
    public func interrupt(sessionId: String) throws {
        guard let session = session(id: sessionId) else { throw SessionManagerError.unknownSession(sessionId) }
        session.process.write(Data([0x1B]))
        requests.expire(sessionId: sessionId, reason: "interrupted")
        session.apply([.turnFinished(lastMessage: nil)])
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
                            title: record.title, reviewed: record.reviewed ?? false)) != nil {
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
        // No request outlives its turn: a hook still waiting then was cancelled, or answered in the terminal.
        let payload = session.agent.hookDialect.normalize(message.payload)
        switch payload["hook_event_name"]?.stringValue {
        case "UserPromptSubmit":
            requests.expire(sessionId: session.id, reason: "answered in the terminal")
            messages.promptSubmitted(sessionId: session.id, prompt: payload["prompt"]?.stringValue ?? "")
        case "Stop":
            requests.expire(sessionId: session.id, reason: "turn ended")
            // Tagged per session, so a device shows only the latest turn's end.
            let json = session.json
            push.notify(PushPayload(title: "Turn finished · \(json.title)",
                                    body: PushNotifier.clipped(json.state.lastMessage ?? "Ready for your next message."),
                                    sessionId: session.id, tag: "turn-\(session.id)"))
        case "SessionEnd": requests.expire(sessionId: session.id, reason: "session ended")
        default: break
        }
    }

    /// Holds the hook for an answer from a browser when the agent can take one; otherwise its terminal asks,
    /// as in the Mac app.
    private func open(_ message: WireMessage, reply: @escaping (String?) -> Void) {
        // Every request an agent answers remotely can be denied, which is also what a timeout sends.
        guard let session = session(id: message.sessionId),
              session.agent.hookOutput(for: message.payload, decision: .deny(message: "", interrupt: false)) != nil else {
            reply(nil)
            return
        }
        let request = requests.open(sessionId: session.id, agent: session.agent, payload: message.payload, reply: reply)
        let question = request.input["questions"]?[0]?["question"]?.stringValue
        if request.kind == "question" {
            session.apply([.needsAttention(message: question.map { "Question: " + $0 } ?? "Question")])
        }
        push.notify(PushPayload(title: (request.kind == "question" ? "Question · " : "Approval needed · ") + session.json.title,
                                body: PushNotifier.clipped(question ?? request.title),
                                sessionId: session.id, tag: "request-\(request.id)"),
                    urgency: "high")
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
