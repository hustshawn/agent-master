import SwiftUI
import AgentMasterCore

public struct SessionRowModel: Identifiable, Equatable {
    public let id: String
    public let projectPath: String
    public let title: String
    public let status: SessionStatus
    public let createdAt: Date

    public init(id: String, projectPath: String, title: String, status: SessionStatus, createdAt: Date) {
        self.id = id
        self.projectPath = projectPath
        self.title = title
        self.status = status
        self.createdAt = createdAt
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
}

public struct SessionSidebar: View {
    let rows: [SessionRowModel]
    @Binding var selection: String?
    let onNew: () -> Void

    public init(rows: [SessionRowModel], selection: Binding<String?>, onNew: @escaping () -> Void) {
        self.rows = rows
        self._selection = selection
        self.onNew = onNew
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(SessionGrouping.group(rows)) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("▾ " + group.name).font(MuseFont.heading).foregroundStyle(Palette.muted)
                                .help(group.id)
                            ForEach(group.rows) { row in
                                SessionRow(row: row, selected: row.id == selection)
                                    .onTapGesture { selection = row.id }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 28)   // clears the traffic lights in the hidden title bar
            }
            HairLine()
            Button(action: onNew) {
                Text("＋ New session").font(MuseFont.body).foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .background(Palette.bg)
    }
}

struct SessionRow: View {
    let row: SessionRowModel
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(StatusGlyph.symbol(for: row.status)).foregroundStyle(Color(hex: StatusGlyph.colorHex(for: row.status)))
            Text(row.title).foregroundStyle(selected ? Palette.text : Palette.muted).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(MuseFont.body)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Palette.selection : .clear))
        .contentShape(Rectangle())
    }
}
