import SwiftUI
import AgentMasterCore

/// The right-hand half of the header: `model · mode · ctx N% · $X.XX`, with ctx flagged from 80%.
public enum HeaderUsage {
    public struct Part: Equatable {
        public let text: String
        public let warning: Bool
    }

    public static let contextWarningPercent = 80

    public static func parts(usage: Usage?, mode: String?) -> [Part] {
        var parts: [Part] = []
        if let model = usage?.modelName { parts.append(Part(text: model, warning: false)) }
        if let mode { parts.append(Part(text: mode == "bypassPermissions" ? "bypass" : mode, warning: false)) }
        if let percent = usage?.contextUsedPercent {
            parts.append(Part(text: "ctx \(percent)%", warning: percent >= contextWarningPercent))
        }
        if let usage { parts.append(Part(text: String(format: "$%.2f", usage.costUSD), warning: false)) }
        return parts
    }

    public static func tokens(_ usage: Usage?) -> String? {
        usage.map { "↑\(TokenFormat.short($0.inputTokens)) ↓\(TokenFormat.short($0.outputTokens))" }
    }
}

/// `AgentMaster ▸ <project> ▸ <session>` on the left, usage on the right; the rule turns accent when waiting on you.
public struct SessionHeader: View {
    let project: String
    let session: String
    let usage: Usage?
    let mode: String?
    let needsAttention: Bool
    let inspectorCollapsed: Bool
    let onToggleInspector: () -> Void

    public init(project: String, session: String, usage: Usage?, mode: String?, needsAttention: Bool,
                inspectorCollapsed: Bool, onToggleInspector: @escaping () -> Void) {
        self.project = project
        self.session = session
        self.usage = usage
        self.mode = mode
        self.needsAttention = needsAttention
        self.inspectorCollapsed = inspectorCollapsed
        self.onToggleInspector = onToggleInspector
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("AgentMaster").foregroundStyle(Palette.muted)
                Text("▸").foregroundStyle(Palette.faint)
                Text(project).foregroundStyle(Palette.muted)
                Text("▸").foregroundStyle(Palette.faint)
                Text(session).foregroundStyle(Palette.text).lineLimit(1)
                Spacer(minLength: 12)
                usageText.help(HeaderUsage.tokens(usage) ?? "")
                Button(action: onToggleInspector) {
                    Image(systemName: "sidebar.right").font(.system(size: 15))
                        .foregroundStyle(inspectorCollapsed ? Palette.faint : Palette.muted)
                }
                .buttonStyle(IconButtonStyle())
                .help(inspectorCollapsed ? "Show inspector (⌥⌘0)" : "Hide inspector (⌥⌘0)")
                .padding(.leading, 6)
            }
            .font(MuseFont.small)
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(height: 34)
            HairLine(color: needsAttention ? Palette.accent : Palette.faint)
        }
        .background(Palette.bg)
    }

    private var usageText: some View {
        HStack(spacing: 4) {
            ForEach(Array(HeaderUsage.parts(usage: usage, mode: mode).enumerated()), id: \.offset) { index, part in
                if index > 0 { Text("·").foregroundStyle(Palette.faint) }
                Text(part.text).foregroundStyle(part.warning ? Palette.warning : Palette.muted)
            }
        }
    }
}
