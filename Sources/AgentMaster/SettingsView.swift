import SwiftUI
import AgentMasterBridge

/// Defaults for new sessions. Stored in UserDefaults and read by `LaunchPreferences` at launch time.
struct SettingsView: View {
    /// "" follows Claude Code's own settings.
    @AppStorage(LaunchPreferences.modeKey) private var mode = ""
    @AppStorage(LaunchPreferences.allowBypassKey) private var allowBypass = true

    var body: some View {
        Form {
            Picker("Default permission mode", selection: $mode) {
                Text("Follow Claude Code settings").tag("")
                Divider()
                ForEach(PermissionMode.allCases, id: \.rawValue) { mode in
                    Text(mode == .manual ? "manual (default)" : mode.rawValue).tag(mode.rawValue)
                }
            }
            Toggle("Allow switching to bypass permissions in a session",
                   isOn: mode == PermissionMode.bypassPermissions.rawValue ? .constant(true) : $allowBypass)
                .disabled(mode == PermissionMode.bypassPermissions.rawValue)
            Text("Applies to new sessions. Running sessions keep their mode; use Shift+Tab to change it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
