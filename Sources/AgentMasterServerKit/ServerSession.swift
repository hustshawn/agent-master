import Foundation
import AgentMasterCore
import AgentMasterBridge

/// One session on the server: an agent in a pseudo-terminal, its hook translator and its reduced state.
public final class ServerSession: @unchecked Sendable {
    public let id: String
    public let agent: any AgentKind
    public let projectPath: String
    public let createdAt = Date()
    /// The id this session was resumed with; kept in the journal until SessionStart reports the live one.
    public let resumeHint: String?
    public let process: PTYProcess

    private let lock = NSLock()
    private var translator: HookTranslator
    private var _state = SessionState()
    private var _customName: String?
    /// Called after any change a browser should see.
    var onChange: (@Sendable () -> Void)?

    init(id: String, agent: any AgentKind, projectPath: String, resumeHint: String?, customName: String?,
         process: PTYProcess) {
        self.id = id
        self.agent = agent
        self.projectPath = projectPath
        self.resumeHint = resumeHint
        self.process = process
        _customName = customName
        translator = HookTranslator(dialect: agent.hookDialect)
    }

    public var state: SessionState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    public var customName: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _customName
        }
        set {
            lock.lock()
            _customName = newValue
            lock.unlock()
            onChange?()
        }
    }

    func receive(hook payload: JSONValue) {
        lock.lock()
        let events = translator.translate(payload)
        lock.unlock()
        apply(events)
    }

    func receive(statusLine payload: JSONValue) {
        lock.lock()
        let events = translator.translate(statusLine: payload)
        lock.unlock()
        apply(events)
    }

    func processExited() {
        guard state.status != .ended else { return }
        apply([.sessionEnded(reason: "process_exit")])
    }

    /// Also for what the server itself knows of, outside the agent's hooks (a request it timed out).
    func apply(_ events: [SessionEvent]) {
        guard !events.isEmpty else { return }
        let now = Date()
        lock.lock()
        for event in events { _state.apply(event, at: now) }
        lock.unlock()
        onChange?()
    }

    public var json: SessionJSON {
        lock.lock()
        let state = _state
        let customName = _customName
        lock.unlock()
        let label = agent.id == AgentRegistry.defaultAgent.id ? nil : agent.displayName
        return SessionJSON(
            id: id, agentId: agent.id, agentName: agent.displayName, projectPath: projectPath,
            projectName: (projectPath as NSString).lastPathComponent,
            title: RowText.title(customName: customName, firstPrompt: state.firstPrompt), customName: customName,
            subtitle: RowText.subtitle(for: state, agentName: label), status: state.status.name,
            createdAt: createdAt.timeIntervalSince1970, state: StateJSON(state))
    }

    var snapshot: OpenSessionSnapshot {
        let state = self.state
        return OpenSessionSnapshot(agentId: agent.id, projectPath: projectPath, createdAt: createdAt, state: state,
                                   selected: false, fallbackResumeId: resumeHint,
                                   title: customName ?? state.firstPrompt)
    }
}
