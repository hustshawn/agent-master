import SwiftUI

/// What a card at the bottom of the terminal shows for a hook request waiting on the user (ADR 0017).
public struct DecisionCardModel: Identifiable, Equatable {
    public enum Kind: Equatable { case permission, question, policy }

    public struct Option: Equatable {
        public let label: String
        public let detail: String?

        public init(label: String, detail: String?) {
            self.label = label
            self.detail = detail
        }
    }

    public struct Question: Equatable {
        public let text: String
        public let header: String?
        public let options: [Option]

        public init(text: String, header: String?, options: [Option]) {
            self.text = text
            self.header = header
            self.options = options
        }
    }

    public let id: String
    public let kind: Kind
    public let title: String
    /// The command or path the tool would use.
    public let detail: String
    /// Why the policy rules asked.
    public let reason: String?
    public let questions: [Question]
    /// Whether "Answer in terminal" hands the call to the agent's own prompt (Claude Code) rather than denying it.
    public let canHandBack: Bool

    public init(id: String, kind: Kind, title: String, detail: String, reason: String?, questions: [Question],
                canHandBack: Bool) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.reason = reason
        self.questions = questions
        self.canHandBack = canHandBack
    }
}

/// An approval, a question or a policy check, answered here or handed to the terminal. While a policy check
/// waits, the agent's own prompt does not show in the terminal, so "Answer in terminal" stays one click away.
/// No button takes Return: Return in the reason field denies, so typing a reason can never allow the call.
public struct DecisionOverlay: View {
    let card: DecisionCardModel
    let onAllow: () -> Void
    /// "Allow for this session" on a policy check: the rule that asked stops asking in this session.
    let onAllowForSession: () -> Void
    let onDeny: (String) -> Void
    let onAnswer: ([String: String]) -> Void
    let onTerminal: () -> Void
    @State private var reason = ""
    @State private var chosen: [String: String] = [:]

    public init(card: DecisionCardModel, onAllow: @escaping () -> Void, onAllowForSession: @escaping () -> Void,
                onDeny: @escaping (String) -> Void, onAnswer: @escaping ([String: String]) -> Void,
                onTerminal: @escaping () -> Void) {
        self.card = card
        self.onAllow = onAllow
        self.onAllowForSession = onAllowForSession
        self.onDeny = onDeny
        self.onAnswer = onAnswer
        self.onTerminal = onTerminal
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(heading, systemImage: card.kind == .question ? "questionmark.bubble" : "checkmark.shield")
                .font(MuseFont.heading).foregroundStyle(Palette.accent)
            if card.kind == .question {
                ForEach(card.questions, id: \.text) { question in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(question.header ?? question.text).font(MuseFont.body.bold()).foregroundStyle(Palette.text)
                        if question.header != nil { Text(question.text).font(MuseFont.small).foregroundStyle(Palette.muted) }
                        // A click picks an option; the answer goes once every question has one.
                        HStack {
                            ForEach(question.options, id: \.label) { option in
                                Button { choose(option.label, for: question.text) } label: {
                                    Text(option.label).fontWeight(chosen[question.text] == option.label ? .bold : .regular)
                                }
                                .help(option.detail ?? option.label)
                            }
                        }
                    }
                }
            } else {
                if let reason = card.reason { Text(reason).font(MuseFont.small).foregroundStyle(Palette.warning) }
                // The command once: a shell call's title ("$ rm -rf build") already is the command.
                if card.detail.isEmpty || card.title.contains(card.detail) {
                    Text(card.title).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.text)
                        .lineLimit(4).textSelection(.enabled)
                } else {
                    Text(card.title).font(MuseFont.body.bold()).foregroundStyle(Palette.text)
                    Text(card.detail).font(MuseFont.small).foregroundStyle(Palette.muted).lineLimit(4).textSelection(.enabled)
                }
                TextField("Reason, if you deny (optional)", text: $reason).textFieldStyle(.roundedBorder)
                    .onSubmit(deny)
            }
            HStack {
                if card.kind != .question {
                    Button("Allow", action: onAllow)
                    if card.kind == .policy {
                        Button("Allow for this session", action: onAllowForSession)
                            .help("The rule that asked stops asking in this session.")
                    }
                    Button("Deny", action: deny)
                }
                Spacer()
                if card.kind != .policy || card.canHandBack {
                    Button("Answer in terminal", action: onTerminal)
                }
            }
            .controlSize(.large)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.selection))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.accent.opacity(0.4)))
        .padding(12)
    }

    private var heading: String {
        switch card.kind {
        case .permission: return "Needs your approval"
        case .question: return "Needs your answer"
        case .policy: return "Policy check"
        }
    }

    private func deny() {
        onDeny(reason.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func choose(_ label: String, for text: String) {
        chosen[text] = label
        if card.questions.allSatisfy({ chosen[$0.text] != nil }) { onAnswer(chosen) }
    }
}
