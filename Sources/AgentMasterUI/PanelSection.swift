import SwiftUI

/// Collapsible right-panel block with an uppercase bold muted title (spec §4.5).
public struct PanelSection<Content: View>: View {
    let title: String
    let content: Content
    @State private var expanded = true

    public init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
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
