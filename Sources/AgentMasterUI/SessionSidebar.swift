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

/// The row title: the user's name for the session, else its first prompt, else a placeholder.
public enum SessionTitle {
    public static func text(customName: String?, firstPrompt: String?) -> String {
        if let name = customName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        if let prompt = firstPrompt, !prompt.isEmpty { return prompt }
        return "New session"
    }
}

/// In-place rename of one sidebar row. Only a real change is committed, so a stray double-click
/// never freezes the placeholder or the first prompt as a custom name.
public struct RenameState: Equatable {
    public private(set) var editingId: String?
    public var draft = ""
    private var original = ""

    public init() {}

    /// A second begin on the row being edited (a double-click inside the field) keeps what was typed.
    public mutating func begin(_ id: String, title: String) {
        guard editingId != id else { return }
        editingId = id
        draft = title
        original = title
    }

    /// Ends editing. Returns the name to apply ("" clears it), or nil when nothing changed.
    public mutating func commit(_ id: String) -> String? {
        guard editingId == id else { return nil }
        editingId = nil
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == original.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : draft
    }

    public mutating func cancel() {
        editingId = nil
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
    let onRename: (String, String) -> Void
    /// Project paths whose rows are hidden; kept for this run only.
    @State private var collapsed: Set<String> = []
    @State private var rename = RenameState()

    public init(rows: [SessionRowModel], selection: Binding<String?>, recentProjects: [String],
                onNewIn: @escaping (String) -> Void, onChooseFolder: @escaping () -> Void,
                onClose: @escaping (String) -> Void, onRename: @escaping (String, String) -> Void) {
        self.rows = rows
        self._selection = selection
        self.recentProjects = recentProjects
        self.onNewIn = onNewIn
        self.onChooseFolder = onChooseFolder
        self.onClose = onClose
        self.onRename = onRename
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(SessionGrouping.group(rows).enumerated()), id: \.element.id) { index, group in
                        if index > 0 { HairLine().padding(.vertical, 8) }
                        groupHeader(group)
                        if !collapsed.contains(group.id) {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(group.rows) { row in sessionRow(row) }
                            }
                            .padding(.leading, 18)
                            .padding(.top, 4)
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

    private func groupHeader(_ group: SessionGroup) -> some View {
        HStack(spacing: 6) {
            Button {
                if collapsed.contains(group.id) { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
            } label: {
                HStack(spacing: 6) {
                    Text(collapsed.contains(group.id) ? "▸" : "▾").font(MuseFont.small).foregroundStyle(Palette.faint)
                        .frame(width: 10)
                    Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(Palette.muted)
                    Text(group.name).font(MuseFont.groupTitle).foregroundStyle(Palette.text).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(group.rows.count)").font(MuseFont.small).foregroundStyle(Palette.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(group.id)
            Button { onNewIn(group.id) } label: {
                Text("＋").font(MuseFont.groupHeading).foregroundStyle(Palette.muted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New session in \(group.name)")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    private func sessionRow(_ row: SessionRowModel) -> some View {
        let editing = rename.editingId == row.id
        // While a row is a text field its own clicks belong to the field, not to select or rename.
        return SessionRow(row: row, selected: row.id == selection, editing: editing, draft: $rename.draft,
                          onClose: { onClose(row.id) },
                          onCommit: { commitRename(row.id) },
                          onCancel: { rename.cancel() })
            .gesture(TapGesture().onEnded { selection = row.id }, including: editing ? .subviews : .all)
            .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename(row) }, including: editing ? .subviews : .all)
            .contextMenu {
                Button("Rename…") { beginRename(row) }
                Button("Close Session") { onClose(row.id) }
            }
    }

    private func beginRename(_ row: SessionRowModel) {
        rename.begin(row.id, title: row.title)
    }

    private func commitRename(_ id: String) {
        if let name = rename.commit(id) { onRename(id, name) }
    }
}

struct SessionRow: View {
    let row: SessionRowModel
    let selected: Bool
    let editing: Bool
    @Binding var draft: String
    let onClose: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    @State private var hovering = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(StatusGlyph.symbol(for: row.status)).foregroundStyle(Color(hex: StatusGlyph.colorHex(for: row.status)))
            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Palette.text)
                        .focused($fieldFocused)
                        .onSubmit(onCommit)
                        .onExitCommand(perform: onCancel)
                        .onAppear { fieldFocused = true }
                        .onChange(of: fieldFocused) { _, focused in if !focused { onCommit() } }
                } else {
                    Text(row.title).foregroundStyle(selected ? Palette.text : Palette.muted).lineLimit(1)
                }
                if !row.subtitle.isEmpty {
                    Text(row.subtitle).font(MuseFont.rowSubtitle).foregroundStyle(Palette.faint).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Text("×").foregroundStyle(Palette.muted).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close session")
            .opacity(hovering && !editing ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .font(MuseFont.rowTitle)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Palette.selection : .clear))
        .contentShape(Rectangle())
    }
}
