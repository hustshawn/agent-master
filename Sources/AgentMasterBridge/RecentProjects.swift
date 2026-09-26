import Foundation

/// Project directories sessions were started in, most recent first. Backs the New session menu.
public struct RecentProjects {
    public static let key = "recentProjects"
    public static let limit = 10

    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Directories deleted since they were recorded are left out.
    public var paths: [String] {
        stored.filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    public func record(_ path: String) {
        defaults.set(Array(([path] + stored.filter { $0 != path }).prefix(Self.limit)), forKey: Self.key)
    }

    private var stored: [String] { defaults.stringArray(forKey: Self.key) ?? [] }
}
