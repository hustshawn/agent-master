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
    private(set) var sessions: [SessionController] = []
    var selectedId: String?
    var errorMessage: String?
    private(set) var recentProjects: [String] = []

    @ObservationIgnored private let paths = AppPaths.standard
    /// The login shell's environment once captured; Settings resolves model aliases against it.
    private(set) var capturedEnvironment: [String: String]?

    @ObservationIgnored private let recents = RecentProjects(defaults: .standard)
    @ObservationIgnored private let preferenceStore = AgentPreferenceStore(defaults: .standard)
    @ObservationIgnored private var server: HookServer?
    @ObservationIgnored private var environmentTask: Task<[String: String], Never>?

    init() {
        recentProjects = recents.paths
        // The login shell can take seconds; start it now so the first session does not wait.
        environmentTask = Task.detached {
            LaunchEnvironment.captureLoginShell() ?? ProcessInfo.processInfo.environment
        }
        do {
            try paths.prepare()
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
        Task { _ = await environment() }
    }

    var selected: SessionController? {
        sessions.first { $0.id == selectedId }
    }

    /// ⌘N: another session next to the selected one; the folder picker only when nothing is open.
    func newSessionInCurrentProject() {
        guard let project = selected?.projectPath else { return chooseProjectAndStart() }
        start(in: project)
    }

    func start(in projectPath: String) {
        Task { await startSession(in: projectPath) }
    }

    func chooseProjectAndStart() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start Session"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        start(in: url.path)
    }

    @discardableResult
    func startSession(in projectPath: String, agent: any AgentKind = AgentRegistry.defaultAgent,
                      resumeId: String? = nil) async -> String? {
        do {
            let base = await environment()
            let id = UUID().uuidString
            let launch = try agent.launch(AgentLaunchRequest(
                sessionId: id, preferences: preferenceStore.preferences(for: agent.id),
                environment: base, paths: paths, resumeId: resumeId))
            let session = SessionController(
                id: id, agentId: agent.id, projectPath: projectPath,
                launch: TerminalLaunch(executable: launch.executable, args: launch.args,
                                       environment: launch.environment, currentDirectory: projectPath))
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
            alert.informativeText = "Claude is still working in \(session.projectName). The transcript is kept; continue it later with claude --resume."
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
        server?.stop()
        server = nil
        sessions.forEach { $0.terminal.terminate() }
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
