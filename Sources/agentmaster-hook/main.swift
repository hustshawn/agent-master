import Foundation
import AgentMasterWire

// Invoked by Claude Code as a hook (`hook`) and as the statusLine command (`statusline`).
// Always exits 0: a failing hook must never disturb the user's session.
let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment

if arguments.first == "settings" {
    let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
    let data = (try? SessionSettingsBuilder(hookExecutable: executable).data()) ?? Data()
    FileHandle.standardOutput.write(data)
    exit(0)
}

let mode = arguments.first.flatMap(ShimMode.init(rawValue:)) ?? .hook
let input = FileHandle.standardInput.readDataToEndOfFile()
let connector: WireConnector? = environment["AGENTMASTER_SOCKET"].map { UnixWireConnector(path: $0) }
let home = environment["HOME"] ?? NSHomeDirectory()
let output = HookShim.run(
    mode: mode, input: input, environment: environment, connector: connector,
    userStatusLine: { data, payload in UserStatusLine.output(for: data, payload: payload, home: home) }
)
if let output {
    FileHandle.standardOutput.write(Data(output.utf8))
}
exit(0)
