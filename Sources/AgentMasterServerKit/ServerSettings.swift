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
        if let data = try? encoder.encode(stored) { try? data.write(to: url, options: .atomic) }
    }
}
