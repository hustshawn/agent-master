import SwiftUI
import AppKit

/// A key combination: one printable key plus modifiers, or modifiers alone (`key` empty) for the
/// session-switching digits, whose keys are fixed.
public struct Hotkey: Equatable, Hashable, Codable, Sendable {
    public var key: String
    public var command: Bool
    public var option: Bool
    public var shift: Bool
    public var control: Bool

    public init(_ key: String, command: Bool = true, option: Bool = false, shift: Bool = false, control: Bool = false) {
        self.key = key.lowercased()
        self.command = command
        self.option = option
        self.shift = shift
        self.control = control
    }

    public var modifiersOnly: Hotkey { Hotkey("", command: command, option: option, shift: shift, control: control) }

    /// In the order macOS menus draw them: ⌃⌥⇧⌘ then the key.
    public var symbols: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key.uppercased()
    }

    public var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if option { modifiers.insert(.option) }
        if shift { modifiers.insert(.shift) }
        if control { modifiers.insert(.control) }
        return modifiers
    }

    public var keyboardShortcut: KeyboardShortcut? {
        key.count == 1 ? KeyboardShortcut(KeyEquivalent(Character(key)), modifiers: eventModifiers) : nil
    }

    /// The combination an event was typed with; the key unshifted, so ⇧⌘1 reads as "1", not "!".
    public init?(event: NSEvent) {
        let flags = event.modifierFlags
        guard let key = event.characters(byApplyingModifiers: []), key.count == 1 else { return nil }
        self.init(key, command: flags.contains(.command), option: flags.contains(.option),
                  shift: flags.contains(.shift), control: flags.contains(.control))
    }

    /// Whether `flags` (from an event) are exactly these modifiers.
    public func matches(_ flags: NSEvent.ModifierFlags) -> Bool {
        modifiersOnly == Hotkey("", command: flags.contains(.command), option: flags.contains(.option),
                                shift: flags.contains(.shift), control: flags.contains(.control))
    }
}

/// A menu command whose shortcut can be changed in Settings.
public struct HotkeyAction: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let defaultHotkey: Hotkey?

    public init(id: String, title: String, defaultHotkey: Hotkey?) {
        self.id = id
        self.title = title
        self.defaultHotkey = defaultHotkey
    }
}

/// The user's changes to the default shortcuts, stored as JSON in one UserDefaults key. An action set to
/// nil has had its shortcut removed.
public struct HotkeyMap: Equatable, RawRepresentable, Sendable {
    public static let storageKey = "hotkeys"
    public static let switchSessionId = "switchSession"
    public static let defaultSwitchModifiers = Hotkey("")
    /// The modifiers offered for ⌘1…⌘9; with ⇧ the digits would type symbols on many layouts.
    public static let switchModifierChoices = [Hotkey(""), Hotkey("", command: false, control: true),
                                               Hotkey("", command: false, option: true), Hotkey("", control: true),
                                               Hotkey("", option: true)]
    /// Standard macOS commands no action may take over.
    static let reserved: [Hotkey: String] = [
        Hotkey("q"): "Quit", Hotkey("h"): "Hide", Hotkey("h", option: true): "Hide Others", Hotkey("m"): "Minimize",
        Hotkey(","): "Settings", Hotkey("`"): "the next window", Hotkey("c"): "Copy", Hotkey("v"): "Paste",
        Hotkey("x"): "Cut", Hotkey("a"): "Select All", Hotkey("z"): "Undo", Hotkey("z", shift: true): "Redo",
    ]

    public private(set) var overrides: [String: Hotkey?]

    public init() { overrides = [:] }

    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let overrides = try? JSONDecoder().decode([String: Hotkey?].self, from: data) else { return nil }
        self.overrides = overrides
    }

    /// Sorted keys: RawRepresentable's `==` compares this string, so the same map must always encode alike.
    public var rawValue: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(overrides)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    public func hotkey(for action: HotkeyAction) -> Hotkey? {
        if let override = overrides[action.id] { return override }
        return action.defaultHotkey
    }

    public var switchModifiers: Hotkey {
        (overrides[Self.switchSessionId] ?? nil) ?? Self.defaultSwitchModifiers
    }

    public func isCustomized(_ id: String) -> Bool { overrides[id] != nil }

    public mutating func set(_ hotkey: Hotkey?, for id: String) { overrides[id] = .some(hotkey) }

    public mutating func reset(_ id: String) { overrides[id] = nil }

    /// Why `hotkey` can't be given to action `id`, or nil when it can.
    public func problem(with hotkey: Hotkey, for id: String, among actions: [HotkeyAction]) -> String? {
        if id == Self.switchSessionId {
            let clash = actions.first { action in
                guard let other = self.hotkey(for: action), "123456789".contains(other.key), other.key.count == 1
                else { return false }
                return other.modifiersOnly == hotkey
            }
            return clash.map { "\(hotkey.symbols)1…9 would take \($0.title)’s shortcut" }
        }
        guard hotkey.command || hotkey.control || hotkey.option else { return "Include ⌘, ⌃ or ⌥" }
        guard let scalar = hotkey.key.unicodeScalars.first, hotkey.key.unicodeScalars.count == 1,
              (0x21...0x7E).contains(scalar.value) else { return "Use a letter, digit or symbol key" }
        if let name = Self.reserved[hotkey] { return "\(hotkey.symbols) is macOS’s \(name)" }
        if "123456789".contains(hotkey.key), hotkey.modifiersOnly == switchModifiers {
            return "\(hotkey.symbols) switches sessions"
        }
        if let other = actions.first(where: { $0.id != id && self.hotkey(for: $0) == hotkey }) {
            return "\(hotkey.symbols) is already used by \(other.title)"
        }
        return nil
    }
}

/// Click, then type the new shortcut. Esc cancels; Delete removes the shortcut.
public struct HotkeyRecorder: View {
    let hotkey: Hotkey?
    let validate: (Hotkey) -> String?
    let onSet: (Hotkey?) -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    public init(hotkey: Hotkey?, validate: @escaping (Hotkey) -> String?, onSet: @escaping (Hotkey?) -> Void) {
        self.hotkey = hotkey
        self.validate = validate
        self.onSet = onSet
    }

    public var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Button(recording ? "Type a shortcut…" : hotkey?.symbols ?? "None") {
                recording ? stop() : start()
            }
            .frame(minWidth: 110)
            if let message {
                Text(message).font(.caption).foregroundStyle(Palette.warning)
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        message = nil
        recording = true
        // Local monitors see the key before the menus, so typing a taken shortcut doesn't also run it.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 53: stop()                                  // Esc
            case 51, 117: onSet(nil); stop()                 // Delete, Forward Delete
            default:
                guard let typed = Hotkey(event: event) else { message = "Use a letter, digit or symbol key"; break }
                if let problem = validate(typed) { message = problem; break }
                onSet(typed)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
