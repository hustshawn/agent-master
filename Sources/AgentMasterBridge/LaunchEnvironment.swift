import Foundation

public enum LaunchEnvironment {
    /// Markers a parent Claude Code / cmux session leaves behind. Inheriting them makes the child
    /// claude think it is a nested session (e.g. CLAUDE_CODE_CHILD_SESSION stops transcripts being saved).
    public static let strippedKeys: Set<String> = [
        "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
        "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_PID", "CLAUDE_JOB_DIR", "CLAUDE_EFFORT",
        "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
    ]
    static let strippedPrefixes = ["CMUX_", "AGENTMASTER_"]

    public static func sessionEnvironment(base: [String: String], sessionId: String, socketPath: String) -> [String: String] {
        var env = base.filter { key, _ in
            !strippedKeys.contains(key) && !strippedPrefixes.contains { key.hasPrefix($0) }
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["AGENTMASTER_SESSION_ID"] = sessionId
        env["AGENTMASTER_SOCKET"] = socketPath
        return env
    }

    /// Parses `env -0` output, ignoring anything the shell printed before `marker`.
    public static func parseEnvDump(_ data: Data, marker: String) -> [String: String]? {
        guard let range = data.range(of: Data(marker.utf8)) else { return nil }
        var env: [String: String] = [:]
        for entry in data[range.upperBound...].split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let equals = text.firstIndex(of: "="), equals != text.startIndex else { continue }
            env[String(text[..<equals])] = String(text[text.index(after: equals)...])
        }
        return env
    }

    /// The environment a Terminal window would have (PATH, credentials, proxies…). GUI apps
    /// launched from Finder do not get it. Returns nil if the shell fails or exceeds `timeout`.
    public static func captureLoginShell(shell: String = userShell, timeout: TimeInterval = 5) -> [String: String]? {
        let marker = "__AGENTMASTER_ENV_\(UUID().uuidString)__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '%s' '\(marker)'; /usr/bin/env -0"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return nil
        }

        let output = DataBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard let env = parseEnvDump(output.data, marker: marker), !env.isEmpty else { return nil }
        return env
    }

    public static var userShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}

/// Written by the reader thread before `done.signal()`, read after `done.wait()`.
private final class DataBox {
    var data = Data()
}
