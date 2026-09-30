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
        case .ghost(let hex):
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.14).fill(Color(hex: hex))
                Ghost().fill(Color.white)
                GhostEyes().fill(Color(hex: "#0D0B12"))
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

/// Kiro's ghost, traced from its app icon into a 100×100 box and drawn as a smooth curve through the points.
/// The web UI draws the same points the same way.
struct Ghost: Shape {
    static let points: [(CGFloat, CGFloat)] = [
        (58, 83.5), (56.5, 83.5), (55, 83), (53.7, 82), (52, 80.2), (51, 79.8), (50, 80), (47, 81.5),
        (42.5, 83.1), (39, 83.4), (36.5, 83.1), (35, 82.5), (32.5, 80.5), (31.1, 77.5), (30.8, 75), (31.6, 71),
        (31.5, 70), (30.5, 69.4), (27, 69.7), (24.5, 69.3), (22.9, 68), (22.3, 67), (21.9, 65.5), (22, 64),
        (22.5, 62.5), (24.7, 58), (26, 54.5), (27.1, 49), (28.6, 37.5), (30.3, 31.5), (32.4, 27), (35, 23.6),
        (39.5, 19.7), (45, 17.1), (51.5, 15.8), (57, 16.4), (60, 17.2), (65.5, 19.9), (68.5, 22.3), (71.9, 26),
        (74.6, 31), (76.2, 35.5), (77.2, 41), (77.7, 49), (77.1, 55.5), (75.5, 63), (73.6, 68.5), (70.5, 74.5),
        (68.7, 77), (66.7, 79), (62.5, 82.1),
    ]

    func path(in rect: CGRect) -> Path {
        let points = Self.points.map { CGPoint(x: rect.minX + rect.width * $0.0 / 100, y: rect.minY + rect.height * $0.1 / 100) }
        let count = points.count
        func at(_ index: Int) -> CGPoint { points[(index + count) % count] }
        var path = Path()
        path.move(to: points[0])
        // A closed Catmull-Rom spline, as cubic Béziers.
        for index in 0..<count {
            let (a, b, c, d) = (at(index - 1), at(index), at(index + 1), at(index + 2))
            path.addCurve(to: c,
                          control1: CGPoint(x: b.x + (c.x - a.x) / 6, y: b.y + (c.y - a.y) / 6),
                          control2: CGPoint(x: c.x - (d.x - b.x) / 6, y: c.y - (d.y - b.y) / 6))
        }
        path.closeSubpath()
        return path
    }
}

struct GhostEyes: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width / 100, h = rect.height / 100
        var path = Path()
        for (x, y) in [(53.0, 40.0), (64.5, 40.1)] {
            path.addEllipse(in: CGRect(x: rect.minX + (x - 3.2) * w, y: rect.minY + (y - 5.2) * h, width: 6.4 * w, height: 10.4 * h))
        }
        return path
    }
}
