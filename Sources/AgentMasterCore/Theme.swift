import Foundation

/// Muse dark theme tokens (spec §4.6). Hex strings so every layer (ANSI, AppKit, SwiftUI) can use them.
public enum Theme {
    public static let bg = "#1e1e22"
    public static let text = "#ccd3db"
    public static let muted = "#8a9098"
    public static let faint = "#676c74"
    public static let accent = "#5aa0ff"
    public static let selection = "#263854"
    public static let teal = "#8abeb7"
    public static let success = "#a6e3a1"
    public static let error = "#f38ba8"
    public static let warning = "#ffe14a"
    public static let diffDelBg = "#4a221d"
    public static let diffDelFg = "#cc6666"
    public static let diffAddBg = "#213a2b"
    public static let diffAddFg = "#b5bd68"
    public static let shimmer = ["#676c74", "#767b83", "#9aa0a8", "#bdc4cc", "#ccd3db"]

    /// ANSI 0–15 for the embedded terminal, derived from the tokens above.
    public static let ansi: [String] = [
        "#2a2a30", "#f38ba8", "#a6e3a1", "#ffe14a", "#5aa0ff", "#c5a3ff", "#8abeb7", "#ccd3db",
        "#676c74", "#ff9eb8", "#b5e8b0", "#fff08a", "#8cbcff", "#d7bfff", "#a8d8d2", "#ffffff",
    ]

    public static func rgb(_ hex: String) -> (r: UInt8, g: UInt8, b: UInt8)? {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        return (UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff))
    }
}
