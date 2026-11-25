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
    /// The models each agent's CLI lists, by agent id, once asked; until then the model can only be typed.
    private(set) var modelCatalog: [String: [AgentChoice]] = [:]

    @ObservationIgnored private let recents = RecentProjects(defaults: .standard)
    @ObservationIgnored private let preferenceStore = AgentPreferenceStore(defaults: .standard)
    @ObservationIgnored private let journal = OpenSessionJournal(fileURL: AppPaths.standard.openSessionsURL)
    /// While relaunching the journal's sessions, do not overwrite it with the partial list.
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var server: HookServer?
    @ObservationIgnored private let newSessionPanel = NewSessionPanel()
    @ObservationIgnored private var environmentTask: Task<[String: String], Never>?
    /// Policy checks waiting on a card; unanswered ones go back to the terminal, since the user is at this Mac
    /// (ADR 0017). Approvals and questions get no card: Claude Code draws its own prompt in the terminal while
    /// the hook waits, so they are answered at once and only post a notification.
    @ObservationIgnored let requests = ActionRequestStore(timeoutDecision: nil)
    @ObservationIgnored private let policyBook = PolicyBook()
    /// Which agent each session runs, for the hook thread, which cannot read `sessions`.
    @ObservationIgnored private let sessionAgents = SessionAgents()
    /// The open requests, for the cards; kept in step with `requests` on the main actor.
    private(set) var pendingRequests: [ActionRequestJSON] = []
    @ObservationIgnored private let notifications = AppNotifications()

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
            let requests = self.requests, policyBook = self.policyBook, sessionAgents = self.sessionAgents
            requests.onChange = { request in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.requestChanged(request) }
                }
            }
            let server = HookServer(socketPath: paths.socketPath) { message, reply in
                if message.kind == .statusline { policyBook.observe(statusLine: message.payload, sessionId: message.sessionId) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.route(message) }
                }
                guard message.kind == .request else { return }
                // On this thread, so a tool call nothing objects to is answered at once (ADR 0017).
                guard let agent = sessionAgents[message.sessionId] else { return reply(nil) }
                HookRequestRouter.route(sessionId: message.sessionId, payload: message.payload, reply: reply, agent: agent,
                                        settings: GeneralSettings.policies(.standard), policies: policyBook,
                                        requests: requests, remote: false) { _ in }
            }
            try server.start()
            self.server = server
            notifications.onOpen = { id in MainActor.assumeIsolated { self.selectedId = id } }
            notifications.start()
        } catch {
            errorMessage = "Could not start the hook server: \(error)"
        }
        Task {
            let environment = await environment()
            await restoreOpenSessions(pending)
            modelCatalog = await Task.detached { AgentRegistry.modelCatalog(environment: environment) }.value
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

    /// Whether the agent's binary can be found, with the same lookup Settings and the new-session panel use.
    func isInstalled(_ agent: any AgentKind) -> Bool {
        agent.executable.locate(environment: capturedEnvironment ?? ProcessInfo.processInfo.environment) != nil
    }

    /// Every agent's glyph, model choices, current default and whether it is installed, for the new-session panel.
    func newSessionAgents() -> [NewSessionAgent] {
        let environment = capturedEnvironment ?? ProcessInfo.processInfo.environment
        return AgentRegistry.all.map { agent in
            let modelOption = agent.options(environment: capturedEnvironment ?? [:], models: modelCatalog[agent.id])
                .first { $0.id == AgentOption.modelId }
            var choices: [AgentChoice] = []
            var allowsCustom = false
            if case let .choice(values, custom)? = modelOption?.kind {
                choices = values
                allowsCustom = custom
            }
            return NewSessionAgent(id: agent.id, name: agent.displayName, glyph: agent.glyph, modelChoices: choices,
                                   allowsCustomModel: allowsCustom,
                                   defaultModel: preferenceStore.preferences(for: agent.id).string(AgentOption.modelId),
                                   location: agent.executable.locate(environment: environment),
                                   missingHint: "Not found. Install \(agent.executable.name) or set \(agent.executable.overrideVariable).")
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
                      resumeId: String? = nil, title: String? = nil, model: String? = nil,
                      lastActivityAt: Date? = nil) async -> String? {
        do {
            let base = await environment()
            let id = UUID().uuidString
            // Before the agent starts, so its first hook already finds which agent it is.
            sessionAgents[id] = agent
            var preferences = preferenceStore.preferences(for: agent.id)
            if let model { preferences.values[AgentOption.modelId] = model }
            let launch = try agent.launch(AgentLaunchRequest(
                sessionId: id, preferences: preferences,
                environment: base, paths: paths, resumeId: resumeId, projectPath: projectPath))
            let session = SessionController(
                id: id, agent: agent, projectPath: projectPath, resumeHint: resumeId, lastActivityAt: lastActivityAt,
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

    /// Summarizes and reviews a session from its transcript in the background; the result shows in the inspector.
    func summarize(_ id: String) {
        guard let session = sessions.first(where: { $0.id == id }), session.summary != .running else { return }
        selectedId = id
        UserDefaults.standard.set(false, forKey: InspectorSettings.collapsedKey)
        guard let agent = AgentRegistry.agent(id: session.agentId), let path = session.state.transcriptPath else {
            session.summary = .failed("There is no transcript yet. Send the agent a prompt first.")
            return
        }
        session.summary = .running
        let directory = paths.supportDirectory
        Task {
            let environment = await environment()
            do {
                let entries = await Task.detached { agent.transcript(at: path) }.value
                session.summary = .done(try await SessionSummary.run(entries: entries, environment: environment,
                                                                     directory: directory))
            } catch {
                session.summary = .failed(error.localizedDescription)
            }
        }
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
        sessionAgents[id] = nil
        requests.expire(sessionId: id, reason: "session closed")
        policyBook.remove(sessionId: id)
        // claude reads settings.json only at startup, so it can go as soon as the process is signalled.
        paths.removeSessionDirectory(sessionId: id)
    }

    func shutdown() {
        // Terminating below marks every session ended; the journal must keep what was open.
        journal.freeze()
        // Before stopping the hook server, which would release a Codex policy check with no output: "run it".
        requests.expireAll(reason: "AgentMaster quit")
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
                                              title: record.title, lastActivityAt: record.lastActivityAt ?? record.createdAt)
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
        case .event, .request:
            session.receive(hook: message.payload)
            let payload = AgentRegistry.agent(id: session.agentId)?.hookDialect.normalize(message.payload)
            let event = payload?["hook_event_name"]?.stringValue
            let needsYouId = "needs-\(session.id)"
            // An approval or a question is answered in the terminal (see `requests`); only tell the user.
            if event == "PermissionRequest" || (event == "PreToolUse" && payload?["tool_name"]?.stringValue == "AskUserQuestion") {
                let input = payload?["tool_input"] ?? .null
                let body = event == "PermissionRequest"
                    ? ToolClassifier.kind(name: payload?["tool_name"]?.stringValue ?? "tool", input: input).title
                    : input["questions"]?[0]?["question"]?.stringValue ?? "The agent has a question."
                notifyNeedsYou(id: needsYouId, heading: event == "PermissionRequest" ? "Approval needed" : "Question",
                               body: body, session: session)
            } else if ["PostToolUse", "UserPromptSubmit", "Stop", "SessionEnd"].contains(event) {
                notifications.remove(id: needsYouId)
            }
            // No request outlives its turn: a hook still waiting then was cancelled, or answered in the terminal.
            switch event {
            case "UserPromptSubmit": requests.expire(sessionId: session.id, reason: "answered in the terminal")
            case "Stop":
                requests.expire(sessionId: session.id, reason: "turn ended")
                titleIfNeeded(session)
                if GeneralSettings.notifyTurnFinished(.standard), !isLooking(at: session.id) {
                    notifications.post(id: "turn-\(session.id)", title: "Turn finished · \(session.displayTitle)",
                                       body: "Ready for your next message.", sessionId: session.id, sound: false)
                }
            case "SessionEnd": requests.expire(sessionId: session.id, reason: "session ended")
            default: break
            }
        }
    }

    // MARK: requests

    private func requestChanged(_ request: ActionRequestJSON) {
        pendingRequests = requests.open
        let id = "request-\(request.id)"
        guard request.status == "pending" else { return notifications.remove(id: id) }
        guard let session = sessions.first(where: { $0.id == request.sessionId }) else { return }
        notifyNeedsYou(id: id, heading: "Policy check", body: request.title, session: session)
    }

    /// Unless turned off in General settings, or the user is looking at the session.
    private func notifyNeedsYou(id: String, heading: String, body: String, session: SessionController) {
        guard GeneralSettings.notifyNeedsYou(.standard), !isLooking(at: session.id) else { return }
        notifications.post(id: id, title: "\(heading) · \(session.displayTitle)", body: body, sessionId: session.id)
    }

    /// The user has this session in front of them, so a notification would only interrupt.
    private func isLooking(at sessionId: String) -> Bool {
        NSApp.isActive && selectedId == sessionId
    }

    /// The card for the selected session's oldest open request.
    func decisionCard(for sessionId: String) -> DecisionCardModel? {
        guard let request = pendingRequests.first(where: { $0.sessionId == sessionId }) else { return nil }
        let kind: DecisionCardModel.Kind = request.kind == "policy" ? .policy : request.kind == "question" ? .question : .permission
        let questions = (request.input["questions"]?.arrayValue ?? []).map { question in
            DecisionCardModel.Question(
                text: question["question"]?.stringValue ?? "", header: question["header"]?.stringValue,
                options: (question["options"]?.arrayValue ?? []).map {
                    DecisionCardModel.Option(label: $0["label"]?.stringValue ?? "", detail: $0["description"]?.stringValue)
                })
        }
        let detail = request.input["command"]?.stringValue ?? request.input["file_path"]?.stringValue ?? ""
        // Codex takes no "ask", so handing a policy check back there would deny it.
        let agentId = sessions.first { $0.id == sessionId }?.agentId
        return DecisionCardModel(id: request.id, kind: kind, title: request.title, detail: detail, reason: request.reason,
                                 questions: questions, canHandBack: agentId == ClaudeCodeAgent().id)
    }

    /// A card's answer. One answered elsewhere first (in the terminal, or after it timed out) is just gone.
    /// Then the keyboard goes back to the session's terminal, so the user can type on without a click.
    func answer(_ requestId: String, _ decision: RemoteDecision, forSession: Bool = false) {
        let sessionId = pendingRequests.first { $0.id == requestId }?.sessionId
        _ = try? requests.answer(requestId, decision: decision, forSession: forSession)
        guard let view = sessions.first(where: { $0.id == sessionId })?.terminal.view else { return }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }

    /// After a turn ends: once per session, a short AI title from its first prompt and the reply, unless it has a name.
    private func titleIfNeeded(_ session: SessionController) {
        guard GeneralSettings.aiSessionTitles(.standard), !session.titleClaimed,
              let prompt = SessionTitler.prompt(for: session.state, customName: session.customName) else { return }
        session.titleClaimed = true
        let reply = session.state.lastMessage
        let directory = paths.supportDirectory
        Task {
            let environment = await environment()
            guard let title = try? await SessionTitler.run(prompt: prompt, reply: reply, environment: environment,
                                                           directory: directory),
                  session.customName == nil else { return }
            session.customName = title
            persistOpenSessions()
        }
    }
}

/// Session id → agent, behind a lock, for the hook server's thread.
final class SessionAgents: @unchecked Sendable {
    private let lock = NSLock()
    private var agents: [String: any AgentKind] = [:]

    subscript(id: String) -> (any AgentKind)? {
        get { lock.lock(); defer { lock.unlock() }; return agents[id] }
        set { lock.lock(); agents[id] = newValue; lock.unlock() }
    }
}
