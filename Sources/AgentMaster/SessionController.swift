import Foundation
import Observation
import AgentMasterCore
import AgentMasterBridge
import AgentMasterUI
import TerminalKit

/// One AgentMaster session: one PTY running claude, its translator and its reduced state.
@MainActor
@Observable
final class SessionController: Identifiable {
    let id: String
    let projectPath: String
    let createdAt = Date()
    private(set) var state = SessionState()
    private(set) var title: String?
    @ObservationIgnored let terminal: TerminalSession
    @ObservationIgnored private var translator = HookTranslator()

    init(id: String, projectPath: String, launch: TerminalLaunch) {
        self.id = id
        self.projectPath = projectPath
        terminal = TerminalSession(launch: launch)
        terminal.onExit = { [weak self] _ in
            guard let self, self.state.status != .ended else { return }
            self.apply([.sessionEnded(reason: "process_exit")])
        }
        terminal.onTitle = { [weak self] title in
            self?.title = title.isEmpty ? nil : title
        }
    }

    func receive(hook payload: JSONValue) {
        apply(translator.translate(payload))
    }

    func receive(statusLine payload: JSONValue) {
        apply(translator.translate(statusLine: payload))
    }

    private func apply(_ events: [SessionEvent]) {
        let now = Date()
        for event in events { state.apply(event, at: now) }
    }

    var projectName: String {
        (projectPath as NSString).lastPathComponent
    }

    var row: SessionRowModel {
        SessionRowModel(id: id, projectPath: projectPath, title: title ?? "Session \(id.prefix(4))",
                        status: state.status, createdAt: createdAt)
    }
}
