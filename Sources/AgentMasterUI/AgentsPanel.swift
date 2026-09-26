import SwiftUI
import AgentMasterCore

public struct AgentsPanel: View {
    let subagents: [SubagentInfo]
    let mainActive: Bool

    public init(subagents: [SubagentInfo], mainActive: Bool) {
        self.subagents = subagents
        self.mainActive = mainActive
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("main").bold().foregroundStyle(Palette.accent)
                    if mainActive { Text("◈").foregroundStyle(Palette.teal) }
                }
                ForEach(subagents) { agent in
                    HStack(spacing: 6) {
                        Text("└").foregroundStyle(Palette.faint)
                        Text(agent.finished ? "✓" : "•")
                            .foregroundStyle(agent.finished ? Palette.success : Palette.teal)
                        Text(agent.description ?? agent.type)
                            .foregroundStyle(agent.finished ? Palette.muted : Palette.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(DurationFormat.short(agent.elapsed(at: context.date))).foregroundStyle(Palette.faint)
                    }
                }
            }
            .font(MuseFont.body)
        }
    }
}
