import AppKit
import Observation
import AgentMasterCore
import AgentMasterWire
import AgentMasterBridge
import TerminalKit
import AgentMasterUI


@MainActor
@Observable
final class AppModel {
    private(set) var sessions: [SessionController] = [] {
        didSet { persistOpenSessions() }
    }
    var selectedId: String? {
        didSet { persistOpenSessions() }
    }
    var errorMessage: String?
    private(set) var recentProjects: [String] = []

    @ObservationIgnored private let paths = AppPaths.standard
    /// The login shell's environment once captured; Settings resolves model aliases against it.
    private(set) var capturedEnvironment: [String: String]?

    @ObservationIgnored private let recents = RecentProjects(defaults: .standard)
    @ObservationIgnored private let preferenceStore = AgentPreferenceStore(defaults: .standard)
    @ObservationIgnored private let journal = OpenSessionJournal(fileURL: AppPaths.standard.openSessionsURL)
    /// While relaunching the journal's sessions, do not overwrite it with the partial list.
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var server: HookServer?
    @ObservationIgnored private let newSessionPanel = NewSessionPanel()
    @ObservationIgnored private var environmentTask: Task<[String: String], Never>?

    init() {
        recentProjects = recents.paths
        // The login shell can take seconds; start it now so the first session does not wait.
        environmentTask = Task.detached {
            LaunchEnvironment.captureLoginShell() ?? ProcessInfo.processInfo.environment
        }
        // Decide synchronously whether to restore so that any session started before the Task
        // runs cannot race with restoreOpenSessions and wipe the journal with an empty list.
        let pending = GeneralSettings.restoreSessionsOnLaunch(.standard) ? journal.load() : []
        restoring = !pending.isEmpty
        do {
            try paths.prepare()
            paths.removeAllSessionDirectories()
            let server = HookServer(socketPath: paths.socketPath) { message, reply in
                // M3 replaces this with the native approval / question overlays.
                if message.kind == .request { reply(nil) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.route(message) }
                }
            }
            try server.start()
            self.server = server
        } catch {
            errorMessage = "Could not start the hook server: \(error)"
        }
        Task {
            _ = await environment()
            await restoreOpenSessions(pending)
        }
    }

    var selected: SessionController? {
        sessions.first { $0.id == selectedId }
    }

    /// ⌘N: another session next to the selected one, running the same agent unless `agent` is given;
    /// the folder picker only when nothing is open.
    func newSessionInCurrentProject(agent: (any AgentKind)? = nil) {
        let agent = agent ?? AgentRegistry.agentForNewSession(selectedAgentId: selected?.agentId)
        guard let project = selected?.projectPath else { return chooseProjectAndStart(agent: agent) }
        start(in: project, agent: agent)
    }

    func start(in projectPath: String, agent: any AgentKind = AgentRegistry.defaultAgent) {
        Task { await startSession(in: projectPath, agent: agent) }
    }

    func chooseProjectAndStart(agent: any AgentKind = AgentRegistry.defaultAgent) {
        guard let path = chooseFolder(prompt: "Start Session") else { return }
        start(in: path, agent: agent)
    }

    func chooseFolder(prompt: String = "Choose") -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    /// Every agent's glyph, model choices and current default, for the new-session panel.
    func newSessionAgents() -> [NewSessionAgent] {
        AgentRegistry.all.map { agent in
            let modelOption = agent.options(environment: capturedEnvironment ?? [:]).first { $0.id == AgentOption.modelId }
            var choices: [AgentChoice] = []
            var allowsCustom = false
            if case let .choice(values, custom)? = modelOption?.kind {
                choices = values
                allowsCustom = custom
            }
            return NewSessionAgent(id: agent.id, name: agent.displayName, glyph: agent.glyph, modelChoices: choices,
                                   allowsCustomModel: allowsCustom,
                                   defaultModel: preferenceStore.preferences(for: agent.id).string(AgentOption.modelId))
        }
    }

    /// Every ＋: the floating new-session panel, for `project` or (nil) any recent project.
    func showNewSession(project: String?) {
        newSessionPanel.show(NewSessionForm(
            agents: newSessionAgents(), initialProject: project, projects: recentProjects,
            chooseFolder: { [weak self] in self?.chooseFolder() },
            onStart: { [weak self] request in
                self?.newSessionPanel.close()
                self?.start(request)
            },
            onCancel: { [weak self] in self?.newSessionPanel.close() }))
    }

    func start(_ request: NewSessionRequest) {
        let agent = AgentRegistry.agent(id: request.agentId) ?? AgentRegistry.defaultAgent
        Task { await startSession(in: request.projectPath, agent: agent, model: request.model) }
    }

    /// `model` overrides the agent's default model for this launch only.
    @discardableResult
    func startSession(in projectPath: String, agent: any AgentKind = AgentRegistry.defaultAgent,
                      resumeId: String? = nil, title: String? = nil, model: String? = nil) async -> String? {
        do {
            let base = await environment()
            let id = UUID().uuidString
            var preferences = preferenceStore.preferences(for: agent.id)
            if let model { preferences.values[AgentOption.modelId] = model }
            let launch = try agent.launch(AgentLaunchRequest(
                sessionId: id, preferences: preferences,
                environment: base, paths: paths, resumeId: resumeId, projectPath: projectPath))
            let session = SessionController(
                id: id, agent: agent, projectPath: projectPath, resumeHint: resumeId,
                launch: TerminalLaunch(executable: launch.executable, args: launch.args,
                                       environment: launch.environment, currentDirectory: projectPath))
            session.customName = title
            session.onStateChange = { [weak self] in self?.persistOpenSessions() }
            sessions.append(session)
            selectedId = id
            recents.record(projectPath)
            recentProjects = recents.paths
            return id
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// A blank name clears the custom title, so the row falls back to the first prompt.
    func rename(_ id: String, to name: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        session.customName = trimmed.isEmpty ? nil : trimmed
        persistOpenSessions()
    }

    /// ⌘W. Returns false when there is no session, so the window closes as usual.
    func closeSelected() -> Bool {
        guard let selectedId else { return false }
        close(selectedId)
        return true
    }

    func close(_ id: String) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        if session.state.status.needsCloseConfirmation {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Close “\(session.row.title)”?"
            let agentName = AgentRegistry.agent(id: session.agentId)?.displayName ?? "The agent"
            alert.informativeText = "\(agentName) is still working in \(session.projectName). The transcript is kept, so the conversation can be resumed later."
            alert.addButton(withTitle: "Close")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let next = SessionGrouping.selectionAfterClosing(id, in: sessions.map(\.row))
        sessions.removeAll { $0.id == id }
        if selectedId == id { selectedId = next }
        session.terminal.terminate()
        // claude reads settings.json only at startup, so it can go as soon as the process is signalled.
        paths.removeSessionDirectory(sessionId: id)
    }

    func shutdown() {
        // Terminating below marks every session ended; the journal must keep what was open.
        journal.freeze()
        server?.stop()
        server = nil
        sessions.forEach { $0.terminal.terminate() }
    }

    private func persistOpenSessions() {
        guard !restoring else { return }
        journal.save(RestorePlan.records(from: sessions.map {
            OpenSessionSnapshot(agentId: $0.agentId, projectPath: $0.projectPath, createdAt: $0.createdAt,
                                state: $0.state, selected: $0.id == selectedId, fallbackResumeId: $0.resumeHint,
                                title: $0.customName ?? $0.state.firstPrompt)
        }, agents: AgentRegistry.all))
    }

    private func restoreOpenSessions(_ records: [OpenSessionRecord]) async {
        let plan = RestorePlan.make(records: records, agents: AgentRegistry.all) { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard !plan.isEmpty else {
            restoring = false
            return
        }
        var restoredIds: Set<String> = []
        var restoredSelected: String?
        for record in plan {
            guard let agent = AgentRegistry.agent(id: record.agentId),
                  let id = await startSession(in: record.projectPath, agent: agent, resumeId: record.resumeId,
                                              title: record.title)
            else { continue }
            restoredIds.insert(id)
            if record.selected { restoredSelected = id }
        }
        // F6: if every startSession failed (e.g. claude not on PATH), leave the journal intact.
        guard !restoredIds.isEmpty else {
            restoring = false
            return
        }
        // F1: only override the selection if the user has not picked a different session during restore.
        if let restoredSelected, selectedId == nil || restoredIds.contains(selectedId ?? "") {
            selectedId = restoredSelected
        }
        restoring = false
        persistOpenSessions()
    }

    private func environment() async -> [String: String] {
        if let capturedEnvironment { return capturedEnvironment }
        let captured = await environmentTask?.value ?? ProcessInfo.processInfo.environment
        capturedEnvironment = captured
        return captured
    }

    private func route(_ message: WireMessage) {
        guard let session = sessions.first(where: { $0.id == message.sessionId }) else { return }
        switch message.kind {
        case .statusline: session.receive(statusLine: message.payload)
        case .event, .request: session.receive(hook: message.payload)
        }
    }
}
