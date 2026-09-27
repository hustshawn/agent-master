import SwiftUI

/// Collapsible right-panel block with an uppercase bold muted title (spec §4.5).
public struct PanelSection<Content: View>: View {
    let title: String
    let isEmpty: Bool
    let content: Content
    @State private var expanded = true

    public init(_ title: String, isEmpty: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.isEmpty = isEmpty
        self.content = content()
    }

    public var body: some View {
        if isEmpty {
            // Nothing to show: one quiet line instead of a header plus an empty hint.
            HStack(spacing: 4) {
                Text(title.uppercased()).font(MuseFont.heading).foregroundStyle(Palette.muted)
                Spacer()
                Text("—").font(MuseFont.small).foregroundStyle(Palette.faint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } else {
            expandable
        }
    }

    private var expandable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(title.uppercased()).font(MuseFont.heading).foregroundStyle(Palette.muted)
                    Spacer()
                    Text(expanded ? "▾" : "▸").font(MuseFont.small).foregroundStyle(Palette.faint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded { content }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
