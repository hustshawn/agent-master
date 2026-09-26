import Foundation

public enum TokenFormat {
    /// 753 → "753", 1600 → "1.6k", 1_250_000 → "1.2M".
    public static func short(_ count: Int) -> String {
        if count < 1000 { return "\(count)" }
        if count < 1_000_000 { return trimmed(Double(count) / 1000) + "k" }
        return trimmed(Double(count) / 1_000_000) + "M"
    }

    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}

public enum DurationFormat {
    /// 3.7 → "3s", 65 → "1m 5s", 3720 → "1h 2m".
    public static func short(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}
