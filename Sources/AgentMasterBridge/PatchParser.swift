import Foundation
import AgentMasterCore

/// Reads the `structuredPatch` that Edit/MultiEdit/Write report in PostToolUse `tool_response`.
public enum PatchParser {
    public static func change(fromToolResponse response: JSONValue) -> FileChange? {
        guard let path = response["filePath"]?.stringValue else { return nil }
        let hunks = (response["structuredPatch"]?.arrayValue ?? []).compactMap(hunk)
        if !hunks.isEmpty { return FileChange(path: path, hunks: hunks) }
        guard response["type"]?.stringValue == "create" else { return nil }
        let lines = splitLines(response["content"]?.stringValue ?? "")
        guard !lines.isEmpty else { return FileChange(path: path, hunks: []) }
        return FileChange(path: path, hunks: [
            DiffHunk(oldStart: 0, oldLines: 0, newStart: 1, newLines: lines.count,
                     lines: lines.map { DiffLine(kind: .added, text: $0) }),
        ])
    }

    private static func hunk(_ value: JSONValue) -> DiffHunk? {
        guard let rawLines = value["lines"]?.arrayValue else { return nil }
        let lines = rawLines.compactMap { raw -> DiffLine? in
            guard let text = raw.stringValue, let marker = text.first else { return nil }
            let body = String(text.dropFirst())
            switch marker {
            case "+": return DiffLine(kind: .added, text: body)
            case "-": return DiffLine(kind: .removed, text: body)
            case " ": return DiffLine(kind: .context, text: body)
            default: return nil   // "\ No newline at end of file"
            }
        }
        return DiffHunk(oldStart: value["oldStart"]?.intValue ?? 0, oldLines: value["oldLines"]?.intValue ?? 0,
                        newStart: value["newStart"]?.intValue ?? 0, newLines: value["newLines"]?.intValue ?? 0,
                        lines: lines)
    }

    private static func splitLines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
