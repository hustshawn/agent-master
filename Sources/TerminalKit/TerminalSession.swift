import AppKit
import SwiftTerm

/// One pseudo-terminal running one process. The view outlives SwiftUI view updates, so switching
/// sessions in the UI never restarts the process.
@MainActor
public final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    public let view: AgentTerminalView
    public var onExit: ((Int32?) -> Void)?
    public var onTitle: ((String) -> Void)?
    public private(set) var isRunning = false

    public init(launch: TerminalLaunch) {
        view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        super.init()
        TerminalPalette.apply(to: view)
        view.workingDirectory = launch.currentDirectory
        view.processDelegate = self
        view.startProcess(executable: launch.executable, args: launch.args, environment: launch.environmentStrings,
                          execName: nil, currentDirectory: launch.currentDirectory)
        isRunning = true
    }

    public func terminate() {
        guard isRunning else { return }
        view.terminate()
    }

    private func finished(_ exitCode: Int32?) {
        guard isRunning else { return }
        isRunning = false
        onExit?(exitCode)
    }

    nonisolated public func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated public func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onMain { $0.onTitle?(title) }
    }

    nonisolated public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated public func processTerminated(source: TerminalView, exitCode: Int32?) {
        onMain { $0.finished(exitCode) }
    }

    /// SwiftTerm calls the delegate on the main queue today; hop explicitly in case that changes.
    nonisolated private func onMain(_ body: @escaping @MainActor (TerminalSession) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(self) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { body(self) } }
        }
    }
}
