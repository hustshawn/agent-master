import Foundation
import AgentMasterCore

public enum GeneralSettings {
    public static let restoreSessionsOnLaunchKey = "restoreSessionsOnLaunch"

    public static func restoreSessionsOnLaunch(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: restoreSessionsOnLaunchKey) as? Bool ?? true
    }

    /// Whether a session's first turn gets it an AI title (see SessionTitler) instead of its first prompt.
    public static let aiSessionTitlesKey = "aiSessionTitles"

    public static func aiSessionTitles(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: aiSessionTitlesKey) as? Bool ?? true
    }

    /// The policy rules (ADR 0017), as the JSON the server keeps under the same key in settings.json.
    public static let policiesKey = "policies"

    /// Read on every tool call, so the decoded value is kept until the stored text changes.
    public static func policies(_ defaults: UserDefaults) -> PolicySettings {
        let raw = defaults.string(forKey: policiesKey)
        return policiesCache.value(for: raw) {
            raw.flatMap { try? JSONDecoder().decode(PolicySettings.self, from: Data($0.utf8)) } ?? PolicySettings()
        }
    }

    private static let policiesCache = DecodedCache()

    private final class DecodedCache: @unchecked Sendable {
        private let lock = NSLock()
        private var raw: String??
        private var value = PolicySettings()

        func value(for raw: String?, decode: () -> PolicySettings) -> PolicySettings {
            lock.lock()
            defer { lock.unlock() }
            if self.raw != .some(raw) {
                value = decode()
                self.raw = .some(raw)
            }
            return value
        }
    }

    public static func setPolicies(_ policies: PolicySettings, _ defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(policies) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: policiesKey)
    }
}

/// What the app knows about one open session when it writes the journal.
public struct OpenSessionSnapshot {
    public let agentId: String
    public let projectPath: String
    public let createdAt: Date
    public let state: SessionState
    public let selected: Bool
    /// The id a restored session was launched with, until its own SessionStart reports one.
    public let fallbackResumeId: String?
    public let title: String?
    public let reviewed: Bool?

    public init(agentId: String, projectPath: String, createdAt: Date, state: SessionState, selected: Bool,
                fallbackResumeId: String?, title: String? = nil, reviewed: Bool? = nil) {
        self.agentId = agentId
        self.projectPath = projectPath
        self.createdAt = createdAt
        self.state = state
        self.selected = selected
        self.fallbackResumeId = fallbackResumeId
        self.title = title
        self.reviewed = reviewed
    }
}

public enum RestorePlan {
    /// Sessions worth reopening: not ended, of an agent that can resume, with an id to resume.
    public static func records(from snapshots: [OpenSessionSnapshot], agents: [any AgentKind]) -> [OpenSessionRecord] {
        snapshots.compactMap { snapshot in
            guard snapshot.state.status != .ended,
                  let agent = agents.first(where: { $0.id == snapshot.agentId }), agent.supportsResume,
                  let resumeId = agent.resumeId(from: snapshot.state) ?? snapshot.fallbackResumeId
            else { return nil }
            return OpenSessionRecord(agentId: snapshot.agentId, projectPath: snapshot.projectPath,
                                     createdAt: snapshot.createdAt, resumeId: resumeId, selected: snapshot.selected,
                                     title: snapshot.title, reviewed: snapshot.reviewed,
                                     lastActivityAt: snapshot.state.lastActivityAt)
        }
    }

    /// The records to relaunch, oldest first so the sidebar keeps its order.
    public static func make(records: [OpenSessionRecord], agents: [any AgentKind],
                            directoryExists: (String) -> Bool) -> [OpenSessionRecord] {
        records
            .filter { record in
                !record.resumeId.isEmpty
                    && agents.contains { $0.id == record.agentId && $0.supportsResume }
                    && directoryExists(record.projectPath)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }
}

/// `open-sessions.json`, rewritten whenever the open sessions change so a crash still restores.
public final class OpenSessionJournal {
    private let fileURL: URL
    private var frozen = false
    private var lastSaved: [OpenSessionRecord]?

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// A missing or unreadable file means nothing to restore.
    public func load() -> [OpenSessionRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([OpenSessionRecord].self, from: data) else { return [] }
        return records
    }

    public func save(_ records: [OpenSessionRecord]) {
        guard !frozen, records != lastSaved, let data = try? JSONEncoder().encode(records) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: fileURL, options: .atomic)) != nil { lastSaved = records }
    }

    /// Called as quitting starts: terminating the sessions marks them ended, which must not reach the file.
    public func freeze() {
        frozen = true
    }
}
