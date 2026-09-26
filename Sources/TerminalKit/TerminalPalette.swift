import AppKit
import SwiftTerm
import AgentMasterCore

extension NSColor {
    public convenience init(hex: String) {
        let rgb = Theme.rgb(hex) ?? (r: 0, g: 0, b: 0)
        self.init(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}

public enum TerminalPalette {
    public static var ansiColors: [SwiftTerm.Color] {
        Theme.ansi.map { hex in
            let rgb = Theme.rgb(hex) ?? (r: 0, g: 0, b: 0)
            return SwiftTerm.Color(red8: UInt16(rgb.r), green8: UInt16(rgb.g), blue8: UInt16(rgb.b))
        }
    }

    @MainActor
    public static func apply(to view: TerminalView) {
        view.installColors(ansiColors)
        view.nativeBackgroundColor = NSColor(hex: Theme.bg)
        view.nativeForegroundColor = NSColor(hex: Theme.text)
        view.caretColor = NSColor(hex: Theme.accent)
        view.selectedTextBackgroundColor = NSColor(hex: Theme.selection)
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }
}
