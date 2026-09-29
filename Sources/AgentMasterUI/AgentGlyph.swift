import SwiftUI
import AgentMasterCore

/// A hand-drawn outline that tells agents apart at a glance; not the vendors' official artwork.
public struct AgentGlyph: View {
    let style: AgentGlyphStyle
    let size: CGFloat

    public init(style: AgentGlyphStyle, size: CGFloat = 40) {
        self.style = style
        self.size = size
    }

    public var body: some View {
        switch style {
        case .spark(let hex):
            ClaudeSpark()
                .stroke(Color(hex: hex), style: StrokeStyle(lineWidth: size * 0.09, lineCap: .round))
                .frame(width: size, height: size)
        case .terminalPrompt:
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.26)
                    .stroke(Palette.text, lineWidth: size * 0.06)
                TerminalPrompt()
                    .stroke(Palette.text, style: StrokeStyle(lineWidth: size * 0.08, lineCap: .round, lineJoin: .round))
                    .padding(size * 0.26)
            }
            .frame(width: size, height: size)
        case .symbol(let name):
            Image(systemName: name).font(.system(size: size * 0.7)).foregroundStyle(Palette.muted)
                .frame(width: size, height: size)
        }
    }
}

/// Rays of uneven length around a centre, like Claude's spark.
struct ClaudeSpark: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let lengths: [CGFloat] = [1, 0.78, 0.92, 0.74, 1, 0.82, 0.95, 0.76, 0.98, 0.8, 0.9, 0.72]
        var path = Path()
        for (index, length) in lengths.enumerated() {
            let angle = CGFloat(index) / CGFloat(lengths.count) * 2 * .pi - .pi / 2
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            path.move(to: CGPoint(x: center.x + direction.x * radius * 0.16, y: center.y + direction.y * radius * 0.16))
            path.addLine(to: CGPoint(x: center.x + direction.x * radius * length * 0.92,
                                     y: center.y + direction.y * radius * length * 0.92))
        }
        return path
    }
}

/// `>_`
struct TerminalPrompt: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.12))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rect.height * 0.12))
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.55, y: rect.maxY - rect.height * 0.12))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rect.height * 0.12))
        return path
    }
}
