import SwiftUI
import AgentMasterUI
import TerminalKit

struct MainWindow: View {
    @Bindable var model: AppModel
    @AppStorage(InspectorSettings.collapsedKey) private var inspectorCollapsed = InspectorSettings.collapsedByDefault

    var body: some View {
        HSplitView {
            SessionSidebar(rows: model.sessions.map(\.row), selection: $model.selectedId,
                           onNewSession: { model.showNewSession(project: $0) },
                           onClose: { model.close($0) },
                           onRename: { model.rename($0, to: $1) })
            .frame(minWidth: 180, idealWidth: 240, maxWidth: 360)

            if let session = model.selected {
                VStack(spacing: 0) {
                    SessionHeader(project: session.projectName, session: session.displayTitle,
                                  usage: session.state.usage, mode: session.state.permissionMode,
                                  needsAttention: session.state.status == .needsAttention,
                                  inspectorCollapsed: inspectorCollapsed,
                                  onToggleInspector: { inspectorCollapsed.toggle() })
                    TerminalHost(session: session.terminal)
                        .id(session.id)
                }
                .frame(minWidth: 520)

                if inspectorCollapsed {
                    InspectorRail(summary: PanelSummary(state: session.state)) { inspectorCollapsed = false }
                        .frame(width: 28)
                } else {
                    SidePanel(state: session.state)
                        .frame(minWidth: 240, idealWidth: 320, maxWidth: 480)
                }
            } else {
                VStack(spacing: 12) {
                    EmptyHint("No session")
                    Button("New Session…  ⌘N") { model.chooseProjectAndStart() }
                        .buttonStyle(.plain)
                        .font(MuseFont.body)
                        .foregroundStyle(Palette.accent)
                }
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.bg)
            }
        }
        .background(Palette.bg)
        .alert("AgentMaster", isPresented: Binding(get: { model.errorMessage != nil },
                                                  set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
