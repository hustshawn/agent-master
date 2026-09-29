import SwiftUI
import AgentMasterCore

public struct ChangesPanel: View {
    let changes: [FileChange]
    @State private var expanded: Set<String> = []

    public init(changes: [FileChange]) {
        self.changes = changes
    }

    public var body: some View {
        if changes.isEmpty {
            EmptyHint("No changes yet")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(changes) { change in
                    Button {
                        if expanded.contains(change.id) { expanded.remove(change.id) } else { expanded.insert(change.id) }
                    } label: {
                        HStack(spacing: 6) {
                            Text((change.path as NSString).lastPathComponent).foregroundStyle(Palette.text).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("+\(change.added)").foregroundStyle(Palette.success)
                            Text("−\(change.removed)").foregroundStyle(Palette.error)
                            Text(expanded.contains(change.id) ? "⌄" : "›").foregroundStyle(Palette.faint)
                        }
                        .font(MuseFont.body)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(change.path)
                    if expanded.contains(change.id) { DiffView(change: change) }
                }
            }
        }
    }
}

/// Inline unified diff. Syntax highlighting is M5.
public struct DiffView: View {
    let change: FileChange

    public init(change: FileChange) {
        self.change = change
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(change.hunks.enumerated()), id: \.offset) { _, hunk in
                    // Codex patches carry no line numbers.
                    Text(hunk.oldStart == 0 && hunk.newStart == 0 ? "@@"
                         : "@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@")
                        .foregroundStyle(Palette.faint)
                        .padding(.vertical, 2)
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        DiffLineRow(line: line)
                    }
                }
            }
            .font(MuseFont.small)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).stroke(Palette.faint, lineWidth: 1))
    }
}

struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        let (marker, foreground, background): (String, Color, Color) = {
            switch line.kind {
            case .added: return ("+", Palette.diffAddFg, Palette.diffAddBg)
            case .removed: return ("-", Palette.diffDelFg, Palette.diffDelBg)
            case .context: return (" ", Palette.muted, .clear)
            }
        }()
        Text(marker + line.text)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
    }
}
