import Foundation

public struct TerminalLaunch: Equatable {
    public var executable: String
    public var args: [String]
    public var environment: [String: String]
    public var currentDirectory: String

    public init(executable: String, args: [String], environment: [String: String], currentDirectory: String) {
        self.executable = executable
        self.args = args
        self.environment = environment
        self.currentDirectory = currentDirectory
    }

    /// SwiftTerm takes the child environment as `KEY=value` strings; sorted for deterministic tests.
    public var environmentStrings: [String] {
        environment.map { "\($0.key)=\($0.value)" }.sorted()
    }
}
