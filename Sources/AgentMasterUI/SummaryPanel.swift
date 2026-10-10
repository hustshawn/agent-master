import SwiftUI
import AppKit

/// Where a session's on-demand summary stands. Kept for this run only.
public enum SummaryState: Equatable {
    case none
    case running
    case done(String)
    case failed(String)
}

public struct SummaryPanel: View {
    let summary: SummaryState
    let onRegenerate: () -> Void

    public init(summary: SummaryState, onRegenerate: @escaping () -> Void) {
        self.summary = summary
        self.onRegenerate = onRegenerate
    }

    public var body: some View {
        switch summary {
        case .none:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Summarizing…").font(MuseFont.small).foregroundStyle(Palette.muted)
            }
        case .done(let text):
            VStack(alignment: .leading, spacing: 8) {
                MarkdownText(text)
                HStack(spacing: 12) {
                    action("Regenerate", onRegenerate)
                    action("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(MuseFont.small).foregroundStyle(Palette.error).textSelection(.enabled)
                action("Retry", onRegenerate)
            }
        }
    }

    private func action(_ title: String, _ perform: @escaping () -> Void) -> some View {
        Button(title, action: perform).buttonStyle(OutlineButtonStyle())
    }
}

/// The few Markdown blocks a summary uses: `#` headings and `-` bullets, with inline styling inside each line.
struct MarkdownText: View {
    let lines: [Substring]

    init(_ text: String) {
        lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines.indices, id: \.self) { index in
                line(lines[index].trimmingCharacters(in: .whitespaces))
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func line(_ text: String) -> some View {
        if text.hasPrefix("#") {
            Text(text.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).uppercased())
                .font(MuseFont.heading).foregroundStyle(Palette.muted).padding(.top, 6)
        } else if let item = ["- ", "* "].first(where: text.hasPrefix).map({ String(text.dropFirst($0.count)) }) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(Palette.faint)
                inline(item)
            }
        } else if !text.isEmpty {
            inline(text)
        }
    }

    private func inline(_ text: String) -> some View {
        let styled = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        return Text(styled).font(MuseFont.body).foregroundStyle(Palette.text).fixedSize(horizontal: false, vertical: true)
    }
}
