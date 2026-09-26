import Foundation
import AgentMasterCore

/// Muse-style bottom bar printed by Claude Code's statusLine: `model · folder · ctx N%`.
public enum StatusLineFormatter {
    public static func format(_ payload: JSONValue) -> String {
        var parts = [paint(payload["model"]?["display_name"]?.stringValue ?? "claude", Theme.accent)]
        let directory = payload["workspace"]?["current_dir"]?.stringValue ?? payload["cwd"]?.stringValue ?? ""
        if !directory.isEmpty {
            parts.append(paint((directory as NSString).lastPathComponent, Theme.text))
        }
        if let percent = payload["context_window"]?["used_percentage"]?.intValue {
            parts.append(paint("ctx \(percent)%", Theme.muted))
        }
        return parts.joined(separator: paint(" · ", Theme.muted))
    }

    static func paint(_ text: String, _ hex: String) -> String {
        guard let color = Theme.rgb(hex) else { return text }
        return "\u{1B}[38;2;\(color.r);\(color.g);\(color.b)m\(text)\u{1B}[0m"
    }
}
