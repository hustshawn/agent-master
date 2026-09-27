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
    let agentId: String
    let projectPath: String
    /// The id this session was resumed with; kept in the journal until SessionStart reports the live one.
    let resumeHint: String?
    @ObservationIgnored var onStateChange: (() -> Void)?
    let createdAt = Date()
    private(set) var state = SessionState()
    /// Set by the user (Rename…) or carried over from the journal when restored.
    var customName: String?
    @ObservationIgnored let terminal: TerminalSession
    @ObservationIgnored private var translator = HookTranslator()

    init(id: String, agentId: String, projectPath: String, resumeHint: String? = nil, launch: TerminalLaunch) {
        self.id = id
        self.agentId = agentId
        self.projectPath = projectPath
        self.resumeHint = resumeHint
        terminal = TerminalSession(launch: launch)
        terminal.onExit = { [weak self] _ in
            guard let self, self.state.status != .ended else { return }
            self.apply([.sessionEnded(reason: "process_exit")])
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
        if !events.isEmpty { onStateChange?() }
    }

    var displayTitle: String {
        SessionTitle.text(customName: customName, firstPrompt: state.firstPrompt)
    }

    var projectName: String {
        (projectPath as NSString).lastPathComponent
    }

    var row: SessionRowModel {
        SessionRowModel(id: id, projectPath: projectPath, title: displayTitle,
                        subtitle: SessionSubtitle.text(for: state), status: state.status, createdAt: createdAt)
    }
}
