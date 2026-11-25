import Foundation
import AgentMasterCore
import AgentMasterBridge

/// The server's settings in `<data-dir>/settings.json`: agent options under the Mac app's key names
/// (`agents.<agent>.<option>`), recent projects and the restore toggle. Not UserDefaults: on Linux its
/// CFPreferences backend is unreliable (writing an array crashes a statically linked release build).
public final class ServerSettings: @unchecked Sendable {
    private struct Stored: Codable {
        var options: [String: String] = [:]
        var recentProjects: [String] = []
        var restoreSessionsOnLaunch = true
        /// nil means on.
        var aiSessionTitles: Bool?
        var policies = PolicySettings()
        var notifications = NotificationSettings()

        init() {}

        /// Every key may be missing, so a file written before a setting existed keeps all the others.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            options = try container.decodeIfPresent([String: String].self, forKey: .options) ?? [:]
            recentProjects = try container.decodeIfPresent([String].self, forKey: .recentProjects) ?? []
            restoreSessionsOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .restoreSessionsOnLaunch) ?? true
            aiSessionTitles = try container.decodeIfPresent(Bool.self, forKey: .aiSessionTitles)
            policies = try container.decodeIfPresent(PolicySettings.self, forKey: .policies) ?? PolicySettings()
            notifications = try container.decodeIfPresent(NotificationSettings.self, forKey: .notifications)
                ?? NotificationSettings()
        }
    }

    private let url: URL
    private let lock = NSLock()
    private var stored: Stored

    public init(url: URL) {
        self.url = url
        stored = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    public func preferences(for agentId: String) -> AgentPreferences {
        let prefix = AgentPreferenceStore.key(agentId: agentId, optionId: "")
        return read { stored in
            AgentPreferences(values: Dictionary(uniqueKeysWithValues: stored.options.compactMap { key, value in
                key.hasPrefix(prefix) ? (String(key.dropFirst(prefix.count)), value) : nil
            }))
        }
    }

    /// nil or blank removes the value, which means "follow the agent's own settings".
    public func set(_ value: String?, agentId: String, optionId: String) {
        let key = AgentPreferenceStore.key(agentId: agentId, optionId: optionId)
        write { stored in
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stored.options[key] = value
            } else {
                stored.options[key] = nil
            }
        }
    }

    /// Most recent first; folders deleted since are left out.
    public var recentProjects: [String] {
        read(\.recentProjects).filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    public func recordProject(_ path: String) {
        write { stored in
            stored.recentProjects = Array(([path] + stored.recentProjects.filter { $0 != path }).prefix(RecentProjects.limit))
        }
    }

    public var restoreSessionsOnLaunch: Bool {
        get { read(\.restoreSessionsOnLaunch) }
        set { write { $0.restoreSessionsOnLaunch = newValue } }
    }

    public var aiSessionTitles: Bool {
        get { read { $0.aiSessionTitles ?? true } }
        set { write { $0.aiSessionTitles = newValue } }
    }

    public var policies: PolicySettings {
        get { read(\.policies) }
        set { write { $0.policies = newValue } }
    }

    public var notifications: NotificationSettings {
        get { read(\.notifications) }
        set { write { $0.notifications = newValue } }
    }

    private func read<T>(_ body: (Stored) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(stored)
    }

    private func write(_ body: (inout Stored) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        Self.writeOwnerOnly(data, to: url)
    }

    /// Owner only from the first byte, since webhook URLs carry tokens: a temporary file created 0600, then
    /// renamed over the old one, so a reader never sees a half-written file either.
    static func writeOwnerOnly(_ data: Data, to url: URL) {
        let temporary = url.path + ".tmp-\(getpid())"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { return }
        fchmod(fd, 0o600)   // O_TRUNC kept an older file's mode
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let written = (try? handle.write(contentsOf: data)) != nil
        try? handle.close()
        if written { rename(temporary, url.path) } else { unlink(temporary) }
    }
}
