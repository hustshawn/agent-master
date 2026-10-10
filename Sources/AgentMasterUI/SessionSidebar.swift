import SwiftUI
import AppKit
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

/// ⌘1…⌘8 pick the first eight visible rows and ⌘9 the last one, like browser tabs.
public enum SessionShortcuts {
    /// The digit shown on each row. With more than nine rows, those past the eighth have none except the last.
    public static func digits(for visibleIds: [String]) -> [String: Int] {
        var digits: [String: Int] = [:]
        for (index, id) in visibleIds.prefix(visibleIds.count > 9 ? 8 : 9).enumerated() { digits[id] = index + 1 }
        if visibleIds.count > 9, let last = visibleIds.last { digits[last] = 9 }
        return digits
    }

    public static func id(for digit: Int, in visibleIds: [String]) -> String? {
        guard (1...9).contains(digit), !visibleIds.isEmpty else { return nil }
        if digit == 9 { return visibleIds.last }
        return digit <= visibleIds.count ? visibleIds[digit - 1] : nil
    }
}

public struct SessionSidebar: View {
    let rows: [SessionRowModel]
    @Binding var selection: String?
    /// A ＋ was clicked: the project's path, or nil for the bottom one.
    let onNewSession: (String?) -> Void
    let onClose: (String) -> Void
    let onRename: (String, String) -> Void
    let onSummarize: (String) -> Void
    /// What is held with 1…9 to pick a row; ⌘ unless changed in Settings.
    let switchModifiers: Hotkey
    /// Project paths whose rows are hidden; kept for this run only.
    @State private var collapsed: Set<String> = []
    @State private var rename = RenameState()
    /// Read by the key monitor, which outlives any one body evaluation, so kept as state.
    @State private var visibleIds: [String] = []
    @State private var currentSwitchModifiers = HotkeyMap.defaultSwitchModifiers
    @State private var showsShortcuts = false
    @State private var keyMonitor: Any?
    @State private var hintDelay: Task<Void, Never>?

    public init(rows: [SessionRowModel], selection: Binding<String?>,
                onNewSession: @escaping (String?) -> Void,
                onClose: @escaping (String) -> Void, onRename: @escaping (String, String) -> Void,
                onSummarize: @escaping (String) -> Void = { _ in },
                switchModifiers: Hotkey = HotkeyMap.defaultSwitchModifiers) {
        self.rows = rows
        self._selection = selection
        self.onNewSession = onNewSession
        self.onClose = onClose
        self.onRename = onRename
        self.onSummarize = onSummarize
        self.switchModifiers = switchModifiers
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
            Button { onNewSession(nil) } label: {
                Label("New session", systemImage: "plus").font(.system(size: 14)).foregroundStyle(Palette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(IconButtonStyle(size: 32))
            .padding(6)
        }
        .background(Palette.bg)
        .onChange(of: SessionGrouping.group(rows).filter { !collapsed.contains($0.id) }.flatMap { $0.rows.map(\.id) },
                  initial: true) { _, ids in visibleIds = ids }
        .onChange(of: switchModifiers, initial: true) { _, modifiers in currentSwitchModifiers = modifiers }
        .onAppear(perform: startKeyMonitor)
        .onDisappear(perform: stopKeyMonitor)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            setShortcutHints(false)   // ⌘-Tab away: the ⌘ release goes to the other app
        }
    }

    /// ⌘1…⌘9 select a visible row from anywhere in the main window, the terminal included; holding ⌘ alone
    /// shows each row's digit after a short delay, so quick ⌘C/⌘V presses don't flash the badges. ⌘ stands for
    /// whatever modifiers Settings picked.
    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            // SwiftUI names the main `Window(id: "main")` frame after its id; Settings is left alone.
            guard event.window?.frameAutosaveName == "main" else { return event }
            let held = currentSwitchModifiers.matches(event.modifierFlags)
            if event.type == .flagsChanged {
                setShortcutHints(held)
                return event
            }
            setShortcutHints(false)
            if held, let digit = Int(event.characters(byApplyingModifiers: []) ?? ""),
               let id = SessionShortcuts.id(for: digit, in: visibleIds) {
                selection = id
                return nil
            }
            return event
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        setShortcutHints(false)
    }

    private func setShortcutHints(_ show: Bool) {
        hintDelay?.cancel()
        hintDelay = nil
        guard show else { showsShortcuts = false; return }
        hintDelay = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { showsShortcuts = true }
        }
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
            Button { onNewSession(group.id) } label: {
                Image(systemName: "plus").font(.system(size: 14, weight: .medium)).foregroundStyle(Palette.muted)
            }
            .buttonStyle(IconButtonStyle())
            .help("New session in \(group.name)")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    private func sessionRow(_ row: SessionRowModel) -> some View {
        let editing = rename.editingId == row.id
        // While a row is a text field its own clicks belong to the field, not to select or rename.
        return SessionRow(row: row, selected: row.id == selection, editing: editing, draft: $rename.draft,
                          shortcut: showsShortcuts ? SessionShortcuts.digits(for: visibleIds)[row.id]
                              .map { currentSwitchModifiers.symbols + "\($0)" } : nil,
                          onClose: { onClose(row.id) },
                          onCommit: { commitRename(row.id) },
                          onCancel: { rename.cancel() })
            .gesture(TapGesture().onEnded { selection = row.id }, including: editing ? .subviews : .all)
            .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename(row) }, including: editing ? .subviews : .all)
            .contextMenu {
                Button("Rename…") { beginRename(row) }
                Button("Summarize Session") { onSummarize(row.id) }
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
    /// Shown in place of the close button while ⌘ is held.
    let shortcut: String?
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
            if let shortcut {
                Text(shortcut).font(MuseFont.small)
                    .foregroundStyle(selected ? Palette.text : Palette.muted)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .overlay(Capsule().stroke(selected ? Palette.text.opacity(0.6) : Palette.faint, lineWidth: 1))
            } else if hovering && !editing {
                // Only there on hover, so a resting row gives its whole width to the title.
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
                }
                .buttonStyle(IconButtonStyle())
                .help("Close session")
            }
        }
        .onHover { hovering = $0 }
        .font(MuseFont.rowTitle)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Palette.selection : .clear))
        .contentShape(Rectangle())
    }
}
