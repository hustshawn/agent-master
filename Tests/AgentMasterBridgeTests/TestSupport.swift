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

    static func translate(_ name: String) throws -> [SessionEvent] {
        var translator = HookTranslator()
        return try payloads(name).flatMap { translator.translate($0) }
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
