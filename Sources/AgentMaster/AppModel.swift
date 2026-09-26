import AppKit
import Observation
import AgentMasterCore
import AgentMasterWire
import AgentMasterBridge
import TerminalKit

enum AppError: LocalizedError {
    case claudeNotFound
    case hookHelperMissing

    var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "Claude Code not found. Install it (~/.local/bin/claude) or set AGENTMASTER_CLAUDE_PATH."
        case .hookHelperMissing:
            return "agentmaster-hook is missing. Build with scripts/bundle.sh, or `swift build` so it sits next to the app binary."
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var sessions: [SessionController] = []
    var selectedId: String?
    var errorMessage: String?

    @ObservationIgnored private let paths = AppPaths.standard
    @ObservationIgnored private var server: HookServer?
    @ObservationIgnored private var baseEnvironment: [String: String]?
    @ObservationIgnored private var environmentTask: Task<[String: String], Never>?

    init() {
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
    }

    var selected: SessionController? {
        sessions.first { $0.id == selectedId }
    }

    func chooseProjectAndStart() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Start Session"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await startSession(in: url.path) }
    }

    func startSession(in projectPath: String) async {
        do {
            let base = await environment()
            guard let claude = ClaudeLocator.locate(environment: base) else { throw AppError.claudeNotFound }
            guard let hook = paths.hookExecutable() else { throw AppError.hookHelperMissing }
            let id = UUID().uuidString
            let settings = try paths.writeSettings(SessionSettingsBuilder(hookExecutable: hook).data(), sessionId: id)
            let launch = TerminalLaunch(
                executable: claude,
                args: ["--settings", settings.path],
                environment: LaunchEnvironment.sessionEnvironment(base: base, sessionId: id, socketPath: paths.socketPath),
                currentDirectory: projectPath)
            let session = SessionController(id: id, projectPath: projectPath, launch: launch)
            sessions.append(session)
            selectedId = id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func shutdown() {
        server?.stop()
        server = nil
        sessions.forEach { $0.terminal.terminate() }
    }

    private func environment() async -> [String: String] {
        if let baseEnvironment { return baseEnvironment }
        let captured = await environmentTask?.value ?? ProcessInfo.processInfo.environment
        baseEnvironment = captured
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
