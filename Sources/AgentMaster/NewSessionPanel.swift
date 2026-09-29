import AppKit
import SwiftUI
import AgentMasterUI

/// A floating, draggable panel centred on the main window that hosts the new-session form.
@MainActor
final class NewSessionPanel {
    private var panel: NSPanel?

    func show(_ content: some View) {
        close()
        let panel = KeyPanel(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentViewController = NSHostingController(rootView: content.preferredColorScheme(.dark))
        panel.setContentSize(panel.contentViewController?.view.fittingSize ?? NSSize(width: 480, height: 360))

        if let main = NSApp.windows.first(where: { $0.frameAutosaveName == "main" && $0.isVisible }) {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: main.frame.midX - size.width / 2, y: main.frame.midY - size.height / 2))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

/// A titled NSPanel only takes key focus when asked; this one should, so Return and Esc reach the form.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
