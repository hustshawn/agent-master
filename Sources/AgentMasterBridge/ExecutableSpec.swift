import Foundation

/// Where an agent's binary may live. Lookup order: the override variable, `~/.local/bin`, Homebrew,
/// `/usr/local/bin`, then the login shell's `PATH`.
public struct ExecutableSpec: Equatable, Sendable {
    public let name: String
    /// An environment variable holding an explicit path, e.g. `AGENTMASTER_CLAUDE_PATH`.
    public let overrideVariable: String
    /// Path fragments to skip, e.g. a same-named wrapper another app ships.
    public let excluding: [String]

    public init(name: String, overrideVariable: String, excluding: [String] = []) {
        self.name = name
        self.overrideVariable = overrideVariable
        self.excluding = excluding
    }

    public func locate(
        environment: [String: String],
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        var candidates: [String] = []
        if let override = environment[overrideVariable], !override.isEmpty { candidates.append(override) }
        candidates += ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }
        return candidates.first { candidate in !excluding.contains { candidate.contains($0) } && isExecutable(candidate) }
    }
}
