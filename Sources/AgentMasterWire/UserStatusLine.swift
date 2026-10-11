import Foundation
import AgentMasterCore

/// The user's own `statusLine` command. The session `--settings` file overrides it with
/// `agentmaster-hook statusline`, so the shim runs it again to keep the user's status line on screen.
public enum UserStatusLine {
    /// Seconds. Claude Code redraws the status line often; a slow script must not stall it.
    public static let defaultTimeout: TimeInterval = 2

    /// Same precedence as Claude Code: local project > project > user.
    public static func settingsFiles(directory: String?, home: String) -> [String] {
        var files: [String] = []
        if let directory, !directory.isEmpty {
            files += [directory + "/.claude/settings.local.json", directory + "/.claude/settings.json"]
        }
        return files + [home + "/.claude/settings.json"]
    }

    /// First `statusLine.command` found in `files`, skipping our own shim so it never calls itself.
    public static func command(in files: [String], read: (String) -> Data? = { FileManager.default.contents(atPath: $0) }) -> String? {
        for file in files {
            guard let data = read(file), let settings = try? JSONValue.parse(data),
                  let statusLine = settings["statusLine"], statusLine["type"]?.stringValue == "command",
                  let command = statusLine["command"]?.stringValue, !command.isEmpty else { continue }
            return command.contains("agentmaster-hook") ? nil : command
        }
        return nil
    }

    public static func directory(of payload: JSONValue) -> String? {
        payload["workspace"]?["current_dir"]?.stringValue ?? payload["cwd"]?.stringValue
    }

    /// Runs `command` through the shell with the status line JSON on stdin; nil on failure, timeout or empty output.
    public static func run(command: String, input: Data, directory: String?,
                           timeout: TimeInterval = defaultTimeout) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        if let directory, FileManager.default.fileExists(atPath: directory) {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }

        // Drain stdout concurrently so a chatty script cannot block on a full pipe.
        var output = Data()
        let reader = DispatchQueue(label: "agentmaster.userstatusline")
        let drained = DispatchSemaphore(value: 0)
        reader.async {
            output = stdout.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        try? stdin.fileHandleForWriting.write(contentsOf: input)
        try? stdin.fileHandleForWriting.close()

        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        drained.wait()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: output, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Resolves and runs the user's status line for `input`, or nil when there is none.
    public static func output(for input: Data, payload: JSONValue, home: String) -> String? {
        let directory = directory(of: payload)
        guard let command = command(in: settingsFiles(directory: directory, home: home)) else { return nil }
        return run(command: command, input: input, directory: directory)
    }
}
