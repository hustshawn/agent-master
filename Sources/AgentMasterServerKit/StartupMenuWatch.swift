import Foundation

/// Until an agent's first prompt, watches its terminal for a menu only the terminal can answer: Claude Code asking
/// to trust the folder, Kiro warning about trust-all-tools mode or asking to trust the workspace, Codex offering an
/// update. Kiro reports itself ready before it shows its menu, so the session looks idle, and the Enter of a message
/// typed from Chat would pick the menu's default choice (Kiro's is "No, exit").
struct StartupMenuWatch {
    /// The key hints under those menus, without whitespace: TUIs style and space words with escape sequences.
    static let hints = ["↑↓tonavigate", "Entertoconfirm·Esctocancel", "entercontinue·escskip"]
    /// Enough to hold one redrawn menu.
    static let tailLimit = 16 * 1024
    /// CSI, OSC, charset and other two-character escape sequences.
    private static let escapeSequence = #"\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\)|[()][0-9A-Za-z]|[@-_])"#

    /// The agent's `promptHints`, without whitespace.
    private let promptHints: [String]
    /// What the agent printed since the menu was last answered.
    private var tail = Data()
    private(set) var isShowing = false
    /// Its empty prompt has been on screen with no menu over it.
    private(set) var isPromptReady = false

    init(promptHints: [String] = []) {
        self.promptHints = promptHints.map { $0.filter { !$0.isWhitespace } }
    }

    mutating func output(_ data: Data) {
        guard !isShowing else { return }
        tail.append(data)
        if tail.count > Self.tailLimit { tail = Data(tail.suffix(Self.tailLimit)) }
        let text = String(decoding: tail, as: UTF8.self)
            .replacingOccurrences(of: Self.escapeSequence, with: "", options: .regularExpression)
            .filter { !$0.isWhitespace }
        isShowing = Self.hints.contains { text.contains($0) }
        if !isShowing, promptHints.contains(where: { text.contains($0) }) { isPromptReady = true }
    }

    /// Enter, Esc or a digit answers a menu; the agent draws it again if it is still there. Arrow keys, typed text
    /// and what the browser's terminal reports by itself (device attributes, focus) leave it open.
    mutating func input(_ data: Data) {
        let digit = data.count == 1 && (0x30...0x39).contains(data[data.startIndex])
        guard data.contains(0x0D) || data == Data([0x1B]) || digit else { return }
        isShowing = false
        tail = Data()
    }
}
