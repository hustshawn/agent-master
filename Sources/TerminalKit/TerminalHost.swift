import SwiftUI
import SwiftTerm

public struct TerminalHost: NSViewRepresentable {
    public let session: TerminalSession

    public init(session: TerminalSession) {
        self.session = session
    }

    public func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = session.view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    public func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
