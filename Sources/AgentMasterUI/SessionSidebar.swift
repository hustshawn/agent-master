import SwiftUI
import AgentMasterCore

public struct SessionRowModel: Identifiable, Equatable {
    public let id: String
    public let projectPath: String
    public let title: String
    public let subtitle: String
    public let status: SessionStatus
    public let createdAt: Date

    public init(id: String, projectPath: String, title: String, subtitle: String = "", status: SessionStatus,
                createdAt: Date) {
        self.id = id
        self.projectPath = projectPath
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.createdAt = createdAt
    }
}

/// The second line of a sidebar row: what the session is doing right now.
public enum SessionSubtitle {
    public static func text(for state: SessionState) -> String {
        switch state.status {
        case .starting: return "starting"
        case .running: return joined("running", state.runningTools.last?.name)
        case .needsAttention: return joined("needs you", state.attentionMessage)
        case .idle: return joined("idle", state.usage?.modelName)
        case .ended: return "ended"
        }
    }

    private static func joined(_ status: String, _ detail: String?) -> String {
        guard let detail, !detail.isEmpty else { return status }
        return "\(status) · \(detail)"
    }
}

public struct SessionGroup: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let rows: [SessionRowModel]
}

public enum SessionGrouping {
    public static func group(_ rows: [SessionRowModel]) -> [SessionGroup] {
        Dictionary(grouping: rows, by: \.projectPath)
            .map { path, rows in
                SessionGroup(id: path, name: (path as NSString).lastPathComponent,
                             rows: rows.sorted { $0.createdAt > $1.createdAt })
            }
            .sorted { $0.rows[0].createdAt > $1.rows[0].createdAt }
    }

    /// The row to select once `id` is closed: the next one in its project, else the previous one,
    /// else the first remaining row in display order.
    public static func selectionAfterClosing(_ id: String, in rows: [SessionRowModel]) -> String? {
        let groups = group(rows)
        if let siblings = groups.first(where: { $0.rows.contains { $0.id == id } })?.rows,
           let index = siblings.firstIndex(where: { $0.id == id }) {
            if index + 1 < siblings.count { return siblings[index + 1].id }
            if index > 0 { return siblings[index - 1].id }
        }
        return groups.flatMap(\.rows).first { $0.id != id }?.id
    }
}

public struct SessionSidebar: View {
    let rows: [SessionRowModel]
    @Binding var selection: String?
    let recentProjects: [String]
    let onNewIn: (String) -> Void
    let onChooseFolder: () -> Void
    let onClose: (String) -> Void

    public init(rows: [SessionRowModel], selection: Binding<String?>, recentProjects: [String],
                onNewIn: @escaping (String) -> Void, onChooseFolder: @escaping () -> Void,
                onClose: @escaping (String) -> Void) {
        self.rows = rows
        self._selection = selection
        self.recentProjects = recentProjects
        self.onNewIn = onNewIn
        self.onChooseFolder = onChooseFolder
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(SessionGrouping.group(rows)) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("▾ " + group.name).font(MuseFont.groupHeading).foregroundStyle(Palette.muted)
                                    .help(group.id)
                                Spacer(minLength: 0)
                                Button { onNewIn(group.id) } label: {
                                    Text("＋").font(MuseFont.groupHeading).foregroundStyle(Palette.muted)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("New session in \(group.name)")
                            }
                            ForEach(group.rows) { row in
                                SessionRow(row: row, selected: row.id == selection) { onClose(row.id) }
                                    .onTapGesture { selection = row.id }
                                    .contextMenu {
                                        Button("Close Session") { onClose(row.id) }
                                    }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 28)   // clears the traffic lights in the hidden title bar
            }
            HairLine()
            Menu {
                ForEach(recentProjects, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) { onNewIn(path) }
                        .help(path)
                }
                if !recentProjects.isEmpty { Divider() }
                Button("Choose Folder…", action: onChooseFolder)
            } label: {
                Text("＋ New session").font(MuseFont.body).foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .padding(10)
        }
        .background(Palette.bg)
    }
}

struct SessionRow: View {
    let row: SessionRowModel
    let selected: Bool
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(StatusGlyph.symbol(for: row.status)).foregroundStyle(Color(hex: StatusGlyph.colorHex(for: row.status)))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).foregroundStyle(selected ? Palette.text : Palette.muted).lineLimit(1)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle).font(MuseFont.small).foregroundStyle(Palette.faint).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Text("×").foregroundStyle(Palette.muted).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close session")
            .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .font(MuseFont.rowTitle)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Palette.selection : .clear))
        .contentShape(Rectangle())
    }
}
