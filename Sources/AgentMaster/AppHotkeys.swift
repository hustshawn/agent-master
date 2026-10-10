import AgentMasterBridge
import AgentMasterUI

/// The menu commands whose shortcuts Settings can change, with their defaults.
enum AppHotkeys {
    static let newSession = HotkeyAction(id: "newSession", title: "New Session", defaultHotkey: Hotkey("n"))
    static let newSessionInFolder = HotkeyAction(id: "newSessionInFolder", title: "New Session in Folder…",
                                                 defaultHotkey: Hotkey("n", shift: true))
    static let toggleInspector = HotkeyAction(id: "toggleInspector", title: "Show/Hide Inspector",
                                              defaultHotkey: Hotkey("0", option: true))
    static let summarize = HotkeyAction(id: "summarize", title: "Summarize Session", defaultHotkey: Hotkey("s", option: true))
    static let closeSession = HotkeyAction(id: "closeSession", title: "Close Session", defaultHotkey: Hotkey("w"))

    /// Starts this agent without the new-session panel; it has a menu item only while it has a shortcut.
    static func newAgentSession(_ agent: any AgentKind) -> HotkeyAction {
        HotkeyAction(id: "newSession." + agent.id, title: "New \(agent.displayName) Session",
                     defaultHotkey: agent.shortcut.map {
                         Hotkey(String($0.key), option: $0.option, shift: $0.shift, control: $0.control)
                     })
    }

    static var all: [HotkeyAction] {
        [newSession, newSessionInFolder] + AgentRegistry.all.map(newAgentSession)
            + [summarize, toggleInspector, closeSession]
    }
}
