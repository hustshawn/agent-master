import Foundation

public enum ClaudeLocator {
    /// Finds the real Claude Code binary. The cmux app ships a same-named wrapper that must be skipped.
    public static func locate(
        environment: [String: String],
        home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        var candidates: [String] = []
        if let override = environment["AGENTMASTER_CLAUDE_PATH"], !override.isEmpty { candidates.append(override) }
        candidates += [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/claude" }
        return candidates.first { !$0.contains("cmux.app") && isExecutable($0) }
    }
}
