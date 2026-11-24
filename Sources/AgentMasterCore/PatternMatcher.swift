import Foundation

/// The user's dangerous-command patterns, compiled once and run with a deadline: a regular expression can
/// backtrack for minutes, and the caller is the hook server's only accept thread.
enum PatternMatcher {
    enum Result: Equatable {
        case match(String)
        case none
        case timedOut
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var compiled: [String: NSRegularExpression?] = [:]

    /// The first pattern that matches one of `texts`, case-insensitively; patterns that do not compile are skipped.
    /// Past `timeout` the caller goes on with `.timedOut`; the match keeps a background thread until it ends.
    static func firstMatch(_ texts: [String], patterns: [String], timeout: TimeInterval) -> Result {
        let regexes = patterns.compactMap { pattern in regex(pattern).map { (pattern, $0) } }
        guard !regexes.isEmpty else { return .none }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let found = regexes.first { _, regex in
                texts.contains { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            }
            box.set(found.map { .match($0.0) } ?? .none)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return .timedOut }
        return box.get()
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = compiled[pattern] { return cached }
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        if compiled.count > 256 { compiled.removeAll() }
        compiled[pattern] = regex
        return regex
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var result = Result.none
        func set(_ value: Result) { lock.lock(); result = value; lock.unlock() }
        func get() -> Result { lock.lock(); defer { lock.unlock() }; return result }
    }
}
