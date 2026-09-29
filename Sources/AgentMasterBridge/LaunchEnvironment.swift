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
        let arguments = [shell, "-l", "-i", "-c", "printf '%s' '\(marker)'; /usr/bin/env -0"]
        let pipe = Pipe()
        guard let pid = spawnInOwnProcessGroup(shell, arguments: arguments,
                                               stdout: pipe.fileHandleForWriting.fileDescriptor) else { return nil }
        try? pipe.fileHandleForWriting.close()   // only the shell's group holds the write end now

        let output = DataBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            // Interactive shells ignore SIGTERM, and a hung rc child keeps the pipe open: kill the whole group.
            kill(-pid, SIGTERM)
            Thread.sleep(forTimeInterval: 0.2)
            kill(-pid, SIGKILL)
            reap(pid)
            _ = done.wait(timeout: .now() + 1)   // the reader sees EOF once the group is gone
            return nil
        }
        reap(pid)
        guard let env = parseEnvDump(output.data, marker: marker), !env.isEmpty else { return nil }
        return env
    }

    /// Like Process, but the child leads a new session (and so a new process group) so a timeout can kill
    /// everything it started. A new session, not just a new group: an interactive zsh left in the caller's
    /// session opens the controlling tty from a background group and is stopped by SIGTTOU/SIGTTIN.
    private static func spawnInOwnProcessGroup(_ path: String, arguments: [String], stdout: Int32) -> pid_t? {
        #if os(Linux)
        // glibc: the spawn types are structs, and there is no POSIX_SPAWN_CLOEXEC_DEFAULT (the server captures
        // this before it opens any socket, so nothing is inherited that matters).
        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attributes = posix_spawnattr_t()
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let setsid: Int32 = 0x80   // POSIX_SPAWN_SETSID (glibc 2.26+), not exported to Swift without _GNU_SOURCE
        posix_spawnattr_setflags(&attributes, Int16(setsid | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var signals = sigset_t()
        sigfillset(&signals)
        posix_spawnattr_setsigdefault(&attributes, &signals)
        sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attributes, &signals)

        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &actions, &attributes, argv, environ) == 0 else { return nil }
        return pid
        #else
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT
                                                     | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var signals = sigset_t()
        sigfillset(&signals)
        posix_spawnattr_setsigdefault(&attributes, &signals)
        sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attributes, &signals)

        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &actions, &attributes, argv, environ) == 0 else { return nil }
        return pid
        #endif
    }

    private static func reap(_ pid: pid_t) {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
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
