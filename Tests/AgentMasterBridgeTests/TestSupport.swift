import Foundation
import XCTest
import AgentMasterCore
@testable import AgentMasterBridge

enum Fixtures {
    /// One hook payload per line, exactly as Claude Code wrote it to the hook's stdin.
    static func payloads(_ name: String) throws -> [JSONValue] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONValue.parse(Data($0.utf8)) }
    }

    static func json(_ name: String) throws -> JSONValue {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSONValue.parse(Data(contentsOf: url))
    }

    static func translate(_ name: String, dialect: any HookDialect = ClaudeHookDialect()) throws -> [SessionEvent] {
        var translator = HookTranslator(dialect: dialect)
        return try payloads(name).flatMap { translator.translate($0) }
    }
}

/// A scratch install for launch tests: fake agent binaries and an app bundle with or without the hook helper.
struct FakeInstall {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("am-install-\(UUID().uuidString.prefix(8))")

    /// An executable shell script at `root/bin/<name>`.
    func executable(_ name: String) throws -> String {
        try script(root.appendingPathComponent("bin/\(name)"))
    }

    /// Each variant gets its own bundle so one call's hook helper cannot leak into another's.
    func paths(withHook: Bool = true) throws -> AppPaths {
        let bundle = root.appendingPathComponent(withHook ? "AM.app" : "NoHook.app")
        if withHook { _ = try script(bundle.appendingPathComponent("Contents/Helpers/agentmaster-hook")) }
        return AppPaths(supportDirectory: root.appendingPathComponent("Support"), bundleURL: bundle,
                        executableURL: bundle.appendingPathComponent("Contents/MacOS/AgentMaster"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func script(_ url: URL) throws -> String {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}

/// Thread-safe mutable cell for values shared with background threads in tests.
final class Box<Value> {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&stored)
        lock.unlock()
    }
}

func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}
