import Foundation

/// Runs an agent's CLI for something it prints, such as its model list.
enum CommandOutput {
    /// What `binary` printed, if it exited 0 within `timeout`.
    static func run(_ binary: String, arguments: [String], environment: [String: String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
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
        process.waitUntilExit()
        return process.terminationStatus == 0 ? output.data : nil
    }
}
