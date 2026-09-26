import SwiftUI
import AgentMasterCore

public enum StatusGlyph {
    public static func symbol(for status: SessionStatus) -> String {
        switch status {
        case .starting, .running: return "◈"
        case .needsAttention: return "◆"
        case .idle: return "◇"
        case .ended: return "✓"
        }
    }

    public static func colorHex(for status: SessionStatus) -> String {
        switch status {
        case .starting: return Theme.faint
        case .running: return Theme.teal
        case .needsAttention: return Theme.accent
        case .idle: return Theme.muted
        case .ended: return Theme.success
        }
    }

    public static func symbol(for status: TodoStatus) -> String {
        switch status {
        case .completed: return "✓"
        case .inProgress: return "◆"
        case .pending: return "◇"
        }
    }

    public static func colorHex(for status: TodoStatus) -> String {
        switch status {
        case .completed: return Theme.success
        case .inProgress: return Theme.teal
        case .pending: return Theme.muted
        }
    }
}
