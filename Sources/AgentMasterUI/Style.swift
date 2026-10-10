import SwiftUI
import AgentMasterCore

extension Color {
    public init(hex: String) {
        let rgb = Theme.rgb(hex) ?? (r: 0, g: 0, b: 0)
        self.init(.sRGB, red: Double(rgb.r) / 255, green: Double(rgb.g) / 255, blue: Double(rgb.b) / 255)
    }
}

public enum Palette {
    public static let bg = Color(hex: Theme.bg)
    public static let text = Color(hex: Theme.text)
    public static let muted = Color(hex: Theme.muted)
    public static let faint = Color(hex: Theme.faint)
    public static let accent = Color(hex: Theme.accent)
    public static let selection = Color(hex: Theme.selection)
    public static let teal = Color(hex: Theme.teal)
    public static let success = Color(hex: Theme.success)
    public static let error = Color(hex: Theme.error)
    public static let warning = Color(hex: Theme.warning)
    public static let diffAddBg = Color(hex: Theme.diffAddBg)
    public static let diffAddFg = Color(hex: Theme.diffAddFg)
    public static let diffDelBg = Color(hex: Theme.diffDelBg)
    public static let diffDelFg = Color(hex: Theme.diffDelFg)
}

public enum MuseFont {
    public static let body = Font.system(size: 13, design: .monospaced)
    public static let small = Font.system(size: 11, design: .monospaced)
    public static let heading = Font.system(size: 11, weight: .bold, design: .monospaced)
    public static let rowTitle = Font.system(size: 15, design: .monospaced)
    public static let rowSubtitle = Font.system(size: 12, design: .monospaced)
    public static let groupHeading = Font.system(size: 12, weight: .bold, design: .monospaced)
    /// The one proportional face in the UI, so project names never read as session rows.
    public static let groupTitle = Font.system(size: 15, weight: .bold)
}

public struct HairLine: View {
    let color: Color

    public init(color: Color = Palette.faint) {
        self.color = color
    }

    public var body: some View {
        Rectangle().fill(color).frame(height: 1)
    }
}

public struct EmptyHint: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text).font(MuseFont.small).foregroundStyle(Palette.faint)
    }
}

/// Toolbar-like buttons: at least `size`×`size` to click, with a soft background on hover and while pressed.
public struct IconButtonStyle: ButtonStyle {
    let size: CGFloat

    public init(size: CGFloat = 28) {
        self.size = size
    }

    public func makeBody(configuration: Configuration) -> some View {
        HoverBackground(pressed: configuration.isPressed, cornerRadius: 6) {
            configuration.label
                .padding(.horizontal, 6)
                .frame(minWidth: size, minHeight: size)
        }
    }
}

/// A small outlined text button, for actions inside a panel (Summarize, Copy…).
public struct OutlineButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HoverBackground(pressed: configuration.isPressed, cornerRadius: 6) {
            configuration.label
                .font(MuseFont.body)
                .foregroundStyle(Palette.accent)
                .padding(.horizontal, 10)
                .frame(minHeight: 26)
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.faint, lineWidth: 1))
    }
}

private struct HoverBackground<Content: View>: View {
    let pressed: Bool
    let cornerRadius: CGFloat
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        content
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.white.opacity(pressed ? 0.14 : hovering ? 0.08 : 0)))
            .onHover { hovering = $0 }
    }
}
