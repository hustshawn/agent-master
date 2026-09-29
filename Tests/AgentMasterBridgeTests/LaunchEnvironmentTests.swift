import XCTest
@testable import AgentMasterBridge

final class LaunchEnvironmentTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("am-env-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeShell(_ body: String) throws -> String {
        let url = scratch.appendingPathComponent("fake-shell")
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func testSessionEnvironmentStripsSessionMarkersAndKeepsCredentials() {
        var base = Dictionary(uniqueKeysWithValues: LaunchEnvironment.strippedKeys.map { ($0, "x") })
        base["CMUX_SOCKET_PATH"] = "/tmp/cmux"
        base["AGENTMASTER_SESSION_ID"] = "stale"
        base["AGENTMASTER_EXTRA"] = "stale"
        base["CLAUDE_CODE_USE_BEDROCK"] = "1"
        base["ANTHROPIC_MODEL"] = "opus"
        base["AWS_PROFILE"] = "dev"
        base["AWS_REGION"] = "us-west-2"
        base["PATH"] = "/usr/bin:/bin"
        base["TERM"] = "dumb"

        let env = LaunchEnvironment.sessionEnvironment(base: base, sessionId: "S1", socketPath: "/tmp/a.sock")

        for key in LaunchEnvironment.strippedKeys { XCTAssertNil(env[key], key) }
        XCTAssertNil(env["CMUX_SOCKET_PATH"])
        XCTAssertNil(env["AGENTMASTER_EXTRA"])
        XCTAssertEqual(env["CLAUDE_CODE_USE_BEDROCK"], "1")
        XCTAssertEqual(env["ANTHROPIC_MODEL"], "opus")
        XCTAssertEqual(env["AWS_PROFILE"], "dev")
        XCTAssertEqual(env["AWS_REGION"], "us-west-2")
        XCTAssertEqual(env["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["COLORTERM"], "truecolor")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
        XCTAssertEqual(env["AGENTMASTER_SESSION_ID"], "S1")
        XCTAssertEqual(env["AGENTMASTER_SOCKET"], "/tmp/a.sock")
    }

    func testStrippedKeysCoverTheKnownSessionMarkers() {
        XCTAssertTrue(LaunchEnvironment.strippedKeys.isSuperset(of: [
            "CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT",
            "CLAUDE_CODE_EXECPATH", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
            "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_PID", "CLAUDE_JOB_DIR", "CLAUDE_EFFORT",
            "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
        ]))
        XCTAssertFalse(LaunchEnvironment.strippedKeys.contains("CLAUDE_CODE_USE_BEDROCK"))
    }

    func testExistingLangIsKept() {
        let env = LaunchEnvironment.sessionEnvironment(base: ["LANG": "zh_CN.UTF-8"], sessionId: "S", socketPath: "/s")
        XCTAssertEqual(env["LANG"], "zh_CN.UTF-8")
    }

    func testParseEnvDumpDropsNoiseBeforeMarkerAndKeepsMultilineValues() {
        let data = Data("Last login: Fri\nA=noise\nMARKA=1\u{0}B=x=y\nz\u{0}junk\u{0}=bad\u{0}".utf8)
        XCTAssertEqual(LaunchEnvironment.parseEnvDump(data, marker: "MARK"), ["A": "1", "B": "x=y\nz"])
        XCTAssertNil(LaunchEnvironment.parseEnvDump(Data("A=1\u{0}".utf8), marker: "MARK"))
    }

    func testCaptureLoginShellIgnoresStartupNoise() throws {
        let shell = try makeShell("""
        echo "Welcome! motd NOISE=1"
        export AM_CAPTURE_PROBE=works
        exec /bin/sh -c "$4"
        """)
        let env = try XCTUnwrap(LaunchEnvironment.captureLoginShell(shell: shell, timeout: 5))
        XCTAssertEqual(env["AM_CAPTURE_PROBE"], "works")
        XCTAssertFalse(env.keys.contains { $0.contains("Welcome") || $0.contains("NOISE") })
    }

    func testCaptureLoginShellGivesUpOnAHangingShell() throws {
        let shell = try makeShell("sleep 20\n")
        let start = Date()
        XCTAssertNil(LaunchEnvironment.captureLoginShell(shell: shell, timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testCaptureTimeoutKillsAShellThatIgnoresSIGTERMAndItsChildren() throws {
        // Interactive zsh ignores SIGTERM; a hung rc child also keeps the output pipe open.
        let shellPid = scratch.appendingPathComponent("shell.pid").path
        let childPid = scratch.appendingPathComponent("child.pid").path
        let shell = try makeShell("""
        trap '' TERM
        echo $$ > '\(shellPid)'
        sleep 30 &
        echo $! > '\(childPid)'
        wait
        """)
        let start = Date()
        // The shell must write its pids before the timeout. A freshly written script can take ~0.45 s to start
        // on its first run (macOS checks new executables), so 0.5 s was too tight.
        XCTAssertNil(LaunchEnvironment.captureLoginShell(shell: shell, timeout: 2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        let pids = try [shellPid, childPid].map { try XCTUnwrap(Int32(String(contentsOfFile: $0).trimmingCharacters(in: .whitespacesAndNewlines))) }
        // kill(pid, 0) still succeeds on a zombie, so this also checks the shell was reaped.
        XCTAssertTrue(kill(pids[0], 0) != 0, "the shell must be killed and reaped")
        let deadline = Date().addingTimeInterval(2)   // the orphaned child is reaped by launchd
        while !Self.isDead(pids[1]) && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertTrue(Self.isDead(pids[1]), "the shell's children must be killed too")
    }

    /// Gone, or a zombie nobody reaps: a container whose PID 1 does not reap orphans (GitHub's container jobs
    /// run `tail -f /dev/null`) leaves the killed child as a zombie, which kill(pid, 0) still reports as alive.
    private static func isDead(_ pid: pid_t) -> Bool {
        if kill(pid, 0) != 0 { return true }
        #if os(Linux)
        // /proc/<pid>/stat: "pid (comm) state …"; the state follows the last ')'.
        if let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
           let close = stat.lastIndex(of: ")") {
            return stat[stat.index(after: close)...].trimmingCharacters(in: .whitespaces).hasPrefix("Z")
        }
        #endif
        return false
    }

    func testCaptureRealLoginShell() {
        let env = LaunchEnvironment.captureLoginShell(timeout: 10)
        XCTAssertNotNil(env?["PATH"], "the user's login shell (\(LaunchEnvironment.userShell)) should produce a PATH")
    }
}
