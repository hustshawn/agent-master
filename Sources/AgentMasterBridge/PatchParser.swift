import Foundation
import AgentMasterCore

/// Turns edit reports into FileChanges: Claude's `structuredPatch` and Codex's `apply_patch` text.
public enum PatchParser {
    /// Reads the `structuredPatch` that Edit/MultiEdit/Write report in PostToolUse `tool_response`.
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

    /// Reads a Codex `apply_patch` envelope (`*** Begin Patch` … `*** End Patch`) out of a shell command.
    /// Its hunks carry no line numbers, so starts are 0; relative paths are resolved against `cwd`.
    public static func changes(fromApplyPatch command: String, cwd: String?) -> [FileChange] {
        let lines = command.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let begin = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "*** Begin Patch" })
        else { return [] }
        func resolve(_ path: String) -> String {
            guard let cwd, !path.hasPrefix("/") else { return path }
            return (cwd as NSString).appendingPathComponent(path)
        }

        var changes: [FileChange] = []
        var current: FileChange?
        var hunkLines: [DiffLine]?
        func closeHunk() {
            guard let lines = hunkLines, !lines.isEmpty else { return hunkLines = nil }
            let old = lines.filter { $0.kind != .added }.count
            let new = lines.filter { $0.kind != .removed }.count
            current?.hunks.append(DiffHunk(oldStart: 0, oldLines: old, newStart: 0, newLines: new, lines: lines))
            hunkLines = nil
        }
        func closeFile() {
            closeHunk()
            if let current { changes.append(current) }
            current = nil
        }

        for line in lines[(begin + 1)...] {
            if line.hasPrefix("*** End Patch") { break }
            if let path = line.dropPrefix("*** Update File: ") ?? line.dropPrefix("*** Delete File: ") {
                closeFile()
                current = FileChange(path: resolve(path), hunks: [])
            } else if let path = line.dropPrefix("*** Add File: ") {
                closeFile()
                current = FileChange(path: resolve(path), hunks: [])
                hunkLines = []
            } else if let path = line.dropPrefix("*** Move to: ") {
                current = current.map { FileChange(path: resolve(path), hunks: $0.hunks) }
            } else if line.hasPrefix("@@") {
                closeHunk()
                hunkLines = []
            } else if line.hasPrefix("***") {
                continue   // "*** End of File"
            } else if hunkLines != nil, let marker = line.first {
                let body = String(line.dropFirst())
                switch marker {
                case "+": hunkLines?.append(DiffLine(kind: .added, text: body))
                case "-": hunkLines?.append(DiffLine(kind: .removed, text: body))
                case " ": hunkLines?.append(DiffLine(kind: .context, text: body))
                default: break
                }
            }
        }
        closeFile()
        return changes
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

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) : nil
    }
}
