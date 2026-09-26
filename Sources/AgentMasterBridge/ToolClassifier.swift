import Foundation
import AgentMasterCore

/// Maps Claude Code tool names to display kinds. Claude Code renames tools occasionally; fix it here only.
public enum ToolClassifier {
    public static func kind(name: String, input: JSONValue) -> ToolKind {
        func string(_ key: String) -> String { input[key]?.stringValue ?? "" }
        switch name {
        case "Read": return .read(path: string("file_path"))
        case "Grep", "Glob": return .search(pattern: string("pattern"))
        case "Edit", "MultiEdit": return .edit(path: string("file_path"))
        case "NotebookEdit": return .edit(path: string("notebook_path"))
        case "Write": return .write(path: string("file_path"))
        case "Bash": return .shell(command: string("command"), description: input["description"]?.stringValue)
        case "WebFetch": return .web(target: string("url"))
        case "WebSearch": return .web(target: string("query"))
        case "Agent", "Task": return .agent(description: string("description"))
        default: return .other(name: name)
        }
    }
}
