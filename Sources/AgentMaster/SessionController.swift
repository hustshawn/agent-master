import Foundation
import Observation
import AgentMasterCore
import AgentMasterBridge
import AgentMasterUI
import TerminalKit

/// One AgentMaster session: one PTY running an agent, its translator and its reduced state.
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
    /// Filled in on request (Summarize Session); not kept across launches.
    var summary = SummaryState.none
    @ObservationIgnored let terminal: TerminalSession
    @ObservationIgnored private var translator: HookTranslator

    /// `lastActivityAt` keeps a restored session's place in the sidebar.
    init(id: String, agent: any AgentKind, projectPath: String, resumeHint: String? = nil, lastActivityAt: Date? = nil,
         launch: TerminalLaunch) {
        self.id = id
        self.agentId = agent.id
        translator = HookTranslator(dialect: agent.hookDialect)
        self.projectPath = projectPath
        self.resumeHint = resumeHint
        terminal = TerminalSession(launch: launch)
        state.lastActivityAt = lastActivityAt
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
        // Claude sessions keep the plain subtitle; others say which agent they run.
        var subtitle = SessionSubtitle.text(for: state)
        if agentId != AgentRegistry.defaultAgent.id, let name = AgentRegistry.agent(id: agentId)?.displayName {
            subtitle = "\(name) · \(subtitle)"
        }
        return SessionRowModel(id: id, projectPath: projectPath, title: displayTitle,
                               subtitle: subtitle, status: state.status, lastActivityAt: state.lastActivityAt ?? createdAt)
    }
}
