import XCTest
import AppKit
import AgentMasterCore
@testable import TerminalKit

@MainActor
final class TerminalKitTests: XCTestCase {
    func testEnvironmentStringsAreSortedKeyValuePairs() {
        let launch = TerminalLaunch(executable: "/bin/sh", args: [], environment: ["B": "2", "A": "x=y"], currentDirectory: "/")
        XCTAssertEqual(launch.environmentStrings, ["A=x=y", "B=2"])
    }

    func testSelectionSurvivesOutputAndEndsWithAClick() {
        let view = AgentTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        view.feed(text: "hello world\r\n")
        view.selectAll(nil)
        view.feed(text: "⠋ Working…\r")
        XCTAssertTrue(view.selection.active)
        XCTAssertFalse(view.allowMouseReporting)
        view.selection.active = false
        XCTAssertTrue(view.allowMouseReporting)
    }

    func testPaletteHasSixteenColorsAndMuseBackground() {
        XCTAssertEqual(TerminalPalette.ansiColors.count, 16)
        let bg = NSColor(hex: Theme.bg).usingColorSpace(.sRGB)!
        XCTAssertEqual(bg.redComponent * 255, 0x1e, accuracy: 0.5)
        XCTAssertEqual(bg.greenComponent * 255, 0x1e, accuracy: 0.5)
        XCTAssertEqual(bg.blueComponent * 255, 0x22, accuracy: 0.5)
    }

    func testSessionRunsTheProcessWithEnvironmentAndDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("am-term-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.txt")

        let session = TerminalSession(launch: TerminalLaunch(
            executable: "/bin/sh",
            args: ["-c", "printf '%s|%s' \"$AM_PROBE\" \"$(pwd -P)\" > '\(out.path)'"],
            environment: ["AM_PROBE": "hello", "PATH": "/usr/bin:/bin"],
            currentDirectory: dir.path))
        XCTAssertTrue(session.isRunning)
        let exited = expectation(description: "process exited")
        session.onExit = { _ in exited.fulfill() }
        wait(for: [exited], timeout: 10)

        XCTAssertFalse(session.isRunning)
        let real = try XCTUnwrap(realpath(dir.path, nil).map { path -> String in
            defer { free(path) }
            return String(cString: path)
        })
        XCTAssertEqual(try String(contentsOf: out, encoding: .utf8), "hello|\(real)")
    }

    func testPastingAnImageOnlyClipboardSendsCtrlV() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("am-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let png = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)?
            .representation(using: .png, properties: [:]))
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        XCTAssertEqual(AgentTerminalView.pasteInput(pasteboard: pasteboard, kittyKeyboard: false), "\u{16}")
        XCTAssertEqual(AgentTerminalView.pasteInput(pasteboard: pasteboard, kittyKeyboard: true), "\u{1b}[118;5u")

        pasteboard.setString("hello", forType: .string)
        XCTAssertNil(AgentTerminalView.pasteInput(pasteboard: pasteboard, kittyKeyboard: true))
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        XCTAssertNil(AgentTerminalView.pasteInput(pasteboard: pasteboard, kittyKeyboard: true))
    }
}
