import AppKit
import SwiftTerm

/// The terminal every session runs in. It handles ⌘V itself: SwiftUI disables Edit → Paste when the
/// clipboard holds only an image (a screenshot), so the shortcut would never reach the terminal.
public final class AgentTerminalView: LocalProcessTerminalView {
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers == "v"
        else { return super.performKeyEquivalent(with: event) }
        if let bytes = Self.pasteInput(pasteboard: .general, kittyKeyboard: !getTerminal().keyboardEnhancementFlags.isEmpty) {
            send(txt: bytes)
        } else {
            paste(self)
        }
        return true
    }

    /// Ctrl+V when the clipboard has an image and no text: Claude Code and Codex read the image from
    /// the clipboard on Ctrl+V, and Codex ignores the empty paste a text-only paste would send.
    /// `nil` means paste the text as usual.
    static func pasteInput(pasteboard: NSPasteboard, kittyKeyboard: Bool) -> String? {
        guard pasteboard.string(forType: .string) == nil,
              pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
        else { return nil }
        return kittyKeyboard ? "\u{1b}[118;5u" : "\u{16}"
    }
}
