import Foundation
import AgentMasterCore

/// Reads the statusLine JSON Claude Code pipes to the statusLine command.
public enum UsageParser {
    public static func usage(from payload: JSONValue) -> Usage? {
        guard payload.objectValue != nil else { return nil }
        let context = payload["context_window"]
        return Usage(
            modelName: payload["model"]?["display_name"]?.stringValue ?? "claude",
            contextUsedPercent: context?["used_percentage"]?.intValue,
            inputTokens: context?["total_input_tokens"]?.intValue ?? 0,
            outputTokens: context?["total_output_tokens"]?.intValue ?? 0,
            costUSD: payload["cost"]?["total_cost_usd"]?.doubleValue ?? 0
        )
    }
}
