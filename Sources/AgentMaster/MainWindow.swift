import SwiftUI
import AgentMasterUI
import TerminalKit

struct MainWindow: View {
    @Bindable var model: AppModel

    var body: some View {
        HSplitView {
            SessionSidebar(rows: model.sessions.map(\.row), selection: $model.selectedId,
                           recentProjects: model.recentProjects,
                           onNewIn: { model.start(in: $0) },
                           onChooseFolder: { model.chooseProjectAndStart() },
                           onClose: { model.close($0) })
            .frame(minWidth: 180, idealWidth: 240, maxWidth: 360)

            if let session = model.selected {
                VStack(spacing: 0) {
                    SessionHeader(project: session.projectName, model: session.state.usage?.modelName,
                                  mode: session.state.permissionMode,
                                  needsAttention: session.state.status == .needsAttention)
                    TerminalHost(session: session.terminal)
                        .id(session.id)
                }
                .frame(minWidth: 520)

                SidePanel(state: session.state)
                    .frame(minWidth: 240, idealWidth: 320, maxWidth: 480)
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
