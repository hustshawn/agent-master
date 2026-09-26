import SwiftUI
import AgentMasterCore

public struct SidePanel: View {
    let state: SessionState

    public init(state: SessionState) {
        self.state = state
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PanelSection("Todo") { TodoPanel(todos: state.todos) }
                HairLine()
                PanelSection("Agents") { AgentsPanel(subagents: state.subagents, mainActive: state.status == .running) }
                HairLine()
                PanelSection("Changes") { ChangesPanel(changes: state.changes) }
                HairLine()
                PanelSection("Usage") { UsagePanel(usage: state.usage, permissionMode: state.permissionMode) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.bg)
    }
}

#Preview {
    SidePanel(state: PreviewData.state).frame(width: 320, height: 700).preferredColorScheme(.dark)
}
