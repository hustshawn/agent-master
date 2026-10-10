import SwiftUI
import AgentMasterCore

/// What the inspector has to show for one session: which blocks are empty, and the counts on the rail.
public struct PanelSummary: Equatable {
    public let openTodos: Int
    public let runningAgents: Int
    public let finishedAgents: Int
    public let changedFiles: Int
    public let todoEmpty: Bool
    public let agentsEmpty: Bool
    public let changesEmpty: Bool

    public init(state: SessionState) {
        openTodos = state.todos.filter { $0.status != .completed }.count
        runningAgents = state.subagents.filter { $0.finishedAt == nil }.count
        finishedAgents = state.subagents.count - runningAgents
        changedFiles = state.changes.count
        todoEmpty = state.todos.isEmpty
        // `main` alone is not content.
        agentsEmpty = state.subagents.isEmpty
        changesEmpty = state.changes.isEmpty
    }
}

public struct SidePanel: View {
    let state: SessionState
    let report: SummaryState
    let summarizeShortcut: Hotkey?
    let onSummarize: () -> Void

    public init(state: SessionState, report: SummaryState = .none, summarizeShortcut: Hotkey? = nil,
                onSummarize: @escaping () -> Void = {}) {
        self.state = state
        self.report = report
        self.summarizeShortcut = summarizeShortcut
        self.onSummarize = onSummarize
    }

    public var body: some View {
        let summary = PanelSummary(state: state)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if report == .none {
                    // Like an empty section's quiet line, with the action in place of the dash.
                    HStack(spacing: 4) {
                        Text("SUMMARY").font(MuseFont.heading).foregroundStyle(Palette.muted)
                        Spacer()
                        Button("Summarize", action: onSummarize)
                            .buttonStyle(OutlineButtonStyle())
                            .help(Hotkey.help("Summarize and review this session", summarizeShortcut))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                } else {
                    PanelSection("Summary") { SummaryPanel(summary: report, onRegenerate: onSummarize) }
                }
                HairLine()
                PanelSection("Todo", isEmpty: summary.todoEmpty) { TodoPanel(todos: state.todos) }
                HairLine()
                PanelSection("Agents", isEmpty: summary.agentsEmpty) {
                    AgentsPanel(subagents: state.subagents, mainActive: state.status == .running)
                }
                HairLine()
                PanelSection("Changes", isEmpty: summary.changesEmpty) { ChangesPanel(changes: state.changes) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.bg)
    }
}

/// The collapsed inspector: a narrow strip of counts; clicking anywhere expands it again.
public struct InspectorRail: View {
    let summary: PanelSummary
    let shortcut: Hotkey?
    let onExpand: () -> Void

    public init(summary: PanelSummary, shortcut: Hotkey?, onExpand: @escaping () -> Void) {
        self.summary = summary
        self.shortcut = shortcut
        self.onExpand = onExpand
    }

    public var body: some View {
        Button(action: onExpand) {
            VStack(spacing: 14) {
                Image(systemName: "sidebar.right").font(.system(size: 12)).foregroundStyle(Palette.muted)
                if summary.openTodos > 0 { badge("◆", summary.openTodos, Palette.teal) }
                if summary.runningAgents > 0 {
                    badge("└", summary.runningAgents, Palette.teal)
                } else if summary.finishedAgents > 0 {
                    badge("✓", summary.finishedAgents, Palette.success)
                }
                if summary.changedFiles > 0 { badge("±", summary.changedFiles, Palette.muted) }
                Spacer()
            }
            .padding(.top, 40)
            .frame(width: 28)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Hotkey.help("Show inspector", shortcut))
        .background(Palette.bg)
    }

    private func badge(_ glyph: String, _ count: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(glyph).foregroundStyle(color)
            Text("\(count)").foregroundStyle(Palette.muted)
        }
        .font(MuseFont.small)
    }
}

#Preview {
    SidePanel(state: PreviewData.state).frame(width: 320, height: 700).preferredColorScheme(.dark)
}

public enum InspectorSettings {
    /// UserDefaults key: whether the right panel is collapsed to the rail. Survives relaunch.
    public static let collapsedKey = "panelCollapsed"
    /// The inspector is an on-demand review panel, so a fresh install starts collapsed (ADR 0007).
    public static let collapsedByDefault = true
}
