import Foundation

/// The values `claude --permission-mode` accepts.
public enum PermissionMode: String, CaseIterable, Sendable {
    case manual, acceptEdits, plan, auto, dontAsk, bypassPermissions
}

/// How new sessions launch claude, chosen in Settings. Running sessions are not affected.
public struct LaunchPreferences: Equatable, Sendable {
    public static let modeKey = "defaultPermissionMode"
    public static let allowBypassKey = "allowBypassPermissions"

    /// nil follows Claude Code's own settings (`permissions.defaultMode`).
    public var mode: PermissionMode?
    /// Lets Shift+Tab reach bypass even when the session starts in another mode.
    public var allowBypass: Bool

    public init(mode: PermissionMode?, allowBypass: Bool) {
        self.mode = mode
        self.allowBypass = allowBypass
    }

    public init(defaults: UserDefaults) {
        mode = defaults.string(forKey: Self.modeKey).flatMap(PermissionMode.init(rawValue:))
        allowBypass = defaults.object(forKey: Self.allowBypassKey) as? Bool ?? true
    }

    public var bypassAllowed: Bool { allowBypass || mode == .bypassPermissions }

    public func claudeArguments(settingsPath: String) -> [String] {
        var args = ["--settings", settingsPath]
        if let mode { args += ["--permission-mode", mode.rawValue] }
        if bypassAllowed { args.append("--allow-dangerously-skip-permissions") }
        return args
    }
}
