import SwiftUI
import AgentMasterCore

public struct UsagePanel: View {
    let usage: Usage?
    let permissionMode: String?

    public init(usage: Usage?, permissionMode: String?) {
        self.usage = usage
        self.permissionMode = permissionMode
    }

    public var body: some View {
        if let usage {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("ctx \(usage.contextUsedPercent.map { "\($0)%" } ?? "–")").foregroundStyle(Palette.text)
                    Text("·").foregroundStyle(Palette.faint)
                    Text(String(format: "$%.2f", usage.costUSD)).foregroundStyle(Palette.text)
                }
                Text("↑\(TokenFormat.short(usage.inputTokens)) ↓\(TokenFormat.short(usage.outputTokens))")
                    .foregroundStyle(Palette.muted)
                Text([usage.modelName, permissionMode].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(Palette.muted)
            }
            .font(MuseFont.body)
        } else {
            EmptyHint("Waiting for first status update")
        }
    }
}
