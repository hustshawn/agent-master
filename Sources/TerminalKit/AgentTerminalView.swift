import AppKit
import SwiftTerm

/// The terminal every session runs in. It handles ⌘V itself: SwiftUI disables Edit → Paste when the
/// clipboard holds only an image (a screenshot), so the shortcut would never reach the terminal.
public final class AgentTerminalView: LocalProcessTerminalView {
    /// Where relative paths in the output are resolved from: the session's project directory.
    var workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path

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

    /// SwiftTerm drops the selection on every chunk of output while mouse reporting is allowed, so a running
    /// agent's spinner clears it before ⌘C. Mouse reporting is held off while something is selected; the click
    /// or key press that ends the selection turns it back on.
    public override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        allowMouseReporting = !selection.active
    }

    /// SwiftTerm opens a clicked path with `URL(string:)`, and a URL with no scheme fails in Finder with -50.
    public override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = Self.linkURL(link, relativeTo: workingDirectory) {
            NSWorkspace.shared.open(url)
        } else {
            NSSound.beep()
        }
    }

    /// A URL with a scheme as is; a path as a file URL, relative to `directory`. A trailing `:line:col` or
    /// sentence punctuation is dropped when the path does not exist with it. `nil` when no such file exists.
    static func linkURL(_ link: String, relativeTo directory: String) -> URL? {
        let text = link.trimmingCharacters(in: .whitespaces)
        if let url = URL(string: text), url.scheme != nil { return url }
        let path = (text as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: directory, isDirectory: true)
        return [path, path.replacingOccurrences(of: #"(:\d+)*[.,]*$"#, with: "", options: .regularExpression)]
            .map { URL(fileURLWithPath: $0, relativeTo: base).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.path) }
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
