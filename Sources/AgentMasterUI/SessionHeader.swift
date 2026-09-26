import SwiftUI

/// `AgentMaster ▸ <project>` on the left, `model · mode` on the right; the rule turns accent when waiting on you.
public struct SessionHeader: View {
    let project: String
    let model: String?
    let mode: String?
    let needsAttention: Bool

    public init(project: String, model: String?, mode: String?, needsAttention: Bool) {
        self.project = project
        self.model = model
        self.mode = mode
        self.needsAttention = needsAttention
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("AgentMaster").foregroundStyle(Palette.muted)
                Text("▸").foregroundStyle(Palette.faint)
                Text(project).foregroundStyle(Palette.text)
                Spacer()
                Text([model, mode].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(Palette.muted)
            }
            .font(MuseFont.small)
            .padding(.horizontal, 12)
            .frame(height: 28)
            HairLine(color: needsAttention ? Palette.accent : Palette.faint)
        }
        .background(Palette.bg)
    }
}
